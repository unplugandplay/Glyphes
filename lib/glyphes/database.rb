require "glyphes/ident"
require "glyphes/import_export"

# glyphes — Database (M0 surface; RUBY.md §3).
#
# M0 rule (RUBY.md Y1): this translates and marshals. It caches nothing,
# holds nothing between calls, and materializes nothing behind the
# caller's back. Every method issues exactly one engine call.

module Glyphes
  # The single choke point for status -> exception (RUBY.md §2), so no
  # call site can forget the check and no call site can
  # rescue-and-return-nil by accident.
  #
  # Its own module rather than a `module_function` directly in Glyphes:
  # that would also install a private instance method on every class
  # nested under Glyphes, and `Database#check!` would shadow it.
  module Guard
    module_function

    def check!(status, context)
      return status if status == FFI::GLY_OK

      name = ErrorMapping::NAMES[status] || "GLY_STATUS(#{status})"
      detail = FFI.last_error_message
      message = "#{context}: #{name}"
      message = "#{message}: #{detail}" unless detail.empty?

      klass = ErrorMapping::BY_STATUS[status] || InternalError
      raise klass.new(message, status: status, detail: detail)
    end
  end

  class Database
    # M9: import/export (RUBY.md §6). One transaction per file, batched
    # exec, unknown columns refused (R11).
    include ImportExport

    # GlyHandle as an opaque integer. Never 0 for a live database: 0 is
    # the sentinel the engine treats as "no handle", so a Ruby nil and an
    # engine 0 mean the same thing and `closed?` is the honest test.
    attr_reader :handle

    attr_reader :path

    def self.open(path, create: false, readonly: false,
                  snapshot: false, memory: false)
      db = new
      db.send(:init, path, create: create, readonly: readonly,
                         snapshot: snapshot, memory: memory)
      return db unless block_given?

      begin
        yield db
      ensure
        db.close unless db.closed?
      end
      # Return the Database, not the block's value: `open` is a
      # constructor, and a caller who checks `db.closed?` on the result
      # is asking whether the block form worked. Both forms answering
      # with a Database also means `Database.open(x) { }` and
      # `Database.open(x)` are interchangeable for a caller that keeps
      # the result.
      db
    end

    # ':memory:' is sugar for the open mode rather than a special path,
    # so the engine sees one code path (ABI.md B1: one definition).
    def self.memory
      open(":memory:")
    end

    def initialize
      @handle = 0
      @closed = false
      @path = nil
      @tx = 0
      @tx_depth = 0
    end

    def closed?
      @closed
    end

    # ---- M0 surface ------------------------------------------------

    # GlyStat as a Hash. Every counter is present, so a caller can
    # subscript without a nil check (RUBY.md §3.2).
    def stat
      out = FFI::Stat.new
      Guard.check!(FFI::glyphes_stat(@handle, out.pointer), "stat")
      {
        nodes: out[:nodes],
        edges: out[:edges],
        labels: out[:labels],
        rel_types: out[:rel_types],
        properties: out[:properties],
        bytes_resident: out[:bytes_resident],
        wal_bytes: out[:wal_bytes],
        generation: out[:generation]
      }
    end

    def close
      return if @closed

      # An open transaction is rolled back by the engine before the
      # database goes away, so `ensure`-driven cleanup on the exception
      # path cannot leave a write transaction dangling.
      Guard.check!(FFI::glyphes_close(@handle), "close")
      @closed = true
      @handle = 0
      @tx = 0
      @tx_depth = 0
    end

    # ---- M3 surface: transactions ---------------------------------

    # RUBY.md §3.1. The block returning normally commits; raising rolls
    # back and the exception continues to the caller. Nothing is
    # swallowed in either direction.
    def transaction
      # Nested calls join the outer transaction rather than opening a
      # second one: savepoints are not in 0.1 (TXN.md X14), and the
      # Rails-shaped reading is that an inner `transaction` is a no-op
      # that still runs its block.
      return yield if @tx_depth.positive?

      if @closed
        raise ClosedError.new("transaction: database is closed",
                              status: FFI::GLY_ERR_CLOSED)
      end

      out = FFI::MemoryPointer.new(:uint64)
      # GLY_ERR_BUSY lands here rather than waiting (TXN.md §1): a Ruby
      # thread that is already writing would rather raise than silently
      # stall a request.
      Guard.check!(FFI::glyphes_tx_begin(@handle, out), "transaction")
      tx = out.read_uint64

      # Published before the block runs, so `tx_info` and
      # `in_transaction?` answer truthfully inside it.
      @tx = tx
      @tx_depth = 1

      committed = false
      begin
        result = yield
        Guard.check!(FFI::glyphes_tx_commit(@handle, tx), "commit")
        committed = true
        result
      ensure
        unless committed
          # Best-effort, and deliberately not guarded by Guard.check!:
          # raising from here would replace whatever exception is already
          # unwinding. A failure means the transaction was already
          # finished, which the engine has also already accounted for.
          begin
            FFI::glyphes_tx_rollback(@handle, tx)
          rescue StandardError
            nil
          end
        end
        @tx = 0
        @tx_depth = 0
      end
    end

    # True while a `transaction` block is open on this handle.
    def in_transaction?
      @tx_depth.positive?
    end

    # GlyTxInfo for the open transaction: what it has written so far.
    # Raises rather than returning zeros when there is none, because a
    # zeroed info for a transaction that does not exist is exactly the
    # kind of plausible-looking wrong answer this library avoids.
    def tx_info
      raise ClosedError.new("tx_info: no transaction is open",
                            status: FFI::GLY_ERR_STALE) unless in_transaction?

      out = FFI::TxInfo.new
      Guard.check!(FFI::glyphes_tx_info(@tx, out.pointer), "tx_info")
      {
        id: out[:id],
        nodes_written: out[:nodes_written],
        edges_written: out[:edges_written],
        properties_written: out[:properties_written],
        wal_bytes: out[:wal_bytes]
      }
    end

    # ---- M4 surface: queries ---------------------------------------

    # Prepares a read query. Returns a `Statement`: single-use, `each_slice`
    # over it, `close` when done (or let the block form close it).
    def prepare(cypher, params = {})
      raise ClosedError.new("prepare: database is closed",
                            status: FFI::GLY_ERR_CLOSED) if @closed
      out = FFI::MemoryPointer.new(:uint64)
      Guard.check!(FFI::glyphes_prepare(@handle, cypher.to_s,
                                        JSON.generate(params), out), "prepare")
      st = out.read_uint64

      # The column names come back NUL-separated in one engine-owned block,
      # copied here at the only point that reads it (ABI.md §7).
      count = FFI::MemoryPointer.new(:uint32)
      Guard.check!(FFI::glyphes_stmt_columns_count(st, count), "stmt_columns")
      n = count.read_uint32
      cols = []
      if n.positive?
        out_ptr = FFI::MemoryPointer.new(:pointer)
        len = FFI::MemoryPointer.new(:uint64)
        Guard.check!(FFI::glyphes_stmt_columns(st, out_ptr, len, nil),
                     "stmt_columns")
        block = out_ptr.read_pointer
        cols = block.read_string(len.read_uint64).split("\0", -1)[0...n]
      end
      Statement.new(st, cols, @handle, cypher.to_s,
                      JSON.generate(params))
    end

    # Runs a read query and returns a `Result`. Fully materialised, which is
    # the shape most callers want; `prepare` is there for the streaming one.
    def query(cypher, params = {})
      st = prepare(cypher, params)
      begin
        rows = []
        st.each_slice(256) { |batch| rows.concat(batch) }
        Result.new(st.columns, rows)
      ensure
        st.close
      end
    end

    # ---- M5 surface: writes -----------------------------------------

    # Runs a write query and returns the number of entities that landed:
    # nodes, relationships, deletes, updates. Property writes do not count.
    #
    # Autocommit by default; inside a `transaction` block it joins that
    # transaction, so the block's rollback undoes it (ABI.md §"mutation
    # without a transaction").
    def exec(cypher, params = {})
      raise ClosedError.new("exec: database is closed",
                            status: FFI::GLY_ERR_CLOSED) if @closed
      out = FFI::MemoryPointer.new(:int64)
      Guard.check!(FFI::glyphes_exec(@handle, cypher.to_s,
                                    JSON.generate(params), out), "exec")
      out.read_int64
    end

    # The write door that also hands back the id of the first created
    # node (`CREATE … RETURN id(n) AS id`). One statement, one crossing:
    # reading the id back with a second query would be R5's extra crossing
    # and would race a concurrent writer for "the node I just made".
    # Returns [rows_affected, new_id].
    def exec_returning(cypher, params = {})
      raise ClosedError.new("exec_returning: database is closed",
                            status: FFI::GLY_ERR_CLOSED) if @closed

      out_n = FFI::MemoryPointer.new(:int64)
      out_id = FFI::MemoryPointer.new(:int64)
      Guard.check!(FFI::glyphes_exec_returning(@handle, cypher.to_s,
                                                JSON.generate(params),
                                                out_n, out_id),
                   "exec_returning")
      [out_n.read_int64, out_id.read_int64]
    end

    # The integrity report as a String, copied out of engine storage at
    # the only point that reads it (ABI.md §7). Read-only: it sweeps the
    # store's invariants S1-S10 and reports what the last open had to
    # recover. It never writes, so calling it on a live database is safe.
    # ---- indices (M6.1) ----------------------------------------------
    #
    # Only the range index is built so far; asking for text or vector says
    # so rather than creating something that will not answer a query.

    INDEX_KINDS = { range: 0, text: 1, vector: 2 }.freeze

    def index_create(kind:, property:, label: nil, **options)
      raise ArgumentError, "index kind is #{kind.inspect}" unless INDEX_KINDS.key?(kind)
      opts = { "property" => property }
      opts["label"] = label if label
      opts.merge!(options.transform_keys(&:to_s))
      Guard.check!(FFI::glyphes_index_create(@handle, INDEX_KINDS[kind],
                                             JSON.generate(opts)),
                   "index_create")
      on_schema_change
      label ? "#{label}.#{property}" : property
    end

    def index_drop(name)
      Guard.check!(FFI::glyphes_index_drop(@handle, name), "index_drop")
      on_schema_change
      true
    end

    # A schema change invalidates the model layer's compiled-statement
    # caches (RUBY.md §5.2). Reached by name rather than by a require, so
    # `Database` still loads without the model layer — the layer is optional
    # and `Database` is not allowed to depend on it.
    def on_schema_change
      return unless defined?(Glyph::Base)

      Glyph::Base.clear_all_statement_caches!
    end

    def index_list
      buf = FFI::MemoryPointer.new(:char, 256)
      len = FFI::MemoryPointer.new(:uint64)
      status = FFI::glyphes_index_list(@handle, buf, 256, len)
      needed = len.read_uint64
      # A short buffer is a size, not an error: ask again with what it said.
      # Two calls, and the second is the only one that writes.
      if status == 0 && needed > 255
        buf = FFI::MemoryPointer.new(:char, needed + 1)
        Guard.check!(FFI::glyphes_index_list(@handle, buf, needed + 1, len),
                     "index_list")
      else
        Guard.check!(status, "index_list")
      end
      JSON.parse(buf.read_string)
    end

    def index_rebuild(name)
      Guard.check!(FFI::glyphes_index_rebuild(@handle, name), "index_rebuild")
      true
    end

    def index_build(name)
      Guard.check!(FFI::glyphes_index_build(@handle, name), "index_build")
      true
    end

    # Checkpoint at a transaction boundary (WAL.md §6, pin W11): truncate
    # shortens the log to the snapshot's LSN, fsync makes the snapshot's
    # bytes durable behind the atomic rename. Both are opt-in because both
    # cost time the caller may not want on a hot path.
    def checkpoint(truncate: false, fsync: true)
      flags = 0
      flags |= FFI::GLY_CHECKPOINT_TRUNCATE if truncate
      flags |= FFI::GLY_CHECKPOINT_FSYNC if fsync
      Guard.check!(FFI::glyphes_checkpoint(@handle, flags), "checkpoint")
      true
    end

    def wal_size
      out = FFI::MemoryPointer.new(:uint64)
      Guard.check!(FFI::glyphes_wal_size(@handle, out), "wal_size")
      out.read_uint64
    end

    # Checkpoint-then-copy (WAL.md §3), so the destination is a consistent
    # pair rather than a file copied while a transaction was mid-commit.
    def backup(dest)
      Guard.check!(FFI::glyphes_backup(@handle, dest), "backup")
      dest
    end

    # Rebuild every index from live records and write the snapshot
    # (INDEX.md I14). O(store): explicit on purpose, because close must not
    # do it (a full snapshot on every Ruby `ensure` is the worst possible
    # default for a per-request handle).
    def vacuum
      Guard.check!(FFI::glyphes_vacuum(@handle), "vacuum")
      true
    end

    # The schema as a Hash. `labels:`/`properties:`/`indexes:` default to
    # true — the sections are switchable because a host that only wants
    # index names should not pay to walk a million property keys, but the
    # default is "everything", which is what `db.schema` with no arguments
    # means in the docs.
    def schema(labels: true, properties: true, indexes: true)
      what = 0
      what |= FFI::GLY_SCHEMA_LABELS if labels
      what |= FFI::GLY_SCHEMA_PROPERTIES if properties
      what |= FFI::GLY_SCHEMA_INDEXES if indexes
      len = FFI::MemoryPointer.new(:size_t)
      FFI::glyphes_schema(@handle, what, FFI::MemoryPointer.new(:char, 1), 0, len)
      buf = FFI::MemoryPointer.new(:char, len.read_uint64)
      Guard.check!(FFI::glyphes_schema(@handle, what, buf,
                                      len.read_uint64, len), "schema")
      JSON.parse(buf.read_string(len.read_uint64 - 1))
    end

    # Process-wide allocator and arena counters (handle-free by ABI
    # design): the arena bytes and generation of every open database.
    def stats
      len = FFI::MemoryPointer.new(:size_t)
      FFI::glyphes_stats(FFI::MemoryPointer.new(:char, 1), 0, len)
      buf = FFI::MemoryPointer.new(:char, len.read_uint64)
      Guard.check!(FFI::glyphes_stats(buf, len.read_uint64, len), "stats")
      JSON.parse(buf.read_string(len.read_uint64 - 1))
    end

    def integrity_check
      out = FFI::MemoryPointer.new(:pointer)
      Guard.check!(FFI::glyphes_integrity_check(@handle, out),
                   "integrity_check")
      ptr = out.read_pointer
      ptr.null? ? "" : ptr.read_string
    end

    def inspect
      state = @closed ? "closed" : "open"
      "#<Glyphes::Database #{@path.inspect} #{state}>"
    end
    alias to_s inspect

    private

    def init(path, create:, readonly:, snapshot:, memory:)
      mode = 0
      mode |= FFI::GLY_OPEN_READONLY if readonly
      mode |= FFI::GLY_OPEN_CREATE   if create
      mode |= FFI::GLY_OPEN_MEMORY   if memory
      mode |= FFI::GLY_OPEN_SNAPSHOT if snapshot

      # A FFI out-param for a uintptr_t out-param. The engine writes the
      # handle here; it is a scalar, so it comes back as an Integer.
      out = FFI::MemoryPointer.new(:uint64)

      Guard.check!(FFI::glyphes_open(path.to_s, mode, out),
                   "open #{path.inspect}")
      @handle = out.read_uint64
      @path = path.to_s
    end
  end
end
