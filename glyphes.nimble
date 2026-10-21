## glyphes — embedded graph database
##
## Build:  nimble build
## Gate:   nimble gate

version       = "0.1.0"
author        = "glyphes"
description   = "The SQLite of graphs: an embeddable labeled property graph for Ruby (see docs/PRD-GLYPHES.md)"
license       = "MIT"
srcDir        = "src"

# No dependencies, per PRD pin P2. The ABI is dynlib + FFI, and the
# flags below are the whole toolchain requirement.
#
# There is deliberately no `bin` key: this package ships a shared
# library, not an executable. nimble's default task wants a `bin`, so
# every task here is explicit.

requires "nim >= 2.2.4"

task build, "Build libglyphes (release, ORC, threaded)":
  mkdir "lib"
  exec "nim c -d:release --mm:atomicArc --threads:on --app:lib --noMain:on -o:lib/libglyphes.so src/glyphes.nim"

task buildDebug, "Build libglyphes (debug, invariant checks on)":
  mkdir "lib"
  exec "nim c --mm:atomicArc --threads:on -d:glyphesCheck --app:lib --noMain:on -o:lib/libglyphes.so src/glyphes.nim"

task buildAsan, "Build libglyphes with AddressSanitizer":
  mkdir "lib"
  exec "nim c -d:release --mm:atomicArc --threads:on --app:lib --noMain:on " &
       "--passC:\"-fsanitize=address -fno-omit-frame-pointer\" --passL:-fsanitize=address " &
       "-o:lib/libglyphes_asan.so src/glyphes.nim"

# ASan cannot install its interceptors from a dlopen'd dylib, so Ruby has
# to be started with the runtime preloaded. TESTING.md Q7 wants the FFI
# boundary fuzzed under ASan; this is what makes that runnable at M0.
task asan, "Ruby suite + Nim tests under AddressSanitizer":
  ## Both halves. The FFI boundary is only half the risk; the store's
  ## arena and copyMem paths are the other half, and those are pure Nim.
  let rt = "/Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"
  exec "nim c -d:release --mm:atomicArc --threads:on --passC:\"-fsanitize=address -fno-omit-frame-pointer\" " &
       "--passL:-fsanitize=address -o:tmp/run_all_asan tests/run_all.nim"
  exec "DYLD_INSERT_LIBRARIES=" & rt & " ./tmp/run_all_asan"
  exec "nim c -d:release --mm:atomicArc --threads:on --app:lib --noMain:on " &
       "--passC:\"-fsanitize=address -fno-omit-frame-pointer\" --passL:-fsanitize=address " &
       "-o:lib/libglyphes_asan.so src/glyphes.nim"
  exec "DYLD_INSERT_LIBRARIES=" & rt & " GLYPHES_LIB=" & getEnv("PWD") &
       "/lib/libglyphes_asan.so ruby -Ilib tests/e2e/run.rb"

task bench, "M1 store benchmark at the gate fixture":
  ## Runs the PRD §8 / STORAGE.md §7 gate. Exits non-zero on a miss.
  exec "nim c -d:release --mm:atomicArc --threads:on --passC:\"-I./src\" -o:tmp/bench_m1 tests/bench/bench_m1.nim"
  ## nimble passes its own argv through to paramStr, so paramStr(0) is
  ## the nimble binary path rather than a user argument. Fall back to the
  ## gate shape unless the last argument parses as a count.
  var n = "1000000"
  if paramCount() > 0:
    let candidate = paramStr(paramCount() - 1)
    try:
      discard parseInt(candidate)
      n = candidate
    except ValueError:
      discard
  exec "./tmp/bench_m1 " & n

task test, "Nim tests, fast (the developer loop)":
  ## GLYPHES_FAST_TESTS shrinks the churn suites from 10^6 ops to 2*10^4,
  ## which is the difference between ~2 s and ~5 min. The assertions are
  ## the same; only the iteration count moves.
  exec "nim c --mm:atomicArc --threads:on -d:glyphesCheck -o:tmp/run_all tests/run_all.nim"
  exec "GLYPHES_FAST_TESTS=1 ./tmp/run_all"

task testGate, "Nim tests at full churn (the M1 gate)":
  ## PRD §8: the degree recount runs 10^6 random edge operations. Slow on
  ## purpose; this is the gate, not the loop.
  exec "nim c --mm:atomicArc --threads:on -d:glyphesCheck -o:tmp/run_all tests/run_all.nim"
  exec "./tmp/run_all"

task testRelease, "Nim tests against the release build":
  exec "nim c -r --mm:atomicArc --threads:on -d:release -o:tmp/run_all_release tests/run_all.nim"

task crash, "W1 crash gate: kill an importer, recover, compare to the oracle":
  ## WAL.md §7 W1. The child is a separate binary so it can be SIGKILLed
  ## mid-transaction; the harness spawns it, kills it at a random point,
  ## recovers, and checks the recovered graph against a clean run of the
  ## *same seed* stopped at the recovered transaction. Args: kills ops
  ## opsPerTxn, defaulting to the 100/10^6-node W1 numbers, which take a
  ## few minutes; the defaults below are the quick gate.
  exec "nim c -d:release --mm:atomicArc --threads:on -o:tmp/crash_child tests/fuzz/crash_child.nim"
  exec "nim c -d:release --mm:atomicArc --threads:on -o:tmp/crash_harness tests/fuzz/crash_harness.nim"
  exec "GLYPHES_CRASH_CHILD=$PWD/tmp/crash_child ./tmp/crash_harness 25 2000 20"

task soak, "T1 concurrency gate: 6 readers + 2 writers, no torn read":
  ## TXN.md §10 T1. Short by default so `nimble gate` stays usable; pass
  ## the wall-clock budget as an argument for the full run.
  ## The soak is deliberately run against a debug-invariant build so a
  ## degree drift or a dangling chain is caught by S1-S10 as well as by
  ## the reader-side checks.
  exec "nim c -d:release --mm:atomicArc --threads:on -o:tmp/soak_bin tests/soak/soak.nim"
  exec "./tmp/soak_bin 10"

task soakShared, "S1 two-process write soak (PRD-SHARED gate SG1b)":
  ## The soak that has two *processes* rather than many threads.
  ## soakLeak.nim proves concurrency inside one process; this proves the
  ## cross-process writer lock, which is the bug S1 fixes. A non-zero
  ## refusal count in its output is the lock working — two processes cannot
  ## both write, so one of them waits.
  ##   nimble soakShared 240         # a smoke run
  ##   nimble soakShared 43200       # 12 hours
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-sh -o:tmp/soak_shared tests/soak/soak_shared.nim"
  let secs = getEnv("GLYPHES_SHARED_SECS", "240")
  exec "./tmp/soak_shared " & secs

task crashFollower, "F2 SG7 crash a writer mid-commit; follower off by exactly one":
  ## The gate for the reason the watermark exists. `.vhist` is fsynced before
  ## the graph merge and before the watermark is published, so a process that
  ## dies in that window leaves the log *ahead* of the database. This kills a
  ## real writer there with SIGKILL (see `txn.crashHook`) and checks that a
  ## follower stops at the watermark, is short by exactly the in-flight commit,
  ## and leaves the untrusted tail for whoever opens next.
  ##
  ## It first asserts that the window was actually entered. A crash that never
  ## reached the vulnerable ordering passes every other check vacuously, and a
  ## gate that cannot tell the difference is worse than no gate.
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-cf -o:tmp/crash_follower tests/crash/crashfollow.nim"
  exec "./tmp/crash_follower"

task soakLeak, "M11 20-node leak soak (5 days by default; --mm:orc instrumented)":
  ## The M11 gate: many nodes, long run, and a verdict on *memory* rather
  ## than on correctness. Two optional arguments, seconds and node count:
  ##   nimble soakLeak                 -> 5 days, 20 nodes (the real gate)
  ##   nimble soakLeak 90 20           -> a 90-second smoke run
  ##
  ## Built with --mm:orc, not --mm:atomicArc, because `getOccupiedMem` is
  ## ORC's own allocator accounting and the verdict is a slope in that
  ## number. A gate on an allocator it does not own would be a gate on a
  ## proxy.
  exec "nim c -d:release --mm:orc --threads:on --nimcache:tmp/nimcache-sl -o:tmp/soak_leak tests/soak/soak_leak.nim"
  var secs = "432000"
  if paramCount() > 0:
    secs = paramStr(paramCount() - 1)
  var nodes = "20"
  if paramCount() > 1:
    nodes = paramStr(paramCount() - 2)
  exec "./tmp/soak_leak " & secs & " " & nodes

task fixture, "Rebuild tests/fixtures/social.glyph (the M4 e2e data)":
  ## Generated by the real Nim write path, left with its WAL on purpose:
  ## a readonly open of it is a recovery (test_m4.rb). Rebuilt every run —
  ## it is 2.5 KB and determinism is worth more than the milliseconds.
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-ex -o:tmp/make_fixture tests/fixtures/make_fixture.nim"
  exec "./tmp/make_fixture"

task gemtest, "Ruby surface tests":
  exec "nimble fixture"
  exec "ruby -Ilib tests/e2e/run.rb"

task tck, "TCK subset conformance (CYPHER.md C1)":
  ## Reads tests/conformance/tck_subset.txt, runs it against the fixture,
  ## writes tck_report.md, and fails below 95%. Needs the fixture (the
  ## runner opens it read-only and replays its log).
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-ex -o:tmp/run_tck tests/conformance/run_tck.nim"
  exec "nimble fixture"
  exec "./tmp/run_tck"

task benchSort, "M5.6 sort benchmarks (E2 LIMIT 10, E3 spilled sort)":
  ## E2 `LIMIT 10` over a 10^6-row traversal < 2 ms; E3 a sort of 10^7 rows
  ## that spills and completes. The gate runs the full sizes — E3 is minutes
  ## of work and that is the point of it. For a quick check of the same two
  ## shapes, run the binary directly with two sizes:
  ## `./tmp/bench_sort 200000 500000` (traversal rows, sort rows).
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-bs -o:tmp/bench_sort tests/bench/bench_sort.nim"
  exec "./tmp/bench_sort"

task benchVector, "M6.3 vector benchmark: recall gate + determinism (INDEX.md §4)":
  ## I-vec: recall@10 >= 0.95 at the defaults on 10^5 clustered 64-dim
  ## vectors against brute force, p50 latency, and byte-identical rebuild
  ## (I11). One argument overrides the vector count.
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-bvec -o:tmp/bench_vector tests/bench/bench_vector.nim"
  exec "./tmp/bench_vector"

task bitflip, "M10 bit-flip gate (WAL.md W3): one flipped bit, clean open or a named error":
  ## W3: a single flipped bit anywhere in the snapshot or the log must end
  ## in a named error or a clean open — never a crash, never a database
  ## that serves different data with no error anywhere. One argument
  ## overrides the flip count; the gate runs a CI-sized sweep and
  ## `nimble bitflip 1000000` runs the WAL.md figure.
  exec "nim c --mm:atomicArc --threads:on -o:tmp/bitflip-harness tests/fuzz/bitflip_harness.nim"
  ## Nimble hands the task its own arguments, so the count comes from the
  ## environment: GLYPHES_BITFLIPS=1000000 nimble bitflip runs the WAL.md
  ## figure, and the default is a CI-sized sweep.
  let flips = getEnv("GLYPHES_BITFLIPS", "5000")
  exec "./tmp/bitflip-harness " & flips
  ## W2 in the same task: power loss truncates at every 4 KB boundary and
  ## every outcome must be a clean open or a named error.
  exec "./tmp/bitflip-harness truncate"

task benchImport, "M9 import/export benchmark (RUBY.md R8: 10^6-row CSV, Parquet vs reference)":
  ## R8: a 10^6-row CSV import under 60 s, and a Parquet export within
  ## 0.1% of a byte count recomputed from the format rather than from this
  ## writer. One argument overrides the row count (the gate runs the full
  ## 10^6).
  exec "ruby tests/bench/bench_import.rb"

task benchVersion, "M11 versioning benchmark: diff is O(changed), not O(graph)":
  ## G2, and the measurement that decides whether versioning is worth
  ## building at all. Two commits touching the same number of nodes, on
  ## graphs 100x apart: if the diff time follows the graph, the PRD's core
  ## claim is false and V1 does not start.
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-bv -o:tmp/bench_version tests/bench/bench_version.nim"
  exec "./tmp/bench_version"

task benchIndex, "M6.1 range-index benchmark (INDEX.md I5)":
  ## I5: a 10^6-node point lookup < 1 ms and a range scan < 10 ms, against
  ## the same queries with no index as a baseline. One argument overrides the
  ## node count for a quick check: `./tmp/bench_index 200000`.
  exec "nim c -d:release --mm:atomicArc --threads:on --nimcache:tmp/nimcache-bi -o:tmp/bench_index tests/bench/bench_index.nim"
  exec "./tmp/bench_index"

task benchSqlite, "M11 glyphes vs SQLite edge-tables (PRG §9)":
  ## The comparative benchmark. One optional node count, one optional fanout:
  ##   nimble benchSqlite
  ##   nimble benchSqlite 50000 4
  ## It refuses to print a timing whose row counts disagree between the two
  ## systems, so a run that reports numbers has already proved the two
  ## engines answered the same question.
  var args = ""
  if paramCount() >= 1:
    args = paramStr(paramCount() - 1)
  if paramCount() >= 2:
    args = args & " " & paramStr(paramCount() - 2)
  exec "ruby tests/bench/bench_sqlite.rb " & args

task benchQuery, "M4 query benchmark (CYPHER.md C9)":
  ## 10^6 nodes unless a count is passed. C9: single-hop query rate and
  ## 2-hop latency. Fails the task on a miss, like bench.
  exec "nim c -d:release --mm:atomicArc --threads:on --passC:\"-I./src\" -o:tmp/bench_query tests/bench/bench_query.nim"
  var n = "1000000"
  if paramCount() > 0:
    let candidate = paramStr(paramCount() - 1)
    try:
      discard parseInt(candidate)
      n = candidate
    except ValueError:
      discard
  exec "./tmp/bench_query " & n

task ss2, "F2 SS2: no exported follower symbol can write":
  ## The feature's central guarantee is structural: there is no
  ## `glyphes_follower_commit` to forget to guard, because there is no such
  ## function. A Nim test cannot check that — it cannot reference a symbol
  ## that must not exist — so the check belongs on the built library's
  ## symbol table, which is also the artifact Ruby and the CLI actually
  ## load. Until this task existed the docs claimed the gate was green and
  ## nothing implemented it.
  let libPath = getEnv("GLYPHES_LIB", "lib/libglyphes.so")
  if not fileExists(libPath):
    quit(libPath & " is not built; run `nimble build` first", QuitFailure)
  # NimScript has no pipes: nm's output goes to a file, and the file is
  # read back. `exec` propagates nm's exit code, so a missing `nm` fails
  # the task rather than passing it vacuously on an empty table.
  if not dirExists("tmp"):
    mkdir "tmp"
  let dump = "tmp/ss2-symbols.txt"
  exec "nm -gU " & libPath & " > " & dump
  let table = readFile(dump)
  let forbidden = ["glyphes_follower_commit", "glyphes_follower_write",
                   "glyphes_follower_apply", "glyphes_follower_truncate",
                   "glyphes_follower_exec", "glyphes_follower_create"]
  var leaked: seq[string] = @[]
  for name in forbidden:
    if table.contains("_" & name):
      leaked.add name
  if leaked.len > 0:
    quit("SS2 FAILED: the follower surface exports " & leaked.join(", ") &
         " — a follower must have no write to call", QuitFailure)
  let exported = splitLines(table, false).len
  echo "SS2: clean — " & $exported &
       " exported symbols, none of them a follower write"

task gate, "Everything CI runs":
  ## Chained with plain `nimble` calls, not exec-of-nimble: exec runs a
  ## shell command, and `nimble gate` re-entering nimble from inside a
  ## nimscript deadlocks on the package lock. These run in order and
  ## stop at the first failure.
  ##
  ## The gate is "everything under a couple of minutes", not "everything":
  ## `soakShared` at its default 240 s, `soakLeak` (five days), and
  ## `benchSqlite` (~3 min) are a nightly tier, documented in TESTING.md
  ## §3.1 with the reason each is long. The three flagship gates of the
  ## newest arcs — G2 (`benchVersion`), SG7 (`crashFollower`), and SS2 —
  ## cost seconds each and belong here; they were the three a reviewer
  ## found running nowhere.
  exec "nim c -d:release --mm:atomicArc --threads:on --app:lib --noMain:on -o:lib/libglyphes.so src/glyphes.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:glyphesCheck -o:tmp/run_all tests/run_all.nim"
  exec "nimble fixture"
  exec "ruby -Ilib tests/e2e/run.rb"
  exec "nimble crash"
  exec "nimble crashFollower"
  exec "nimble bitflip"
  exec "nimble soak"
  exec "nimble ss2"
  exec "nimble bench"
  exec "nimble benchQuery"
  exec "nimble benchSort"
  exec "nimble benchVersion"
  exec "nimble benchIndex"
  exec "nimble benchVector"
  exec "nimble benchImport"
  exec "nimble tck"

task ez80Test, "eZ80: the CPU's test suite (Z80 compatibility + the eZ80's own features)":
  ## The eZ80 emulator in ez80/ is a separate project that lives here. Its
  ## suite includes the strongest compatibility statement available: the
  ## BASIC interpreter must produce the same transcript, byte for byte, as
  ## the Z80 emulator it grew out of.
  exec "nim c -r --mm:atomicArc --threads:on -o:tmp/test_ez80 ez80/tests/test_ez80.nim"

task ez80Asm, "eZ80: assemble basic.z80":
  exec "nim c -d:release -o:tmp/ez80asm ez80/ez80asm.nim"
  exec "./tmp/ez80asm ez80/basic.z80 ez80/basic.bin"

task ez80Bench, "eZ80: how fast is the BASIC interpreter? (a million loop iterations)":
  ## The benchmark is a BASIC program fed to GLYPHE BASIC; the harness
  ## takes the clock before the interpreter starts and after it ends.
  exec "nim c -r -d:release --mm:atomicArc --threads:on -o:tmp/ez80_bench ez80/bench/bench.nim"
