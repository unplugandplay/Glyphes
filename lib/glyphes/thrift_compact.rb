## glyphes — the Thrift compact protocol (Parquet metadata)
##
## Parquet's footer is a Thrift-encoded `FileMetaData`, and its column
## headers are Thrift-encoded `PageHeader`s. There is no other way to read
## or write a Parquet file, so this is the bottom of the format stack:
## everything above it — schema, pages, the file itself — is built on these
## twenty lines of wire format.
##
## Compact protocol, from the Thrift spec (the "TCompactProtocol"):
##
##   - field headers carry the *delta* from the previous field id, not the
##     id itself, so a struct with ids 1..N is one byte per field
##   - a field header nibble of 0 is the struct's stop marker
##   - types pack into the same nibble as the delta (1..12), and a type
##     outside that range escapes to a following zigzag varint
##   - bool inside a field header is its own type (1/2) with the value in
##     the payload; inside a *list* header the value rides in the size
##   - i16/i32/i64 are zigzag varints; doubles are 8 little-endian bytes
##
## This writer emits, and this reader accepts, exactly what Parquet needs.
## It is not a general Thrift implementation and does not pretend to be:
## there is no binary protocol, no message envelope, no application layer.

module Glyphes
  # A minimal Thrift compact-protocol codec: enough to read and write
  # Parquet's `FileMetaData` and `PageHeader`, and deliberately no more.
  module ThriftCompact
    # Field types in the compact protocol's nibble table.
    STOP        = 0x00
    TRUE        = 0x01
    FALSE       = 0x02
    BYTE        = 0x03
    I16         = 0x04
    I32         = 0x05
    I64         = 0x06
    DOUBLE      = 0x07
    BINARY      = 0x08
    LIST        = 0x09
    SET         = 0x0A
    MAP         = 0x0B
    STRUCT      = 0x0C
    # Anything above STRUCT is escaped in the nibble as 0x0F followed by a
    # zigzag varint type.
    EXTENDED    = 0x0F

    # Shared between the writer and the reader; included into both so the
    # nested classes can call them unqualified.
    module Helpers
      # Zigzag: `(n << 1) ^ (n >> 31)` done arithmetically, so -1 becomes 1
      # and small negatives stay one byte. Every signed int in the compact
      # protocol is zigzag-encoded.
      def zigzag(n)
        n.negative? ? (-n * 2 - 1) : (n * 2)
      end

      def unzigzag(n)
        n.even? ? n / 2 : -((n + 1) / 2)
      end

      def varint(value)
        v = value
        bytes = +"".b
        loop do
          b = v & 0x7F
          v >>= 7
          if v.zero?
            bytes << b.chr
            break
          end
          bytes << (b | 0x80).chr
        end
        bytes
      end
    end

    extend Helpers

    module_function

    # ---- writing --------------------------------------------------------

    # Accumulates one struct's fields and closes itself with the stop
    # marker. `id` is the field's id in the Thrift schema (not the delta —
    # the delta is computed here, from the previous field).
    class Writer
      include Glyphes::ThriftCompact::Helpers

      attr_reader :bytes

      def initialize
        @bytes = +"".b
        @last_id = 0
      end

      # `type` is a nibble constant above; `value` is written by `write_value`.
      def field(id, type, value = nil)
        write_field_header(id, type)
        write_value(type, value) unless value.nil?
        self
      end

      def bool_field(id, value)
        # A bool's type *is* its value in the header: no payload follows.
        delta = id - @last_id
        @bytes << ((delta << 4) | (value ? TRUE : FALSE)).chr
        @last_id = id
        self
      end

      # Write a list/set header: the element type in the high nibble, the
      # size (or a varint size if 15) in the low nibble. A bool list
      # carries each value in the header's low nibble instead.
      def list_field(id, elem_type, values)
        values = values.to_a
        write_field_header(id, LIST)
        write_list_header(elem_type, values.size)
        values.each { |v| write_value(elem_type, v) }
        self
      end

      # The list header: element type in the high nibble, size in the low
      # nibble, or a varint size when the count does not fit in four bits.
      def write_list_header(elem_type, size)
        @bytes << ((elem_type << 4) | (size < 15 ? size : 15)).chr
        @bytes << varint(size) if size >= 15
      end

      # A field whose payload is already encoded — a nested struct, or a
      # list built elsewhere. Parquet's metadata is mostly nested structs,
      # and framing them here keeps every struct's field-id delta local to
      # the writer that owns it.
      def raw_struct_field(id, _type, encoded)
        write_field_header(id, STRUCT)
        @bytes << encoded
        self
      end

      # A list whose items are pre-encoded bytes. The caller owns the item
      # encoding — in particular integer items must already be zigzag
      # varints, because a list of ints is encoded exactly like a struct
      # field of that int type. `integer_list_field` is the form that gets
      # that right for you.
      def raw_list_field(id, elem_type, encoded_items)
        items = encoded_items.is_a?(Array) ? encoded_items : [encoded_items]
        write_field_header(id, LIST)
        write_list_header(elem_type, items.length)
        items.each { |item| @bytes << item }
        self
      end

      # A list of integers, zigzag-encoded per element (compact protocol).
      def integer_list_field(id, elem_type, values)
        write_field_header(id, LIST)
        write_list_header(elem_type, values.length)
        values.each { |v| @bytes << varint(zigzag(v)) }
        self
      end

      def stop
        @bytes << STOP.chr
        self
      end

      def write_value(type, value)
        case type
        when BYTE     then @bytes << varint(zigzag(value))
        when I16, I32, I64 then @bytes << varint(zigzag(value))
        when DOUBLE   then @bytes << [value].pack("E")
        when BINARY
          bytes = value.to_s.dup.force_encoding(Encoding::BINARY)
          @bytes << varint(bytes.bytesize)
          @bytes << bytes
        else
          raise ArgumentError, "thrift: cannot write type #{type}"
        end
      end

      # ---- low level ----

      # Field header: the delta from the previous id in the high nibble,
      # the type in the low nibble. A delta that does not fit in four bits
      # escapes as a high nibble of 0 followed by a zigzag varint delta; a
      # type outside 1..12 escapes as a low nibble of 15 followed by a
      # zigzag varint type. They are two independent escapes and conflating
      # them (the first version) made an out-of-range *delta* write an
      # out-of-range *type*, which the reader then tried to resolve.
      def write_field_header(id, type)
        delta = id - @last_id
        high = delta.positive? && delta <= 15 ? delta : 0
        if high.zero?
          @bytes << ((0 << 4) | type).chr
          @bytes << varint(zigzag(delta))
        else
          @bytes << ((high << 4) | type).chr
        end
        @last_id = id
      end

      def varint(value)
        v = value
        bytes = +"".b
        loop do
          b = v & 0x7F
          v >>= 7
          if v.zero?
            bytes << b.chr
            break
          else
            bytes << (b | 0x80).chr
          end
        end
        bytes
      end
      alias write_varint varint
    end

    # A standalone varint, for the few places that need one outside a
    # struct (the RLE/bit-packing hybrid's length prefix).
    def self.varint(value)
      v = value
      bytes = +"".b
      loop do
        b = v & 0x7F
        v >>= 7
        if v.zero?
          bytes << b.chr
          break
        end
        bytes << (b | 0x80).chr
      end
      bytes
    end

    # ---- reading --------------------------------------------------------

    # Walks one struct, calling the block with `(field_id, type, value)` per
    # field. Nested structs and lists are handed to the block *undecoded*
    # (as [type, raw_bytes]) so a caller that does not care — and Parquet
    # readers usually do not care about half the metadata — never pays to
    # parse it. The block returns :skip for fields it does not want; :skip
    # still consumes the payload, which is the part that is easy to get
    # wrong.
    class Reader
      include Glyphes::ThriftCompact::Helpers

      def initialize(bytes)
        @bytes = bytes.dup.force_encoding(Encoding::BINARY)
        @pos = 0
      end

      def self.read(bytes, &block)
        new(bytes).each_struct(&block)
      end

      def each_struct
        last_id = 0
        loop do
          header = read_byte
          break if header.nil? || header == STOP

          type = header & 0x0F
          type = unzigzag(read_varint) if type == EXTENDED
          delta = (header >> 4) & 0x0F
          delta = unzigzag(read_varint) if delta.zero?
          id = last_id + delta
          last_id = id

          if type == TRUE
            yield id, :bool, true
          elsif type == FALSE
            yield id, :bool, false
          else
            yield id, type, read_value(type)
          end
        end
      end

      def read_value(type)
        case type
        when BYTE      then read_byte
        when I16, I32, I64 then unzigzag(read_varint)
        when DOUBLE    then read(8).unpack1("E")
        when BINARY    then read(read_varint)
        when LIST, SET  then read_list_header_and_values
        when STRUCT    then [STRUCT, read_struct_bytes]
        when MAP       then raise ArgumentError, "thrift: map is not used by Parquet"
        else
          raise ArgumentError, "thrift: cannot read type #{type}"
        end
      end

      # A list needs its length and element type before anything else; the
      # reader returns `[elem_type, values]`.
      def read_list_header_and_values
        header = read_byte
        elem_type = (header >> 4) & 0x0F
        size = header & 0x0F
        size = read_varint if size == 15
        if elem_type == TRUE || elem_type == FALSE
          # A list of bools packs each value into the header's low nibble.
          flags = []
          while size.positive?
            flags << read_bool_from_nibble
            size -= 1
          end
          [elem_type, flags]
        else
          values = []
          size.times { values << read_value(elem_type) }
          [elem_type, values]
        end
      end

      def read_struct_bytes
        start = @pos
        skip_struct
        @bytes.byteslice(start, @pos - start)
      end

      # The length in bytes of the struct at the current position. A page
      # header does not record its own size, so a reader that wants to know
      # where the page data begins has to measure the header — which means
      # walking it exactly once and counting.
      def read_struct_bytes_size
        start = @pos
        skip_struct
        @pos - start
      end

      # Consume one struct's bytes without building anything from them.
      def skip_struct
        last_id = 0
        loop do
          header = read_byte
          break if header.nil? || header == STOP

          type = header & 0x0F
          type = unzigzag(read_varint) if type == EXTENDED
          delta = (header >> 4) & 0x0F
          delta = unzigzag(read_varint) if delta.zero?
          last_id += delta
          next if type == TRUE || type == FALSE

          skip_value(type)
        end
      end

      def skip_value(type)
        case type
        when BYTE      then read_byte
        when I16, I32, I64 then read_varint
        when DOUBLE    then read(8)
        when BINARY    then read(read_varint)
        when LIST, SET
          header = read_byte
          elem_type = (header >> 4) & 0x0F
          size = header & 0x0F
          size = read_varint if size == 15
          size.times { skip_value(elem_type) }
        when STRUCT    then skip_struct
        else raise ArgumentError, "thrift: cannot skip type #{type}"
        end
      end

      def read_byte
        return nil if @pos >= @bytes.bytesize

        b = @bytes.getbyte(@pos)
        @pos += 1
        b
      end

      def read(n)
        @pos += n
        @bytes.byteslice(@pos - n, n)
      end

      def read_varint
        result = 0
        shift = 0
        loop do
          b = read_byte
          raise ArgumentError, "thrift: truncated varint" if b.nil?

          result |= (b & 0x7F) << shift
          shift += 7
          break if (b & 0x80).zero?
        end
        result
      end

      def unzigzag(n)
        n.even? ? n / 2 : -((n + 1) / 2)
      end

      def read_bool_from_nibble
        b = read_byte
        b = read_byte if b.nil?
        # The bool nibble is the low four bits of each byte.
        (b & 0x0F) != 0
      end
    end
  end
end