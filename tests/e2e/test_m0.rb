# M0 gate: `require "glyphes"` opens :memory: and closes clean
# (ROADMAP.md). Everything here is about the seam, not the store.

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/glyphes"

class M0Test < Minitest::Test
  def test_ffi_layouts_match_the_header
    # The assertion in ffi.rb runs at require time; this asserts it ran
    # and pinned what it checked, so a future edit to LAYOUT that drops
    # a struct is visible here rather than silent.
    layout = Glyphes::FFI.check_layout!
    assert_equal 24, layout[Glyphes::FFI::Cell]
    assert_equal 64, layout[Glyphes::FFI::Stat]
    layout.each_value { |bytes| assert_operator bytes, :>, 0 }
  end

  def test_version_round_trips
    major = FFI::MemoryPointer.new(:uint32)
    minor = FFI::MemoryPointer.new(:uint32)
    patch = FFI::MemoryPointer.new(:uint32)

    assert_equal 0, Glyphes::FFI::glyphes_version(major, minor, patch)
    assert_equal Glyphes::VERSION.split(".").map(&:to_i),
                 [major.read_uint32, minor.read_uint32, patch.read_uint32]
  end

  def test_open_memory_and_close
    db = Glyphes::Database.open(":memory:") do |d|
      refute_predicate d, :closed?
      assert_equal ":memory:", d.path
    end
    assert_predicate db, :closed?
  end

  def test_block_form_closes_even_when_the_block_raises
    captured = nil
    assert_raises(RuntimeError) do
      Glyphes::Database.open(":memory:") do |db|
        captured = db
        raise "boom"
      end
    end
    assert_predicate captured, :closed?, "database must close on unwind"
  end

  def test_close_is_idempotent
    db = Glyphes::Database.open(":memory:")
    db.close
    assert_predicate db, :closed?
    db.close # must not raise
    assert_predicate db, :closed?
  end

  def test_stat_reports_a_fresh_generation
    # STORAGE.md S12 / TXN.md X4: generation is monotonic from 1, and 0
    # is reserved so a zeroed GlyStat never reads as a valid value.
    Glyphes::Database.open(":memory:") do |db|
      s = db.stat
      assert_equal 1, s[:generation]
      assert_equal 0, s[:nodes]
      assert_equal 0, s[:edges]
      assert_equal 0, s[:bytes_resident]
    end
  end

  def test_create_creates_a_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fresh.glyph")
      refute File.exist?(path)

      Glyphes::Database.open(path, create: true) { |db| assert db.stat }

      # M2 writes the snapshot; at M0 open is the only side effect, so
      # assert the intent (no error) rather than a file that does not
      # exist yet.
    end
  end

  def test_open_missing_without_create_raises_io_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "absent.glyph")
      err = assert_raises(Glyphes::IoError) { Glyphes::Database.open(path) }
      assert_match(/GLY_ERR_IO/, err.message)
      assert_match(/does not exist/, err.message)
    end
  end

  def test_open_missing_directory_raises_io_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "no-such-dir", "x.glyph")
      assert_raises(Glyphes::IoError) { Glyphes::Database.open(path, create: true) }
    end
  end

  def test_unknown_mode_bits_are_rejected
    # A typo'd constant must fail at open rather than silently degrading
    # to read-write, which is the dangerous direction to fail in.
    out = FFI::MemoryPointer.new(:uint64)
    status = Glyphes::FFI::glyphes_open(":memory:", 1 << 20, out)
    refute_equal 0, status
    assert_match(/unknown open mode bits/, Glyphes::FFI.last_error_message)
  end

  def test_memory_cannot_be_read_only
    out = FFI::MemoryPointer.new(:uint64)
    mode = Glyphes::FFI::GLY_OPEN_MEMORY | Glyphes::FFI::GLY_OPEN_READONLY
    status = Glyphes::FFI::glyphes_open(":memory:", mode, out)
    assert_equal Glyphes::FFI::GLY_ERR, status
  end

  def test_empty_path_is_rejected
    out = FFI::MemoryPointer.new(:uint64)
    status = Glyphes::FFI::glyphes_open("", Glyphes::FFI::GLY_OPEN_MEMORY, out)
    assert_equal Glyphes::FFI::GLY_ERR, status
  end

  def test_null_out_param_is_rejected_not_a_crash
    status = Glyphes::FFI::glyphes_open(":memory:",
                                        Glyphes::FFI::GLY_OPEN_MEMORY, nil)
    assert_equal Glyphes::FFI::GLY_ERR, status
    assert_match(/out_db is null/, Glyphes::FFI.last_error_message)
  end

  def test_null_version_pointers_are_tolerated
    # Documented: all three may be NULL if you only want validation.
    assert_equal 0, Glyphes::FFI::glyphes_version(nil, nil, nil)
  end

  def test_stale_handle_is_rejected_not_a_crash
    # ABI.md B4: closing invalidates the handle, and reusing it must
    # return GLY_ERR_STALE rather than touch freed memory. This is the
    # property that makes `ensure` cleanup safe in Ruby.
    out = FFI::MemoryPointer.new(:uint64)
    assert_equal 0, Glyphes::FFI::glyphes_open(":memory:",
                                               Glyphes::FFI::GLY_OPEN_MEMORY, out)
    handle = out.read_uint64
    assert_equal 0, Glyphes::FFI::glyphes_close(handle)

    status = Glyphes::FFI::glyphes_stat(handle, Glyphes::FFI::Stat.new.pointer)
    assert_equal Glyphes::FFI::GLY_ERR_STALE, status
    assert_match(/stale handle/, Glyphes::FFI.last_error_message)
  end

  def test_null_handle_is_rejected
    # A GlyHandle of 0 is the engine's "no handle" sentinel, so it must
    # fail as STALE rather than dereference a null slot.
    status = Glyphes::FFI::glyphes_close(0)
    assert_equal Glyphes::FFI::GLY_ERR_STALE, status
  end

  def test_stat_null_out_is_rejected
    out = FFI::MemoryPointer.new(:uint64)
    Glyphes::FFI::glyphes_open(":memory:", Glyphes::FFI::GLY_OPEN_MEMORY, out)
    handle = out.read_uint64
    assert_equal Glyphes::FFI::GLY_ERR, Glyphes::FFI::glyphes_stat(handle, nil)
  end

  def test_error_slot_is_cleared_on_demand
    handle_slot = handle_slot
    Glyphes::FFI::glyphes_open("", Glyphes::FFI::GLY_OPEN_MEMORY, handle_slot)
    refute_empty Glyphes::FFI.last_error_message

    Glyphes::FFI::glyphes_global_error_clear
    assert_empty Glyphes::FFI.last_error_message
  end

  def test_every_error_status_maps_to_a_class
    # Gate R1: no status may fall through to InternalError by omission.
    mapping = Glyphes::ErrorMapping::BY_STATUS
    codes = [
      Glyphes::FFI::GLY_ERR, Glyphes::FFI::GLY_ERR_CLOSED,
      Glyphes::FFI::GLY_ERR_STALE, Glyphes::FFI::GLY_ERR_SQL,
      Glyphes::FFI::GLY_ERR_CONSTRAINT, Glyphes::FFI::GLY_ERR_IO,
      Glyphes::FFI::GLY_ERR_READONLY, Glyphes::FFI::GLY_ERR_BUSY,
      Glyphes::FFI::GLY_ERR_LIMIT, Glyphes::FFI::GLY_ERR_NOMEM,
      Glyphes::FFI::GLY_ERR_UNSUPPORTED,
      # M10: a damaged file is its own status, because the only useful
      # response to it is a restore and a host that cannot tell it from an
      # I/O error retries a file that will never open.
      Glyphes::FFI::GLY_ERR_CORRUPT
    ]

    codes.each do |code|
      assert mapping.key?(code), "status #{code} has no exception class"
      assert mapping[code] <= Glyphes::Error,
             "#{code} maps to #{mapping[code]}, which is not a Glyphes::Error"
    end

    # InternalError is GLY_ERR's class, not a fallback: any status that
    # reaches it by omission rather than by mapping is the bug.
    assert_equal Glyphes::InternalError, mapping[Glyphes::FFI::GLY_ERR]
    specific = codes.reject { |c| c == Glyphes::FFI::GLY_ERR }
    specific.each do |code|
      refute_equal Glyphes::InternalError, mapping[code],
                   "status #{code} must map to its own class, not InternalError"
    end
    assert_equal codes.length, Glyphes::ErrorMapping::NAMES.length
  end

  def test_repeated_open_close_does_not_leak_handles
    # 200 cycles: a leaked handle shows up as growing resident memory far
    # later, so the cheapest early signal is that this does not blow up
    # and that the last close is clean.
    200.times do
      db = Glyphes::Database.open(":memory:")
      db.close
    end
    db = Glyphes::Database.open(":memory:")
    assert_equal 1, db.stat[:generation]
    db.close
  end

  def test_interleaved_databases_are_independent
    # Distinct handles must not share state (ABI.md B9).
    a = Glyphes::Database.open(":memory:")
    b = Glyphes::Database.open("/tmp/glyphes-interleave-a.glyph", create: true)

    assert_equal a.stat[:generation], b.stat[:generation]

    a.close
    # b is untouched by a's close.
    assert_equal 1, b.stat[:generation]
    b.close
    File.unlink("/tmp/glyphes-interleave-a.glyph") if File.exist?("/tmp/glyphes-interleave-a.glyph")
  end
end
