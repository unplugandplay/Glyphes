## glyphes — Parquet page encoding primitives
##
## A Parquet page in 0.1 is PLAIN-encoded and uncompressed. That is a real
## choice, not a shortcut: PLAIN is the encoding every reader understands
## without a codec, and uncompressed pages mean the reader needs no
## decompression library — which is what lets this file format live in Ruby
## with no dependency beyond the standard library (`RUBY.md` §6.2: the
## engine never sees a file format, and neither does the host).
##
## Two encodings matter here:
##
##   PLAIN     fixed-width little-endian values, back to back. An int64
##             column is eight bytes per value; a double, eight. A boolean
##             is *not* PLAIN — there is no fixed-width boolean.
##   RLE       the RLE/bit-packing hybrid, used for two things: definition
##             levels (which values are non-null) and booleans. A run of
##             repeats is encoded as a varint length + the repeated value;
##             anything else is bit-packed eight values to a byte.
##
## Nullability is the whole reason definition levels exist. A Parquet value
## is not "nil" — it is a value plus a level saying whether it is present,
## so a nullable column and a non-null column differ by one flag and the
## definition levels that follow it.

require "glyphes/thrift_compact"

module Glyphes
  # Parquet physical types, as the file format names them. These are the
  # ids that go into the schema and the column metadata, so they are
  # spelled out rather than derived from Ruby's classes. (parquet.thrift:
  # enum Type.)
  module ParquetType
    BOOLEAN  = 0
    INT32    = 1
    INT64    = 2
    INT96    = 3  # deprecated; never produced here
    FLOAT    = 4
    DOUBLE   = 5
    BYTE_ARRAY = 6
    FIXED_LEN_BYTE_ARRAY = 7

    # How a PLAIN page packs each fixed-width type's bytes (little-endian).
    PACK = {
      INT32  => "l<",   # 4-byte signed LE
      INT64  => "q<",   # 8-byte signed LE
      FLOAT  => "e",    # 4-byte float LE
      DOUBLE => "E"     # 8-byte double LE
    }.freeze
  end

  # The RLE/bit-packing hybrid, byte-for-byte as Parquet specifies it
  # (Encodings.md).
  #
  # The framing: a varint `group count`, then per run a varint header whose
  # low bit is the "bit-packed" flag and whose rest is the run length. A
  # bit-packed run holds a multiple of 8 values; an RLE run is `value`
  # repeated, written at the level width. At max definition level 1 the
  # width is one byte, which is every column this gem writes.
  module RLE
    module_function

    # One varint. Used for run headers and the group count.
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

    # Bit-packed: 8 values per byte, LSB first, low bit of the first byte
    # is the first value. The run length is padded to a multiple of 8; the
    # decoder uses `num_values` to know how many packed values are real.
    def bitpack(values)
      bytes = +"".b
      values.each_slice(8) do |group|
        byte = 0
        group.each_with_index { |v, i| byte |= (v & 0xFF) << (i & 7) }
        bytes << byte.chr
      end
      bytes
    end

    # The run header: `(count << 1) | bitpacked_flag`, as a varint.
    def run_header(count, bitpacked)
      varint((count << 1) | (bitpacked ? 1 : 0))
    end

    # Encode a level stream for a 1-bit-wide column (max def level 1):
    # definition levels, or the values of a boolean column.
    #
    # The stream is length-prefixed with a 4-byte LE byte count — which is
    # what a DataPageV1 carries, and what makes a sequence of runs
    # decodable at all. Without a length the reader cannot know a third run
    # follows the second: the first version walked runs until the *group
    # count* ran out, read one run, and treated the rest of the levels as
    # column data. Every page after a first run decoded as garbage.
    #
    # RLE wins when a run is long enough to pay for its header: eight or
    # more identical values cost a length plus one byte as RLE, against
    # eight bytes bit-packed — and a shorter run is padded to eight anyway,
    # so the run is RLE exactly where the format makes it cheaper.
    def encode_levels(values)
      body = +"".b
      body << varint(1) # one group
      i = 0
      n = values.length
      while i < n
        run = 1
        run += 1 while i + run < n && values[i + run] == values[i]
        if run >= 8
          body << run_header(run, false)
          body << (values[i] & 0xFF).chr
          i += run
        else
          # Take the short run plus following values up to a multiple of 8,
          # so the bit-packed run is as full as it can be.
          take = run
          take += 1 while take < 8 && i + take < n
          chunk = values[i, take]
          chunk += [0] * ((8 - (chunk.length % 8)) % 8)
          body << run_header(chunk.length, true)
          body << bitpack(chunk)
          i += take
        end
      end
      [body.bytesize].pack("l<") + body
    end

    # Decode a length-prefixed level stream to exactly `count` values. A
    # bit-packed run holds a multiple of 8 values, eight to a byte; an RLE
    # run is `len` copies of one byte.
    def decode_levels(bytes, count)
      out = []
      len = bytes.byteslice(0, 4).unpack1("l<")
      body = bytes.byteslice(4, len)
      pos = 0
      group_count, pos = read_varint(body, pos)
      # A group is a *sequence* of runs, not one run: the encoder packs as
      # many as the data needs, and the group ends where its bytes end.
      # Looping once per group read the first run of every page and dropped
      # the rest — a level stream that decoded to a correct prefix and then
      # nothing, which is a page that reads as half the rows it has.
      group_count.times do
        while pos < body.bytesize
          header, pos = read_varint(body, pos)
        len = header >> 1
        if (header & 1) == 1
          # The run length counts *values*, eight to a byte. Reading one
          # byte per value runs off the end of the page; reading bit 0 of
          # each byte turns a page of 1,0,1 into 1,1,1.
          (len / 8).times do
            b = body.getbyte(pos)
            raise ArgumentError, "parquet: truncated bit-packed run" if b.nil?

            pos += 1
            8.times { |bit| out << ((b >> bit) & 1) }
          end
        else
          val = body.getbyte(pos)
          raise ArgumentError, "parquet: truncated RLE run" if val.nil?

          pos += 1
          len.times { out << val }
        end
        end
      end
      out[0, count]
    end

    # The total byte length of a length-prefixed level stream: the 4-byte
    # prefix plus the length it names.
    def level_stream_length(bytes, pos = 0)
      bytes.byteslice(pos, 4).unpack1("l<") + 4
    end

    def read_varint(bytes, pos)
      result = 0
      shift = 0
      loop do
        b = bytes.getbyte(pos)
        raise ArgumentError, "parquet: truncated varint" if b.nil?

        pos += 1
        result |= (b & 0x7F) << shift
        shift += 7
        break if (b & 0x80).zero?
      end
      [result, pos]
    end
  end

  # PLAIN encoding for the fixed-width types.
  module Plain
    module_function

    def pack(type, values)
      fmt = ParquetType::PACK[type]
      raise ArgumentError, "parquet: no PLAIN pack for type #{type}" if fmt.nil?

      out = +"".b
      values.each { |v| out << [v].pack(fmt) }
      out
    end

    def unpack(type, bytes, count)
      fmt = ParquetType::PACK[type]
      raise ArgumentError, "parquet: no PLAIN unpack for type #{type}" if fmt.nil?

      size = (fmt == "e" || fmt == "l<") ? 4 : 8
      out = []
      count.times do |i|
        chunk = bytes.byteslice(i * size, size)
        raise ArgumentError, "parquet: truncated PLAIN page" if chunk.nil? || chunk.bytesize < size

        out << chunk.unpack1(fmt)
      end
      out
    end

    # BYTE_ARRAY is length-prefixed: a 4-byte LE length then the bytes. A
    # string column is the common case and this is its encoding.
    def pack_bytes(values)
      out = +"".b
      values.each do |v|
        b = v.to_s.dup.force_encoding(Encoding::BINARY)
        out << [b.bytesize].pack("l<")
        out << b
      end
      out
    end

    def unpack_bytes(bytes, count)
      out = []
      pos = 0
      count.times do
        len = bytes.byteslice(pos, 4)&.unpack1("l<")
        raise ArgumentError, "parquet: truncated BYTE_ARRAY page" if len.nil?

        pos += 4
        out << bytes.byteslice(pos, len).to_s.force_encoding(Encoding::UTF_8)
        pos += len
      end
      out
    end
  end
end