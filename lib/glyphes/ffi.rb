# glyphes — the gem's loadable surface.
#
# The only file that knows FFI exists. Everything else calls methods on
# Database and Statement, so an ABI change lands here first.
#
# Symbol names carry no prefix. `nm` on Mach-O displays C symbols with a
# leading underscore, so `nm -gU` shows `_glyphes_open` while the name
# FFI must ask for is `glyphes_open`. Searching the nm output for the
# name you pass here and finding nothing is a confusing ten minutes.

require "ffi"

module Glyphes
  module FFI
    extend ::FFI::Library

    # Re-export the FFI primitives this module shadows by its own name.
    # `Glyphes::FFI::MemoryPointer` inside Glyphes resolves here, so
    # without these it is a NameError rather than the obvious fix.
    MemoryPointer = ::FFI::MemoryPointer
    Pointer       = ::FFI::Pointer
    Struct        = ::FFI::Struct

    # Search order: an env override for development, then the packaged
    # path, then the local build output.
    lib =
      if (override = ENV["GLYPHES_LIB"])
        override
      else
        candidates = [
          File.expand_path("../../lib/libglyphes.so", __dir__), # repo build
          File.expand_path("libglyphes.so", __dir__)            # gem root
        ]
        found = candidates.find { |p| File.exist?(p) }
        raise LoadError, <<~MSG if found.nil?
          glyphes: libglyphes not found. Build it with `nimble build`.

          Looked in:
          #{candidates.map { |c| "  #{c}" }.join("\n")}

          Set GLYPHES_LIB to override.
        MSG
        found
      end

    ffi_lib lib

    # ---- types, mirroring src/glyphes.h ---------------------------
    #
    # Layouts here and in the C header must agree exactly. The load-time
    # assertion below is what makes a mismatch loud instead of a slow
    # memory corruption discovered in production (ABI.md B1).

    class Cell < Struct
      layout :tag, :uint32,
             :len, :uint32,
             :ptr, :pointer,
             :aux, :uint64
    end

    class PathStruct < Struct
      layout :count, :uint32,
             :nodes, :pointer,
             :edges, :pointer,
             :dirs, :pointer
    end

    class Path < Struct
      layout :count, :uint32,
             :nodes, :pointer,
             :edges, :pointer,
             :dirs,  :pointer
    end

    class Stat < Struct
      layout :nodes,          :uint64,
             :edges,          :uint64,
             :labels,         :uint64,
             :rel_types,      :uint64,
             :properties,     :uint64,
             :bytes_resident, :uint64,
             :wal_bytes,      :uint64,
             :generation,     :uint64
    end

    class TxInfo < Struct
      layout :id,                 :uint64,
             :nodes_written,      :uint64,
             :edges_written,      :uint64,
             :properties_written, :uint64,
             :wal_bytes,          :uint64
    end

    # ---- durability / node views (M7) ----
    attach_function :glyphes_checkpoint, %i[uint64 int32], :int32
    attach_function :glyphes_wal_size, %i[uint64 pointer], :int32
    attach_function :glyphes_backup, %i[uint64 string], :int32
    attach_function :glyphes_vacuum, %i[uint64], :int32
    attach_function :glyphes_exec_returning, %i[uint64 string string pointer pointer], :int32
    attach_function :glyphes_schema, %i[uint64 int32 pointer size_t pointer],
                    :int32
    attach_function :glyphes_stats, %i[pointer size_t pointer], :int32
    attach_function :glyphes_node_labels, %i[uint64 int64 pointer size_t
                                            pointer], :int32
    attach_function :glyphes_node_props, %i[uint64 int64 pointer size_t
                                           pointer], :int32
    attach_function :glyphes_edge_info, %i[uint64 int64 pointer size_t
                                          pointer], :int32
    attach_function :glyphes_edge_props, %i[uint64 int64 pointer size_t
                                           pointer], :int32

    # The cap protocol every JSON-returning call shares: ask with a zero
    # cap, the engine reports the length without writing, ask again with
    # what it said. Two calls, and the second is the only one that writes —
    # the same shape `Database#index_list` has used since M6.1, which is
    # why it is one method here rather than five copies of the dance.
    def self.json_call(handle, fn, id, context)
      lenp = FFI::MemoryPointer.new(:size_t)
      probe = FFI::MemoryPointer.new(:char, 1)
      # The probe *is* the call that can fail: a node that does not exist
      # answers here, before any buffer is allocated, and its status must
      # map to an exception the same way the second call's would. Ignoring
      # it left the "does not exist" case raising a bare ArgumentError from
      # the exception constructor. But the probe answers GLY_MORE on
      # success (cap 0 < the length it is reporting) — GLY_MORE is "buffer
      # too small, here is the size", not a failure, and only a status that
      # is neither OK nor MORE is an error at this stage.
      probe_status = send(fn, handle, id, probe, 0, lenp)
      if probe_status != FFI::GLY_OK && probe_status != FFI::GLY_MORE
        Guard.check!(probe_status, context)
      end
      needed = lenp.read_uint64
      raise Glyphes::Error.new("#{context}: empty response",
                                status: FFI::GLY_ERR) if needed.zero?

      buf = FFI::MemoryPointer.new(:char, needed)
      # `Guard.check!` maps the status and reads the engine's message, and
      # the exception classes take the status as a keyword (errors.rb), so
      # a bare `Guard.check!` here would construct `SqlError.new(msg)`
      # without it. That is the whole reason this helper raises through
      # Guard rather than reading `last_error_message` by hand.
      Guard.check!(send(fn, handle, id, buf, needed, lenp), context)
      buf.read_string(lenp.read_uint64 - 1)
    end

    GLY_CHECKPOINT_TRUNCATE = 1
    GLY_CHECKPOINT_FSYNC    = 2
    GLY_SCHEMA_LABELS      = 4
    GLY_SCHEMA_PROPERTIES  = 8
    GLY_SCHEMA_INDEXES     = 16

    # ---- status codes, from GlyStatus ----------------------------

    GLY_OK              = 0
    GLY_MORE            = 1
    GLY_DONE            = 2
    GLY_ERR             = -1
    GLY_ERR_CLOSED      = -2
    GLY_ERR_STALE       = -3
    GLY_ERR_SQL         = -4
    GLY_ERR_CONSTRAINT  = -5
    GLY_ERR_IO          = -6
    GLY_ERR_READONLY    = -7
    GLY_ERR_BUSY        = -8
    GLY_ERR_LIMIT       = -9
    GLY_ERR_NOMEM       = -10
    GLY_ERR_UNSUPPORTED = -11
    # The file is damaged: a CRC or magic mismatch. Deliberately not the
    # torn tail, which is a frame that was never finished.
    GLY_ERR_CORRUPT = -12

    # ---- value tags, from GlyType ---------------------------------

    GLY_NULL   = 0
    GLY_BOOL   = 1
    GLY_INT    = 2
    GLY_FLOAT  = 3
    GLY_STRING = 4
    GLY_BYTES  = 5
    GLY_VECTOR = 6
    GLY_NODE   = 7
    GLY_EDGE   = 8
    GLY_PATH   = 9
    GLY_LIST   = 10
    GLY_MAP    = 11
    GLY_DATE   = 13   # days since 1970-01-01, in aux
    GLY_POINT  = 14   # two f64: x and y

    # ---- open modes, from GlyOpenMode ----------------------------

    GLY_OPEN_READONLY = 1 << 0
    GLY_OPEN_CREATE   = 1 << 1
    GLY_OPEN_MEMORY   = 1 << 2
    GLY_OPEN_SNAPSHOT = 1 << 3

    # ---- version ---------------------------------------------------

    attach_function :glyphes_version, %i[pointer pointer pointer], :int32

    # ---- error slot ------------------------------------------------

    # Returns char*, engine-owned and valid only until the next call on
    # this thread (ABI.md §2). Copied into a Ruby String here, at the one
    # place that reads it, so nothing downstream holds a pointer into the
    # engine's error slot.
    attach_function :glyphes_global_error, [], :pointer
    attach_function :glyphes_global_error_clear, [], :void

    def self.last_error_message
      ptr = glyphes_global_error
      ptr.nil? || ptr.null? ? "" : ptr.read_string
    end

    # ---- database (M0) --------------------------------------------

    # GlyHandle is a uintptr_t *scalar*, so it binds as :uint64, not as
    # :pointer. Binding it as :pointer passes the address of the FFI
    # object as the handle value, which fails as GLY_ERR_STALE at the
    # first call -- with a handle number that is plainly a heap address.
    attach_function :glyphes_open, %i[string int32 pointer], :int32
    attach_function :glyphes_close, [:uint64], :int32
    attach_function :glyphes_stat, %i[uint64 pointer], :int32

    # ---- transactions (M3) -----------------------------------------
    #
    # A GlyHandle is a uintptr_t scalar here too, so :uint64 for both the
    # database and the transaction. The out-param is a pointer to the
    # scalar, so a bare :pointer.

    # Index control (M6.1). `glyphes_index_list` follows the header's cap
    # protocol: pass a buffer and its size, read the full length back, and
    # retry with a bigger buffer when the first one was short.
    attach_function :glyphes_index_create, %i[uint64 int32 string], :int32
    attach_function :glyphes_index_drop, %i[uint64 string], :int32
    attach_function :glyphes_index_list, %i[uint64 pointer size_t pointer], :int32
    attach_function :glyphes_index_rebuild, %i[uint64 string], :int32
    attach_function :glyphes_index_build, %i[uint64 string], :int32

    attach_function :glyphes_tx_begin, %i[uint64 pointer], :int32
    attach_function :glyphes_tx_commit, %i[uint64 uint64], :int32
    attach_function :glyphes_tx_rollback, %i[uint64 uint64], :int32
    attach_function :glyphes_tx_info, %i[uint64 pointer], :int32

    # ---- statements (M4) -------------------------------------------
    #
    # A GlyHandle is a uintptr_t scalar, so :uint64 for both database and
    # statement. `glyphes_stmt_columns` returns a pointer to engine-owned
    # storage valid until the next call on this thread (same rule as the
    # error slot), so the binding copies it immediately.

    attach_function :glyphes_prepare, %i[uint64 string string pointer], :int32
    attach_function :glyphes_stmt_step, %i[uint64 pointer uint64 pointer], :int32
    attach_function :glyphes_stmt_columns, %i[uint64 pointer pointer pointer], :int32
    attach_function :glyphes_stmt_columns_count, %i[uint64 pointer], :int32
    attach_function :glyphes_stmt_close, [:uint64], :int32
    attach_function :glyphes_stmt_reset, [:uint64], :int32

    # The write door. Returns rows affected through `out_n`.
    attach_function :glyphes_exec, %i[uint64 string string pointer], :int32

    # ---- GLYPH QUERY: the surface a child types --------------------
    #
    # A GLYPH QUERY statement *is* a Cypher statement (ABI.md B11): the
    # same cells, the same accessors. The doors are here under their own
    # names so that a client that knows only the child's language need
    # not learn the engine's to read its rows.

    attach_function :glyphes_gq_compile,
                    %i[string string pointer uint64 pointer pointer uint64 pointer], :int32
    attach_function :glyphes_gq_prepare, %i[uint64 string string pointer], :int32
    attach_function :glyphes_gq_step, %i[uint64 pointer uint64 pointer], :int32
    attach_function :glyphes_gq_columns, %i[uint64 pointer pointer pointer], :int32

    # The one write GLYPH QUERY cannot express: two existing nodes, one
    # relationship.
    attach_function :glyphes_link, %i[uint64 int64 string int64 pointer], :int32
    attach_function :glyphes_link_props,
                    %i[uint64 int64 string int64 string pointer], :int32

    attach_function :glyphes_cell_text, %i[pointer pointer uint64 pointer], :int32
    attach_function :glyphes_cell_id, %i[pointer pointer], :int32
    attach_function :glyphes_cell_len, %i[pointer pointer], :int32

    # The report comes back as `const char *` into engine storage, valid
    # until the next call on this thread (ABI.md §7). Copied here, at the
    # one place that reads it, so no Ruby object holds a pointer into the
    # engine.
    attach_function :glyphes_integrity_check, %i[uint64 pointer], :int32

    # ---- follower (PRD-SHARED F2, surface plan S1) -----------------
    #
    # A read-only observer of a database's commit history. The handle is a
    # GlyHandle (uintptr_t scalar, so :uint64); out-params are pointers to
    # the scalar. `glyphes_follower_error` returns engine-owned storage with
    # the copy-immediately rule, same as the error slot. Deliberately
    # absent: any follower entry point that writes — there is none, and
    # that absence is the write-defense (SS2), so no Ruby method can forget
    # to guard a write that does not exist.

    attach_function :glyphes_follower_open, %i[string pointer], :int32
    attach_function :glyphes_follower_close, [:uint64], :int32
    attach_function :glyphes_follower_refresh, %i[uint64 pointer], :int32
    attach_function :glyphes_follower_head, %i[uint64 pointer], :int32
    attach_function :glyphes_follower_generation, %i[uint64 pointer], :int32
    attach_function :glyphes_follower_lsn, %i[uint64 pointer], :int32
    attach_function :glyphes_follower_error, [:uint64], :pointer

    # ---- load-time layout assertions ------------------------------
    #
    # A cgen or FFI layout change must fail here, loudly, at require
    # time. Without these the mismatch surfaces as a corrupted GlyCell
    # somewhere downstream, which is the worst possible failure mode for
    # a library living in someone else's process.

    # Hash rocket, not `Name:` -- inside a Hash literal `Cell: 24` is a
    # *symbol* key, so `klass.size` measured String#size on the symbol
    # and reported 7. The rocket keeps these as class objects.
    LAYOUT = {
      Cell   => 24, # u32 + u32 + ptr + u64
      Path   => 32, # u32 + 3 pointers, padded
      Stat   => 64, # 8 x u64
      TxInfo => 40  # 5 x u64
    }.freeze

    LAYOUT.each do |klass, expected|
      actual = klass.size
      next if actual == expected

      raise LoadError, <<~MSG
        glyphes: struct layout mismatch for #{klass.name}.
          expected #{expected} bytes (src/glyphes.h), FFI computed #{actual}.
          The engine and the binding disagree about memory layout.
          Rebuild the extension: `nimble build`.
      MSG
    end

    def self.check_layout!
      LAYOUT
    end
  end
end
