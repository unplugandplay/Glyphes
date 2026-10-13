# glyphes — Statement, Cell and Result (RUBY.md §4, ABI.md §1).
#
# The only file besides ffi.rb that touches a cell's bytes. `Cell` is a lazy
# view over the engine's arena memory: reading `cell.value` copies out of
# statement memory at that moment, and the statement guarantees the memory
# lives until the next `step` or `close` (ABI.md B3).
#
# `each_slice` is the primitive and `each` is sugar over it, because per-row
# FFI crossings are the 30x trap the ABI was designed against (ABI.md B2).

module Glyphes
  # One value of one row. Held by a `Result`; constructing one by hand is
  # not a thing the API supports and the constructor is deliberately not
  # exposed.
  class Cell
    attr_reader :tag, :len

    TAG_NAMES = {
      FFI::GLY_NULL => :null,   FFI::GLY_BOOL => :bool,
      FFI::GLY_INT => :int,     FFI::GLY_FLOAT => :float,
      FFI::GLY_STRING => :string, FFI::GLY_BYTES => :bytes,
      FFI::GLY_VECTOR => :vector, FFI::GLY_NODE => :node,
      FFI::GLY_EDGE => :edge,   FFI::GLY_PATH => :path,
      FFI::GLY_LIST => :list,   FFI::GLY_MAP => :map
    }.freeze

    def initialize(struct, stmt, handle = nil)
      @raw = struct
      @stmt = stmt
      # The database handle, for the two tags that are *views* (node, edge):
      # a Node resolves its labels against the store, not against whatever
      # the row happened to carry. A read-only statement from a query has
      # one; a statement built by a test without a database does not, and
      # `Node#labels` then raises ClosedError rather than inventing an id.
      @handle = handle || (stmt.respond_to?(:db_handle) ? stmt.db_handle : nil)
      @tag = TAG_NAMES[struct[:tag]] || struct[:tag]
      @len = struct[:len]
    end

    def null?
      @tag == :null
    end

    def node? = @tag == :node
    def edge? = @tag == :edge

    # The value as a Ruby object. One copy per call, from statement memory —
    # memoising here would keep statement memory alive past `close`, which
    # is the exact bug ABI.md B3 exists to prevent.
    def value
      case @tag
      when :null   then nil
      when :bool   then @raw[:aux] != 0
      when :int    then int_of(@raw[:aux])
      when :float  then [@raw[:aux]].pack("Q").unpack1("D")
      when :string, :bytes then text
      when :node   then Glyphes::Node.new(@handle, int_of(@raw[:aux]))
      when :edge   then Glyphes::Edge.new(@handle, int_of(@raw[:aux]))
      when :vector then Glyphes::Vector.new(vector)
      when :list, :map then JSON.parse(text)
      when :path   then path
      else @raw[:aux]
      end
    end

    def to_s
      case @tag
      when :string, :bytes then text
      when :null then ""
      else value.to_s
      end
    end

    def inspect
      "#<Glyphes::Cell #{@tag}=#{value.inspect}>"
    end

    private

    def int_of(word)
      # A uint64 word holding a signed i64. `pack`/`unpack1` rather than
      # arithmetic, because the wrap-around case (`-1`) is not reachable by
      # subtraction from 2**64 without going through a bignum.
      [word].pack("Q").unpack1("q")
    end

    def text
      # `len` is the byte length for string/bytes/list/map cells; the engine
      # NUL-terminates past it, and the read is bounded by `len` either way.
      out = FFI::MemoryPointer.new(:char, @len + 1)
      written = FFI::MemoryPointer.new(:uint64)
      Guard.check!(FFI::glyphes_cell_text(@raw.pointer, out, @len + 1, written),
                   "cell_text")
      out.read_string(@len)
    end

    def vector
      # `len` is the dimension for a vector cell; the payload is that many
      # float64s in statement memory (execute.nim's toCell). The property
      # model stores f32, so this is the f64 widening the ABI promises.
      @raw[:ptr].read_array_of_float64(@len)
    end

    # A path crosses as three parallel arrays in statement memory, and the
    # component accessors are the bounds-checked reads against them (ABI.md
    # §2's settled representation). Ruby never holds the raw pointers: it
    # copies three plain arrays, so a Path outlives its batch safely —
    # which is the one deviation from "views borrow", and it is the safe
    # direction: a path is at most a few hundred components, while
    # borrowing would tie the value's lifetime to a batch boundary.
    def path
      view = FFI::PathStruct.new
      Guard.check!(FFI::glyphes_cell_path(@raw.pointer, view), "cell_path")
      count = view[:count]
      nodes = Array.new(count) do |i|
        out = FFI::MemoryPointer.new(:int64)
        Guard.check!(FFI::glyphes_cell_path_node(@raw.pointer, i, out),
                     "cell_path_node")
        out.read_int64
      end
      edges = []
      dirs = []
      (count - 1).times do |i|
        eid = FFI::MemoryPointer.new(:int64)
        dir = FFI::MemoryPointer.new(:uint8)
        Guard.check!(FFI::glyphes_cell_path_edge(@raw.pointer, i, eid, dir),
                     "cell_path_edge")
        edges << eid.read_int64
        dirs << dir.read_uint8
      end
      Glyphes::Path.new(nodes, edges, dirs)
    end
  end

  # A materialised batch of rows: `each_slice` hands these out, `each`
  # flattens them. Rows are Ruby arrays of values by the time a Result
  # exists — the cell views are consumed at slice time, while the statement
  # memory is still live.
  class Result
    include Enumerable

    attr_reader :columns

    def initialize(columns, rows)
      @columns = columns
      @rows = rows
    end

    def each
      return enum_for(:each) unless block_given?
      @rows.each { |r| yield r }
      self
    end

    def size = @rows.size
    def length = @rows.size
    def empty? = @rows.empty?

    def [](i) = @rows[i]

    def to_a = @rows.dup

    def inspect
      "#<Glyphes::Result #{@columns.inspect} #{size} rows>"
    end
  end

  # One prepared query. Single-use: `step` until false, then `close`. Re-running
  # means `Database#prepare` again — EXEC.md §1 pins statements as init-once,
  # and the engine's `glyphes_stmt_reset` says so with
  # `GLY_ERR_UNSUPPORTED` rather than half-doing it.
  class Statement
    attr_reader :columns

    def initialize(handle, columns, db_handle = nil, sql = nil, params_json = nil)
      @handle = handle
      @db_handle = db_handle
      # Kept for `reset` only — a re-prepare needs the query text and the
      # parameters it was prepared with. Nothing else reads them, and they
      # are the statement's own inputs rather than engine state (the engine
      # keeps neither: `init`, then `next` until false, and rewind is not a
      # thing a single-use operator has — EXEC.md §0).
      @sql = sql
      @params_json = params_json
      @columns = columns
      @closed = false
      @exhausted = false
      ## Reused across every step. Allocating these per call put two FFI
      ## pointer allocations on every row of every stream, which is the
      ## kind of cost that hides inside a "fast" per-row path until
      ## someone streams a million rows.
      @cells = FFI::MemoryPointer.new(FFI::Cell, columns.size)
      @rows = FFI::MemoryPointer.new(:uint64)
      ## A Statement the GC reaps without `close` holds the engine's
      ## reader count forever — the same wedge an unclosed file handle
      ## causes, except the blocked side is every future write on the
      ## database. The finalizer closes through the engine directly: the
      ## engine answers GLY_ERR_STALE for an already-closed handle, which
      ## is exactly the case we want to ignore here.
      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
    end

    def self.finalizer(handle)
      proc do
        FFI.glyphes_stmt_close(handle) unless handle.zero?
      rescue StandardError
        nil
      end
    end

    # The *database* handle, so a cell can build Node/Edge views (M7).
    # Distinct from @handle, which is the statement's own handle — the two
    # are different handles to different objects, and passing the statement
    # handle where a database handle belongs produces a view that reads
    # another statement's state.
    attr_reader :db_handle

    def closed? = @closed

    def close
      return if @closed
      Guard.check!(FFI::glyphes_stmt_close(@handle), "stmt_close")
      @closed = true
      @handle = 0
    end

    # Fills one Ruby row of plain values, or nil at end of stream. One FFI
    # crossing per row — the engine's step contract is one row per call
    # (ABI.md B2), so `each_slice`'s batching is about Ruby object
    # conversion cadence, not crossing count.
    #
    # Private, and the privacy is R3 rather than a preference: a per-row
    # FFI path in the public API is exactly what the gate forbids, and
    # `step` was public only because nothing had made the call. `each_slice`
    # is the primitive; `each` builds on it.
    private def step
      return nil if @closed || @exhausted
      cells = @cells
      rows = @rows
      status = FFI::glyphes_stmt_step(@handle, cells, @columns.size, rows)
      case status
      when FFI::GLY_DONE
        @exhausted = true
        return nil
      when FFI::GLY_MORE
        # One row per step (ABI.md B2); `out_rows` counts rows in the batch,
        # and the row's width is the statement's column count.
        width = @columns.size
        row = Array.new(width) do |i|
          Cell.new(FFI::Cell.new(cells + i * FFI::Cell.size), self).value
        end
        return row
      else
        Guard.check!(status, "stmt_step")
        nil
      end
    end

    # Rows in groups of `size`, materialising Ruby values while the
    # statement memory for that slice is still live (ABI.md B2, B3). The
    # grouping bounds how many converted rows exist at once; it is not
    # fewer FFI crossings — `step` is one crossing per row by contract.
    def each_slice(size)
      raise ArgumentError, "slice size must be positive" unless size.positive?
      return enum_for(:each_slice, size) unless block_given?
      until @exhausted || @closed
        batch = []
        size.times do
          row = step
          break if row.nil?
          batch << row
        end
        yield batch unless batch.empty?
        break if batch.empty?
      end
      self
    end

    # Materialize, capped. The cap is not a convenience limit: it is what
    # keeps `to_a` from being the line between a query and a gigabyte
    # (RUBY.md §4). Exceeding it raises LimitError rather than returning a
    # truncated array — a truncated result that looks complete is the
    # failure mode this whole document keeps coming back to.
    def to_a(max = 100_000)
      out = []
      each_slice(256) do |batch|
        out.concat(batch)
        if out.size > max
          raise LimitError.new(
            "to_a: more than #{max} rows (use each_slice or count to stream)",
            status: FFI::GLY_ERR_LIMIT)
        end
      end
      out
    end

    # The first row, or nil — then the statement is drained, because the
    # engine has no "stop after one" and a cursor left open pins a
    # snapshot. `first` is therefore a *consuming* convenience; a caller
    # who wants the rest uses `to_a` / `each_slice`, not `first` in a loop.
    def first
      row = step
      close
      row
    end

    # Drain, counting, without materializing (RUBY.md §4: "the right way to
    # answer 'how many', and the difference between O(1) memory and O(n)").
    def count
      n = 0
      each_slice(256) { |batch| n += batch.size }
      n
    end

    # Re-execute from the top. The engine's statements are single-use
    # (`init`, then `next` until false — there is no rewind, because a
    # query that iterates twice gets two executions), so this is close +
    # re-prepare of the same query, not a cursor reset: two executions, two
    # snapshots, and the second sees whatever committed in between. The name
    # says "reset" because that is what a caller means by it; the semantics
    # are documented rather than pretended away.
    def reset
      raise ClosedError.new("reset: statement is closed",
                            status: FFI::GLY_ERR_CLOSED) if @closed

      Guard.check!(FFI::glyphes_stmt_close(@handle), "stmt_close")
      out = FFI::MemoryPointer.new(:uint64)
      Guard.check!(FFI::glyphes_prepare(@db_handle, @sql, @params_json, out),
                   "prepare")
      @handle = out.read_uint64
      @closed = false
      @exhausted = false
      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
      self
    end

    def inspect
      "#<Glyphes::Statement      "#<Glyphes::Statement #{@columns.inspect} #{state}>"
    end
  end
end