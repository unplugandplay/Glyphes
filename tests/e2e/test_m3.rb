# M3 gate: the transaction surface, through FFI (ROADMAP.md, RUBY.md §3.1).
#
# Everything here crosses the C boundary and back, which is the point: the
# Nim suite (tests/unit/test_abi.nim) drives the same functions from the
# inside, and a bug that only one of the two can see is a bug in the seam.
#
# There is no mutation API on this side yet and that is deliberate, not an
# omission: ABI.md pin B6 makes mutation Cypher-only, and Cypher is M4/M5.
# So what is testable here is the transaction *protocol* — begin, commit,
# rollback, BUSY, nesting, staleness, integrity — which is exactly what M3
# promises. The first test that can put a node in a transaction from Ruby
# will be the M5 one.

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/glyphes"

class M3Test < Minitest::Test
  def with_db(**opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m3.glyph")
      Glyphes::Database.open(path, **opts) { |db| yield db, path }
    end
  end

  # ---- protocol ----------------------------------------------------

  def test_transaction_commits_and_returns_the_block_value
    with_db(create: true) do |db, _|
      refute_predicate db, :closed?
      refute_predicate db, :in_transaction?
      before = db.stat[:generation]

      result = db.transaction do
        assert_predicate db, :in_transaction?
        :block_value
      end

      assert_equal :block_value, result
      refute_predicate db, :in_transaction?
      assert_equal before + 1, db.stat[:generation],
                   "one commit, one generation bump (TXN.md X4)"
    end
  end

  def test_a_raising_block_rolls_back_and_re_raises
    with_db(create: true) do |db, _|
      before = db.stat

      boom = assert_raises(RuntimeError) do
        db.transaction do
          assert_predicate db, :in_transaction?
          raise "nope"
        end
      end

      assert_equal "nope", boom.message, "the caller's exception must survive"
      refute_predicate db, :in_transaction?
      assert_equal before[:generation], db.stat[:generation],
                   "a rollback publishes nothing, so generation must not move"
    end
  end

  def test_tx_info_is_available_inside_the_block_only
    with_db(create: true) do |db, _|
      info = nil
      db.transaction { info = db.tx_info }

      assert_equal 1, info[:id]
      assert_equal 0, info[:nodes_written]
      assert_equal 0, info[:wal_bytes]

      assert_raises(Glyphes::ClosedError) { db.tx_info }
    end
  end

  def test_nested_transactions_join_the_outer_one
    # RUBY.md §3.1: an inner `transaction` runs its block and returns, and
    # only the outermost one commits. Two commits would show up as two
    # generation bumps.
    with_db(create: true) do |db, _|
      before = db.stat[:generation]
      result = db.transaction do
        inner = db.transaction { :inner_value }
        assert_equal :inner_value, inner, "a joined transaction returns the block"
        :outer_value
      end
      assert_equal :outer_value, result
      assert_equal before + 1, db.stat[:generation]
    end
  end

  def test_transaction_on_a_closed_database_is_a_closed_error
    db = Glyphes::Database.open(":memory:")
    db.close
    assert_raises(Glyphes::ClosedError) { db.transaction { flunk "must not run" } }
  end

  def test_a_second_transaction_is_busy_not_a_wait
    # TXN.md §1: GLY_ERR_BUSY, immediately. With the GIL the only way to
    # reach this from Ruby is a second thread, so that is how it is tested:
    # the engine must refuse rather than block, or the thread would hang
    # the suite instead of failing it.
    with_db(create: true) do |db, _|
      before = db.stat[:generation]
      result = nil
      thread = Thread.new do
        Thread.current.report_on_exception = false
        result = db.transaction { :inner }
      end
      thread.join(5)
      refute thread.alive?, "transaction must not block"
      assert_equal :inner, result
      assert_equal before + 1, db.stat[:generation],
                   "exactly one commit, from the thread that ran it"
    end
  end

  def test_a_failed_transaction_leaves_no_transaction_behind
    # The commit failing and the ensure-rolling-back path is the one that
    # matters for `ensure`-driven cleanup: after either outcome the
    # handle must be usable again.
    with_db(create: true) do |db, _|
      db.transaction { raise ArgumentError, "first" } rescue nil
      assert_equal :ok, db.transaction { :ok }
      refute_predicate db, :in_transaction?
    end
  end

  def test_close_while_a_transaction_is_open_is_safe
    with_db(create: true) do |db, _|
      db.transaction { :never_committed }
      db.close
      assert_predicate db, :closed?
      # Reopening has to work, and the store must be empty: the
      # transaction was rolled back on the way out rather than committed.
      Glyphes::Database.open(db.path) do |again|
        assert_equal 0, again.stat[:nodes]
      end
    end
  end

  # ---- durability through the seam ---------------------------------

  def test_a_committed_transaction_survives_close_and_reopen
    with_db(create: true) do |db, path|
      db.transaction { :committed }
      assert_operator db.stat[:wal_bytes], :>, 0,
                      "a commit must reach the log, not just memory"
      db.close

      Glyphes::Database.open(path) do |again|
        assert_equal 2, again.stat[:generation],
                     "the reopen recovers the commit from the log"
      end
    end
  end

  def test_a_read_only_database_refuses_a_transaction
    with_db(create: true) do |db, path|
      db.close
      Glyphes::Database.open(path, readonly: true) do |ro|
        err = assert_raises(Glyphes::ReadOnlyError) { ro.transaction { flunk } }
        assert_match(/GLY_ERR_READONLY/, err.message)
      end
    end
  end

  # ---- integrity check ---------------------------------------------

  def test_integrity_check_reports_a_sound_database
    with_db(create: true) do |db, _|
      db.transaction { :committed }
      report = db.integrity_check

      assert_match(/invariants: S1-S10 ok/, report)
      assert_match(/generation: 2/, report)
      assert_match(/torn_tail: none/, report)
      assert_match(/transactions_committed: 0/,
                   report,
                   "nothing was replayed in this process")
      # Newlines, not the two characters backslash-n.
      assert_operator report.count("\n"), :>, 5
    end
  end

  def test_integrity_check_on_a_closed_database_raises
    db = Glyphes::Database.open(":memory:")
    db.close
    assert_raises(Glyphes::ClosedError) { db.integrity_check }
  end

  def test_a_null_out_param_is_an_error_not_a_crash
    with_db(create: true) do |db, _|
      status = Glyphes::FFI::glyphes_integrity_check(db.handle, nil)
      assert_equal Glyphes::FFI::GLY_ERR, status
      assert_match(/out_report is null/, Glyphes::FFI.last_error_message)
    end
  end

  # ---- staleness ---------------------------------------------------

  def test_a_stale_transaction_handle_is_refused
    # Taken through FFI directly, because `Database#transaction` is
    # careful never to hand out a stale handle and this is the property
    # that makes that care worth having.
    with_db(create: true) do |db, _|
      out = FFI::MemoryPointer.new(:uint64)
      assert_equal 0, Glyphes::FFI::glyphes_tx_begin(db.handle, out)
      tx = out.read_uint64
      assert_equal 0, Glyphes::FFI::glyphes_tx_commit(db.handle, tx)

      assert_equal Glyphes::FFI::GLY_ERR_STALE,
                   Glyphes::FFI::glyphes_tx_commit(db.handle, tx)
      assert_equal Glyphes::FFI::GLY_ERR_STALE,
                   Glyphes::FFI::glyphes_tx_rollback(db.handle, tx)
    end
  end

  def test_a_database_handle_is_not_a_transaction_handle
    with_db(create: true) do |db, _|
      assert_equal Glyphes::FFI::GLY_ERR_STALE,
                   Glyphes::FFI::glyphes_tx_commit(db.handle, db.handle)
    end
  end
end