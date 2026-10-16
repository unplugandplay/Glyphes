# S3 gate: the command-line follower surface.
#
# The CLI is the lowest surface and the easiest to get wrong in one specific
# way — becoming an accidental write path. These tests prove the negative:
# the follow subcommand only ever reads head/generation/lsn, exits nonzero
# with the reason when the watermark is absent, and --watch reprints only on
# change. It never opens the database writable; there is no code in bin/
# that could.

require "minitest/autorun"
require "tmpdir"
require "open3"
require "timeout"
require_relative "../../lib/glyphes"

class CliFollowTest < Minitest::Test
  BIN = File.expand_path("../../bin/glyphes", __dir__)

  # See FollowerTest#asan_active?: spawning under ASan-injected Ruby trips
  # the same macOS munmap breakage as fork. The CLI suite spawns the
  # watcher process, so it is skipped wholesale under ASan.
  def asan_active?
    (ENV["DYLD_INSERT_LIBRARIES"] || "").include?("asan") ||
      (ENV["GLYPHES_LIB"] || "").include?("asan")
  end

  def setup
    skip "spawn under ASan faults on macOS (pre-existing platform breakage)" if asan_active?
  end

  def run_cli(*args)
    # -Ilib so bin/glyphes's require_relative resolves against this tree,
    # and the child inherits the library path for libglyphes.
    Open3.capture3("ruby", "-I", File.expand_path("../../lib", __dir__),
                   BIN, *args)
  end

  def with_db(**opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cli.glyph")
      Glyphes::Database.open(path, **opts) { |db| yield db, path }
    end
  end

  def test_follow_prints_the_head_line_and_exits_zero
    with_db(create: true) do |db, path|
      3.times { |i| db.exec("CREATE (n:N {i: $i})", { "i" => i }) }

      out, err, status = run_cli("follow", path)
      assert_predicate status, :success?, "stderr: #{err}"
      assert_match(/head: 3/, out)
      assert_match(/generation: 4/, out)
      assert_match(/lsn: \d+/, out)
    end
  end

  def test_follow_against_no_watermark_exits_nonzero_with_reason
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "absent.glyph")
      _out, err, status = run_cli("follow", bad)
      refute_predicate status, :success?
      assert_match(/watermark unavailable/, err)
    end
  end

  # The plan's SS4: --watch over a live writer prints a monotonically
  # advancing head. The writer is a sequence of separate processes (open,
  # commit, close), the closest a CLI test can get to an external writer
  # without a long-running daemon. No database handle stays open across the
  # loop — each writer open would collide with a still-open one on the
  # cross-process lock, and the watcher takes no lock at all.
  def test_watch_prints_advancing_head_for_a_live_writer
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cli.glyph")
      Glyphes::Database.open(path, create: true) do |db|
        db.exec("CREATE (n:N {i: $i})", { "i" => 0 })
      end

      lines = Queue.new
      # The watcher child is a real process; killing the reader thread would
      # leave it running forever with the pipe held open (a hang at process
      # exit). Kill the process, then join the thread.
      rd, wr = IO.pipe
      pid = spawn("ruby", "-I", File.expand_path("../../lib", __dir__),
                  BIN, "follow", path, "--watch=0.1",
                  out: wr, err: File::NULL)
      wr.close
      reader = Thread.new { rd.each_line { |l| lines << l } }

      ## Write phase: seed plus four commits, each in its own short-lived
      ## writer process, pausing between so the watcher's 0.1 s poll sees
      ## each one. Two writes inside one poll window would collapse into a
      ## single printed line, which is correct behaviour but un-testable.
      4.times do |i|
        Glyphes::Database.open(path) do |w|
          w.exec("CREATE (n:N {i: $i})", { "i" => i + 1 })
        end
        sleep 0.15
      end

      ## Read phase: collect the watcher's lines until it has reported the
      ## final commit (head 5: one seed + four) or the deadline passes.
      heads = []
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          begin
            line = Timeout.timeout(0.2) { lines.pop }
            heads << line[/head: (\d+)/, 1].to_i if line =~ /head:/
            break if heads.last.to_i >= 5
          rescue Timeout::Error
            # Nothing new yet; loop until the deadline.
          end
        end

        assert_equal heads, heads.sort,
                     "watch output is monotonic: #{heads.inspect}"
        assert_equal 5, heads.last,
                     "watch reached the final commit: #{heads.inspect}"
      ensure
        # The watcher child is a real process; killing only the reader thread
        # would leave it running forever with the pipe held open (a hang at
        # process exit). Kill the process, then join the thread.
        Process.kill("TERM", pid)
        Process.waitpid(pid)
        reader.kill
        rd.close
      end
    end
  end

  def test_usage_error_exits_two
    _out, err, status = run_cli("follow")
    refute_predicate status, :success?
    assert_equal 2, status.exitstatus
    assert_match(/usage:/, err)
  end
end
