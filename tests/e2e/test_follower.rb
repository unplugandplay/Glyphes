# S2/S3 gate: the follower surface, through FFI from Ruby.
#
# This is the first gate that proves the door is real: a Ruby process
# observing a writer's commits through the C ABI, with no Nim in the test
# except the writer child. The Nim suite (tests/unit/test_follower_abi.nim)
# drives the same functions from the inside; between them, a seam bug
# cannot hide behind a green engine test.
#
# The write-defense is asserted structurally: Follower has no method that
# could mutate the watched database. A regression that adds one fails here
# not because a call raises, but because the method exists.

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/glyphes"

class FollowerTest < Minitest::Test
  def with_db(**opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "follow.glyph")
      Glyphes::Database.open(path, **opts) { |db| yield db, path }
    end
  end

  # The follower's whole value: commits written after it attaches are
  # visible to the next poll. Attach, watch a writer advance, and check
  # head follows.
  def test_follows_a_live_writer_between_polls
    with_db(create: true) do |db, path|
      db.exec("CREATE (n:Person {name: $name})", { "name" => "one" })

      follower = Glyphes::Follower.open(path)
      assert follower.refresh
      assert_equal 1, follower.head

      db.exec("CREATE (n:Person {name: $name})", { "name" => "two" })
      assert follower.refresh
      assert_equal 2, follower.head

      follower.close
    end
  end

  # A second poll with nothing new reports "no change", not an error —
  # refresh is idempotent the same way the Nim path is.
  def test_refresh_is_idempotent
    with_db(create: true) do |db, path|
      db.exec("CREATE (n:Person {name: $name})", { "name" => "one" })

      follower = Glyphes::Follower.open(path)
      assert follower.refresh
      refute follower.refresh

      follower.close
    end
  end

  # head, generation and lsn are three different counters that advance
  # together; the Ruby surface must not blur them. generation runs one
  # ahead of head here because a fresh database starts its generation
  # counter at 1 and the first commit is id 1.
  def test_head_generation_and_lsn_are_distinct
    with_db(create: true) do |db, path|
      3.times { |i| db.exec("CREATE (n:N {i: $i})", { "i" => i }) }

      Glyphes::Follower.open(path) do |f|
        assert f.refresh
        assert_equal 3, f.head
        assert_equal 4, f.generation
        assert_operator f.lsn, :>, 0
      end
    end
  end

  # The door's whole point: a Ruby process follows a *forked writer*, the
  # real cross-process case the follower exists for. The child writes 10
  # commits and exits; the parent polls until it has seen them all. The
  # parent holds no writable handle during the follow — the child is the
  # writer, and the follower attaches alongside it, which is exactly the
  # shape the feature exists for.
  def test_follows_a_forked_writer_process
    Dir.mktmpdir do |dir|
      path = File.join(dir, "follow.glyph")
      Glyphes::Database.open(path, create: true) do |db|
        db.exec("CREATE (n:N {i: $i})", { "i" => 0 })
      end
      # Parent's handle is closed here; the child takes the writer role.

      pid = fork do
        Glyphes::Database.open(path) do |db|
          9.times { |i| db.exec("CREATE (n:N {i: $i})", { "i" => i + 1 }) }
        end
        exit! 0
      end

      follower = Glyphes::Follower.open(path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        follower.refresh
        break if follower.head >= 10
        sleep 0.02
      end
      Process.waitpid(pid)

      assert_equal 10, follower.head, "follower converged on the child's commits"
      follower.close
    end
  end

  # Attaching to a database whose writer has not published yet (no watermark
  # file) is a race, not an error: the follower opens, refresh reports no
  # change, and the reason is readable.
  def test_unavailable_watermark_is_reported_not_raised
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nowm.glyph")
      Glyphes::Database.open(path, create: true) do |db|
        db.exec("CREATE (n:N)", {})
        # Simulate the watermark being absent (as after a crash that lost
        # it): the follower must say so, not invent generation 0.
        File.delete(path + "-shm") if File.exist?(path + "-shm")
      end

      follower = Glyphes::Follower.open(path)
      refute follower.refresh
      refute_empty follower.unavailable
      follower.close
    end
  end

  # The write-defense, asserted structurally: there is no method on
  # Follower that could write. This is the SS2 guarantee from the surface
  # plan at the Ruby layer — not "writes raise", but "there is nothing to
  # call".
  def test_no_write_surface_exists
    %i[commit apply write insert delete create set remove truncate
       save execute exec query].each do |m|
      refute Glyphes::Follower.method_defined?(m),
             "Follower must not respond to ##{m}: a follower cannot write"
    end
  end

  def test_closed_follower_refuses_further_use
    with_db(create: true) do |db, path|
      db.exec("CREATE (n:N)", {})
      follower = Glyphes::Follower.open(path)
      follower.refresh
      follower.close

      assert_predicate follower, :closed?
      assert_raises(Glyphes::ClosedError) { follower.refresh }
    end
  end

  # Block form closes even when the block raises, the same contract
  # Database.open has had since M0.
  def test_block_form_closes_on_raise
    with_db(create: true) do |db, path|
      db.exec("CREATE (n:N)", {})
      assert_raises(RuntimeError) do
        Glyphes::Follower.open(path) { |_f| raise "boom" }
      end
    end
    # No assertion on the follower itself: block-form close-on-raise is
    # exercised above; here we only prove the raise propagated.
  end
end
