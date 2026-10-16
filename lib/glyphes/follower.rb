# glyphes — the follower (RUBY.md §4, PRD-SHARED F2, surface plan S2).
#
# A read-only observer of a database's commit history, for a Ruby host.
# The only file that knows a follower exists; everything else calls methods
# on Database and Statement. The class is a thin wrapper over the C ABI:
# every call crosses ffi.rb, so an ABI change lands there first, exactly as
# ffi.rb's header comment promises.
#
# The write-defense is the class's shape, not a check: there is no
# Follower#commit, no Follower#[]=, no Follower#delete. A follower cannot
# mutate the database it watches because it has no method that could. The
# e2e suite asserts these absences, so restoring a write would require
# adding a method *and* editing a test that asserts it is not there.
#
#   follower = Glyphes::Follower.open("graph.glyph")
#   follower.refresh        # => true if new commits were folded in
#   follower.head           # => newest commit id
#   follower.generation     # => the watermark generation
#   follower.unavailable    # => "" or why the watermark is missing
#   follower.close

module Glyphes
  class Follower
    # GlyHandle as an opaque integer, the same convention as Database:
    # 0 is the engine's "no handle" sentinel, so a Ruby nil and an engine
    # 0 mean the same thing and `closed?` is the honest test.
    attr_reader :handle

    def self.open(path)
      follower = new
      follower.send(:init, path)
      return follower unless block_given?

      begin
        yield follower
      ensure
        follower.close unless follower.closed?
      end
      follower
    end

    def closed?
      @handle.zero?
    end

    # Poll the watermark and fold in whatever it now covers. Returns true
    # when new commits were applied, false when already current — or when
    # no watermark is available yet. Attaching before the writer has
    # published is a race, not an error: poll again, and read `unavailable`
    # to see why nothing advanced.
    def refresh
      out = FFI::MemoryPointer.new(:int32)
      Guard.check!(FFI.glyphes_follower_refresh(@handle, out), "follower_refresh")
      out.read_int32 != 0
    end

    # Newest commit id applied. A commit id, not a generation: the two
    # advance together and are numbered independently (PRD-SHARED §4.3).
    def head
      read_u64("follower_head") { |out| FFI.glyphes_follower_head(@handle, out) }
    end

    # The watermark generation — the writer's progress, distinct from head.
    def generation
      read_u64("follower_generation") { |out| FFI.glyphes_follower_generation(@handle, out) }
    end

    # The committed LSN paired with the generation.
    def lsn
      read_u64("follower_lsn") { |out| FFI.glyphes_follower_lsn(@handle, out) }
    end

    # Why the watermark is unavailable, or "" when it is fine. A follower
    # attached before the writer exists keeps reporting its reason here
    # until the watermark appears; the string is copied out of engine
    # storage at this one read, per ABI.md B1.
    def unavailable
      ptr = FFI.glyphes_follower_error(@handle)
      ptr.nil? || ptr.null? ? "" : ptr.read_string
    end

    def close
      return if closed?

      Guard.check!(FFI.glyphes_follower_close(@handle), "follower_close")
      @handle = 0
    end

    private

    def init(path)
      out = FFI::MemoryPointer.new(:uint64)
      Guard.check!(FFI.glyphes_follower_open(path, out), "follower_open")
      @handle = out.read_uint64
    end

    def read_u64(context)
      out = FFI::MemoryPointer.new(:uint64)
      Guard.check!(yield(out), context)
      out.read_uint64
    end
  end
end
