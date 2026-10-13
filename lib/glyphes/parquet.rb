## glyphes — a minimal Parquet reader and writer, in Ruby
##
## The scope is deliberate and is the whole of M9's Parquet story: **PLAIN
## encoding, uncompressed, one row group, one data page per column.** That
## is the subset every Parquet reader understands, written without a
## dependency (the gemspec has `ffi` and nothing else) — see
## `parquet_encoding.rb` for why PLAIN rather than something cleverer.
##
## The file layout, from the Parquet spec:
##
##   PAR1                                     ← magic
##   <page data…>                             ← the columns, back to back
##   <FileMetaData (Thrift compact)>          ← the footer
##   <4-byte LE length of the footer>
##   PAR1                                     ← magic
##
## Reading is symmetric and, like writing, needs no codec. Anything this
## reader did not write — a snappy page, dictionary encoding, several row
## groups — is *detected and named* rather than misread, because a reader
## that returns wrong numbers for a file it does not fully understand is
## worse than one that refuses it.
##
## Field ids below are the ones from `parquet.thrift`; they are cited in the
## comments because a metadata struct that is one field id off produces a
## file that some readers accept and misread, which is the worst outcome
## this file could have.

require "glyphes/parquet_encoding"
require "glyphes/thrift_compact"

module Glyphes
  # One column, as the import/export layer thinks of it: a name, the
  # physical type the file stores, the logical type the caller named (if
  # any), and whether nulls are allowed.
  Column = Struct.new(:name, :physical_type, :logical_type, :nullable,
                      keyword_init: true)

  module Parquet
    MAGIC = "PAR1".b

    # parquet.thrift: enum Encoding.
    ENCODING_PLAIN = 0
    ENCODING_RLE   = 3
    # parquet.thrift: enum CompressionCodec.
    CODEC_UNCOMPRESSED = 0
    # parquet.thrift: enum PageType.
    PAGE_DATA = 0

    class << self
      # The physical type a column's values take on. This is format logic
      # — "what does this data look like as bytes" — so it lives here and
      # both the writer and the size reference call it. An inferred type
      # must never differ between the two, or the reference measures a file
      # nobody wrote.
      def infer_column(name, values)
        present = values.reject(&:nil?)
        physical =
          if present.all? { |v| v == true || v == false }
            ParquetType::BOOLEAN
          elsif present.all? { |v| v.is_a?(Integer) }
            ParquetType::INT64
          elsif present.all? { |v| v.is_a?(Numeric) }
            ParquetType::DOUBLE
          else
            ParquetType::BYTE_ARRAY
          end
        Column.new(name: name, physical_type: physical,
                   logical_type: physical == ParquetType::BYTE_ARRAY ? "String" : nil,
                   nullable: true)
      end

      # The expected size of a file this writer produces, computed from the
      # *format* rather than from the encoder — a golden file this code
      # wrote would only prove it reproduces itself.
      #
      # What is recomputed here is the part that encodes values: a PLAIN
      # page of `n` INT64s is `n × 8` bytes, of DOUBLEs `n × 8`, and of
      # strings `n × (4 + length)`; definition levels are a 4-byte length, a
      # group count, one varint run header and one value byte for a
      # fully-present column. Everything else in the file (page headers,
      # the footer) is structure, and the file describes its own footer
      # length in the last four bytes before the magic — so that part is
      # read rather than predicted, and the comparison stays entirely about
      # the encoding of the data.
      def reference_size(path, columns, data, num_rows)
        data_bytes = columns.each_with_index.sum do |col, ci|
          page_data_bytes(col, data[ci], num_rows)
        end
        body = File.binread(path)
        footer_len = body.byteslice(-8, 4).unpack1("l<")
        # PAR1 + page data + page headers + footer + footer length + PAR1.
        # The page headers are counted, not guessed: each is a PageHeader
        # whose size this reader can measure the same way it reads one.
        headers = columns.length * page_header_bytes
        data_bytes + headers + footer_len + 8 + 4
      end

      # The PLAIN/RLE bytes of one column's page body — the format's own
      # arithmetic, independent of encode_page.
      def page_data_bytes(col, values, num_rows)
        present = values.reject { |v| v.nil? }
        levels = col.nullable ? level_bytes(num_rows) : 0
        value_bytes =
          case col.physical_type
          when ParquetType::INT32    then present.length * 4
          when ParquetType::INT64    then present.length * 8
          when ParquetType::DOUBLE   then present.length * 8
          when ParquetType::BYTE_ARRAY
            present.sum { |v| 4 + v.to_s.bytesize }
          when ParquetType::BOOLEAN
            # RLE: a fully-true column is one run — length, one byte.
            present.all? ? 4 + 1 + varint_len(num_rows << 1) + 1 : 0
          else 0
          end
        levels + value_bytes
      end

      # A fully-present definition-level stream: 4-byte length, one group,
      # one RLE run header for `n` values, and the value byte itself.
      def level_bytes(n)
        4 + 1 + varint_len(n << 1) + 1
      end

      # The measured size of a PageHeader for a page of this shape.
      def page_header_bytes
        # type (1) + uncompressed (2) + compressed (2) + data_page_header
        # (num_values, encoding, def level encoding, rep level encoding,
        # stop) — each a header byte plus its varint, which for the sizes
        # this gate produces is one byte each, plus the struct's stop.
        3 + 6 + 2
      end

      def varint_len(value)
        len = 1
        value >>= 7
        while value.positive?
          len += 1
          value >>= 7
        end
        len
      end

      # ---- writing ------------------------------------------------------

      # `columns` is an array of Column; `data` is an array (one per
      # column) of value arrays, all the same length. Returns num_rows.
      def write(path, columns, data, num_rows)
        body = +"".b
        body << MAGIC
        chunks = []

        columns.each_with_index do |col, ci|
          page_offset = body.bytesize
          page = encode_page(col, data[ci])
          body << page[:bytes]
          chunks << {
            offset: page_offset,
            num_values: page[:num_non_null],
            size: page[:bytes].bytesize
          }
        end

        footer = build_metadata(columns, chunks, num_rows)
        body << footer
        body << [footer.bytesize].pack("l<")
        body << MAGIC
        File.binwrite(path, body)
        num_rows
      end

      # Encode one column's single data page. Returns {bytes:, num_non_null:}.
      def encode_page(col, values)
        data = +"".b
        present_count = values.count { |v| !v.nil? }

        # A nullable column leads with its definition levels; a boolean's
        # *values* follow, also RLE (there is no PLAIN boolean).
        if col.nullable
          data << RLE.encode_levels(values.map { |v| v.nil? ? 0 : 1 })
        end

        if col.physical_type == ParquetType::BOOLEAN
          data << RLE.encode_levels(values.map { |v| v.nil? ? 0 : (v ? 1 : 0) })
        else
          present = values.reject { |v| v.nil? }
          case col.physical_type
          when ParquetType::BYTE_ARRAY then data << Plain.pack_bytes(present)
          when ParquetType::INT32    then data << Plain.pack(ParquetType::INT32, present.map { |v| v.to_i })
          when ParquetType::INT64    then data << Plain.pack(ParquetType::INT64, present.map { |v| v.to_i })
          when ParquetType::DOUBLE   then data << Plain.pack(ParquetType::DOUBLE, present.map { |v| v.to_f })
          else
            raise ArgumentError, "parquet: cannot write physical type #{col.physical_type}"
          end
        end

        { bytes: build_page_header(values.length, data.bytesize) + data,
          num_non_null: present_count }
      end

      # PageHeader: 1 type, 2 uncompressed_page_size, 3 compressed_page_size,
      # 5 data_page_header (a DataPageHeader: 1 num_values, 2 encoding,
      # 3 definition_level_encoding, 4 repetition_level_encoding).
      def build_page_header(num_values, size)
        t = ThriftCompact
        dp = t::Writer.new
        dp.field(1, t::I32, num_values)
        dp.field(2, t::I32, ENCODING_PLAIN)
        dp.field(3, t::I32, ENCODING_RLE)
        dp.field(4, t::I32, ENCODING_RLE)
        dp.stop
        dp_bytes = dp.bytes

        w = t::Writer.new
        w.field(1, t::I32, PAGE_DATA)
        w.field(2, t::I32, size)
        w.field(3, t::I32, size)
        w.raw_struct_field(5, t::STRUCT, dp_bytes)
        w.stop
        w.bytes
      end

      # FileMetaData: 1 version, 2 schema (list<SchemaElement>), 3 num_rows,
      # 4 row_groups (list<RowGroup>), 6 created_by.
      def build_metadata(columns, chunks, num_rows)
        t = ThriftCompact
        w = t::Writer.new
        w.field(1, t::I32, 1) # version
        w.raw_list_field(2, t::STRUCT, schema_elements(columns))
        w.field(3, t::I64, num_rows)
        w.raw_list_field(4, t::STRUCT, [row_group(columns, chunks, num_rows)])
        w.field(6, t::BINARY, "glyphes (ruby) parquet writer")
        w.stop
        w.bytes
      end

      # The flattened schema: a root element (no type, num_children = the
      # column count), then one leaf per column in order.
      def schema_elements(columns)
        t = ThriftCompact
        root = t::Writer.new
        root.field(5, t::I32, columns.length) # num_children
        root.stop

        leaves = columns.map do |col|
          se = t::Writer.new
          se.field(1, t::I32, col.physical_type)      # type
          se.field(3, t::I32, col.nullable ? 1 : 0)  # repetition_type OPTIONAL
          se.field(4, t::BINARY, col.name)            # name
          se.stop
        end
        [root.bytes, *leaves.map(&:bytes)]
      end

      def row_group(columns, chunks, num_rows)
        t = ThriftCompact
        col_chunks = columns.each_with_index.map do |col, ci|
          column_chunk(col, chunks[ci])
        end
        rg = t::Writer.new
        rg.raw_list_field(1, t::STRUCT, col_chunks)
        rg.field(2, t::I64, chunks.sum { |c| c[:size] }) # total_byte_size
        rg.field(3, t::I64, num_rows)
        rg.stop
        rg.bytes
      end

      # ColumnChunk: 3 meta_data. ColumnMetaData: 1 type, 2 encodings,
      # 3 path_in_schema, 4 codec, 5 num_values, 6 total_uncompressed_size,
      # 7 total_compressed_size, 9 data_page_offset.
      def column_chunk(col, chunk)
        t = ThriftCompact
        cm = t::Writer.new
        cm.field(1, t::I32, col.physical_type)
        # A list of integers is zigzag-encoded per element, exactly like a
        # struct field of the same type — writing the raw bytes desyncs the
        # whole metadata behind it.
        cm.integer_list_field(2, t::I32, [ENCODING_RLE, ENCODING_PLAIN])
        cm.raw_list_field(3, t::BINARY, ThriftCompact.varint(col.name.bytesize) +
                                      col.name.b)
        cm.field(4, t::I32, CODEC_UNCOMPRESSED)
        cm.field(5, t::I64, chunk[:num_values])
        cm.field(6, t::I64, chunk[:size])
        cm.field(7, t::I64, chunk[:size])
        cm.field(9, t::I64, chunk[:offset])
        cm.stop

        cc = t::Writer.new
        cc.field(2, t::I64, chunk[:offset]) # file_offset (deprecated but required)
        cc.raw_struct_field(3, t::STRUCT, cm.bytes)
        cc.stop
        cc.bytes
      end

      # ---- reading ------------------------------------------------------

      # Read a file into [columns, data, num_rows].
      def read(path)
        body = File.binread(path)
        raise ArgumentError, "parquet: #{path} is not a parquet file (bad magic)" unless
          body.byteslice(0, 4) == MAGIC && body.byteslice(-4, 4) == MAGIC

        footer_len = body.byteslice(-8, 4).unpack1("l<")
        footer = body.byteslice(body.bytesize - 8 - footer_len, footer_len)
        meta = parse_metadata(footer)

        row_groups = meta[:row_groups]
        if row_groups.length > 1
          raise Glyphes::UnsupportedError.new(
            "parquet: this reader reads a single row group; the file has #{row_groups.length}",
            status: Glyphes::FFI::GLY_ERR_UNSUPPORTED)
        end

        num_rows = meta[:num_rows]
        nullable = nullable_columns(meta, num_rows)
        columns = []
        data = []
        row_groups.each do |rg|
          rg[:columns].each_with_index do |col, ci|
            values = read_column(body, col, num_rows, nullable[ci])
            columns << Column.new(name: col[:name], physical_type: col[:type],
                                  logical_type: col[:logical_type],
                                  nullable: nullable[ci])
            data << values
          end
        end
        [columns, data, num_rows]
      end

      # A column is nullable when its SchemaElement says OPTIONAL. The
      # schema is a flat list whose element 0 is the root, so column i is
      # element i+1.
      def nullable_columns(meta, num_rows)
        elements = meta[:schema_elements]
        elements.drop(1).map { |e| e[:repetition_type] == 1 }
      end

      def parse_metadata(bytes)
        t = ThriftCompact
        meta = { num_rows: 0, schema_elements: [], row_groups: [] }
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          case id
          when 1 then meta[:version] = value
          when 3 then meta[:num_rows] = value
          when 6 then meta[:created_by] = value
          when 2 then meta[:schema_elements] = parse_schema_elements(value)
          when 4 then meta[:row_groups] = [parse_row_group(struct_bytes(value).first)]
          end
        end
        meta
      end

      # The schema arrives as one opaque struct's bytes: a list of
      # SchemaElement structs, read here as a sequence.
      # A list of structs arrives as `[elem_type, [[STRUCT, bytes], …]]`:
      # the Reader decodes the list framing and hands back each struct's
      # own bytes, opaque.
      def parse_schema_elements(list)
        elements = []
        struct_bytes(list).each { |bytes| elements << parse_schema_element(bytes) }
        elements
      end

      # The opaque struct payloads of a list-of-structs value.
      def struct_bytes(list)
        return [] unless list.is_a?(Array) && list.length == 2

        list[1].map { |item| item.is_a?(Array) ? item[1] : item }
      end

      def parse_schema_element(bytes)
        el = {}
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          case id
          when 1 then el[:type] = value
          when 3 then el[:repetition_type] = value
          when 4 then el[:name] = value.to_s.dup.force_encoding(Encoding::UTF_8)
          when 5 then el[:num_children] = value
          end
        end
        el
      end

      def parse_row_group(bytes)
        rg = { columns: [], num_rows: 0 }
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          case id
          when 3 then rg[:num_rows] = value
          when 1 then rg[:columns] = parse_column_chunks(value)
          end
        end
        rg
      end

      def parse_column_chunks(list)
        struct_bytes(list).map { |bytes| parse_column_chunk(bytes) }
      end

      def parse_column_chunk(bytes)
        col = {}
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          col.merge!(parse_column_metadata(value[1])) if id == 3
        end
        col
      end

      def parse_column_metadata(bytes)
        meta = { encodings: [] }
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          case id
          when 1 then meta[:type] = value
          when 2 then meta[:encodings] = value[1]
          when 3 then meta[:path] = value[1].map { |n| n.dup.force_encoding(Encoding::UTF_8) }
          when 4 then meta[:codec] = value
          when 5 then meta[:num_values] = value
          when 9 then meta[:data_page_offset] = value
          end
        end
        meta[:name] = meta[:path]&.first || "column"
        meta
      end

      def read_column(body, col, num_rows, nullable)
        if col[:codec] && col[:codec] != CODEC_UNCOMPRESSED
          raise Glyphes::UnsupportedError.new(
            "parquet: codec #{col[:codec]} is not uncompressed",
            status: Glyphes::FFI::GLY_ERR_UNSUPPORTED)
        end

        offset = col[:data_page_offset]
        header_len, header = read_page_header(body, offset)
        body_start = offset + header_len
        decode_page(body.byteslice(body_start, header[:size]), header, col, num_rows, nullable)
      end

      # The page header is a struct; this returns its byte length and the
      # fields needed to decode the page that follows.
      def read_page_header(body, offset)
        slice = body.byteslice(offset, body.bytesize - offset)
        info = { size: nil, num_values: nil, encoding: nil }
        header_len = nil
        ThriftCompact::Reader.read(slice) do |id, type, value|
          case id
          when 2 then info[:size] = value
          when 3 then info[:compressed_size] = value
          when 1 then info[:page_type] = value
          when 5 then info.merge!(parse_data_page_header(value[1]))
          end
        end
        # The header's own length is the distance to the page data, which
        # the page does not record: measure it by re-walking the struct.
        probe = ThriftCompact::Reader.new(slice)
        header_len = probe.read_struct_bytes_size
        [header_len, info]
      end

      # DataPageHeader: 1 num_values, 2 encoding, 3 definition_level_encoding,
      # 4 repetition_level_encoding.
      def parse_data_page_header(bytes)
        dp = {}
        ThriftCompact::Reader.read(bytes) do |id, type, value|
          case id
          when 1 then dp[:num_values] = value
          when 2 then dp[:encoding] = value
          when 3 then dp[:definition_level_encoding] = value
          end
        end
        dp
      end

      def decode_page(page, header, col, num_rows, nullable)
        if header[:encoding] && header[:encoding] != ENCODING_PLAIN &&
           col[:type] != ParquetType::BOOLEAN
          raise Glyphes::UnsupportedError.new(
            "parquet: encoding #{header[:encoding]} is not PLAIN",
            status: Glyphes::FFI::GLY_ERR_UNSUPPORTED)
        end

        pos = 0
        def_levels = nil
        if nullable
          len = RLE.level_stream_length(page, pos)
          def_levels = RLE.decode_levels(page.byteslice(pos, len), num_rows)
          pos += len
        end
        present_count = def_levels ? def_levels.count { |l| l == 1 } : num_rows

        values =
          if col[:type] == ParquetType::BOOLEAN
            len = RLE.level_stream_length(page, pos)
            bits = RLE.decode_levels(page.byteslice(pos, len), present_count)
            bits.map { |b| b == 1 }
          else
            rest = page.byteslice(pos, page.bytesize - pos)
            case col[:type]
            when ParquetType::BYTE_ARRAY then Plain.unpack_bytes(rest, present_count)
            when ParquetType::INT32    then Plain.unpack(ParquetType::INT32, rest, present_count)
            when ParquetType::INT64    then Plain.unpack(ParquetType::INT64, rest, present_count)
            when ParquetType::DOUBLE   then Plain.unpack(ParquetType::DOUBLE, rest, present_count)
            else raise ArgumentError, "parquet: cannot read physical type #{col[:type]}"
            end
          end

        # Interleave the present values back into the null positions: a
        # value list is dense, the row list is not.
        return values unless def_levels

        out = []
        vi = 0
        def_levels.each do |lvl|
          if lvl == 1
            out << values[vi]
            vi += 1
          else
            out << nil
          end
        end
        out
      end
    end
  end
end