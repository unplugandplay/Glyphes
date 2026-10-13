# glyphes — TESTING: how we know it works

> **Status:** specification, applicable from M0. Normative. Every gate in
> `PRD-GLYPHES.md` §8, `STORAGE.md`, `WAL.md`, `TXN.md`, `CYPHER.md`,
> `EXEC.md`, `INDEX.md`, `RUBY.md` is executed by something in here.
> Companion: `../nimblyru/docs/TESTING.md` (the family's method).

---

## 1. Three oracles

An embedded database has no external reference implementation, so it
needs three substitutes or it is only testing itself.

**Oracle 1 — SQLite, for semantics.** glyphes's transaction and index
semantics are SQLite's by design (`TXN.md`, `WAL.md`). So SQLite is the
oracle: a relational model of the same data, run through the same
transaction sequences, and the observable results must agree.

```
graph                        SQLite
(:Person {name, age})        people(name TEXT, age INTEGER)
-[:KNOWS {since}]->          knows(src INTEGER, dst INTEGER, since INTEGER)
```

Concretely differential: build both, run the same script (a sequence of
transactions with a crash point), compare. Durability, isolation level,
constraint behaviour, and index-based-vs-scan results must match. This is
the strongest oracle available and it is nearly free.

**Oracle 2 — brute force.** For every index: build the same data with and
without the index and compare results. For vectors, HNSW against exact
cosine. For text, BM25 against a reference implementation
(`sqlite3` FTS5's ranker is close enough for a 0.1 % tolerance on the
corpus, and it is already on the machine).

An index that changes results is a bug, and this is the only way to notice.

**Oracle 3 — model hand-computation.** For storage layout, WAL framing,
and arena offsets: the spec documents byte offsets (`STORAGE.md` §2,
`WAL.md` §2). Tests assert *those offsets*, so the layout is checked
against the document, not against the implementation. A refactor that
changes `NodeRec` from 48 bytes to 56 fails a test.

**And the oracle we do not have:** a reference graph database. Memgraph
and Neo4j are too different in surface for a result-level diff to be
meaningful. Instead, the openCypher TCK provides the language oracle
(`CYPHER.md` §7) and it is the highest-leverage external test in the
project.

---

## 2. Layout

```
tests/
  oracles/            SQLite schema, brute-force generators, corpus   (M2+)
  unit/               pure Nim, no I/O
    test_core.nim       M0 — status vocabulary, struct layouts, handles, open
    test_store.nim      M1 — layouts, codec, slots, churn, invariants
    test_wal.nim        M2 — frames, CRC, torn tails, replay idempotence
    test_txn.nim        M3 — gates T1-T8 at the engine level
    test_abi.nim        M3 — the exported glyphes_* surface, as C calls it
    test_cypher.nim     M4 — lexer, parser, scope and refusal semantics
    test_exec.nim       M4 — operators, planner, statement lifecycle
    test_write.nim      M5 — the write path: CREATE, SET, REMOVE, DELETE, MERGE
  integration/        WAL, checkpoints, indexes, transactions          (M2+)
  fuzz/               truncation, bit-flip, GC-stress, concurrency     (M2+)
  conformance/        openCypher TCK subset (committed, stable
                      denominator)                                    (M4)
    tck_subset.txt       the denominator; edited by decision only
    tck_report.md        written by `nimble tck`, committed
    run_tck.nim          the runner: prepare, step, compare, report
                      (write rows run against a disposable store)
  fixtures/
    make_fixture.nim     builds social.glyph through the real write path
  differential/       glyphes ↔ SQLite semantic differential          (M2+)
  bench/
    bench_m1.nim       M1 — the §7 gate fixture; exits non-zero on a miss
    bench_query.nim    M4 — C9: query rate and 2-hop latency at 10^6
    bench_churn.nim    churn scaling, with the recount and `check()`
                       timed separately (see §3.4)
  e2e/                Ruby, gem-level
    test_m0.rb           M0 — the FFI seam: load, layouts, stale handles
    test_m3.rb           M3 — db.transaction, BUSY, integrity_check
    test_m4.rb           M4 — db.query, streaming, refusals, over a file
    test_m5.rb           M5 — db.exec, the transaction join, durability
    run.rb               the runner
  run_all.nim         the single runner
  ORACLE              pinned tool versions + flags                    (M1+)
```

Naming: `test_<subject>_<property>.nim`, so a failure name states the
property that broke. Milestone suffixes on the files are the plan, not
decoration: `test_store.nim` does not get a `test_store_m2.nim`, it gets
a suite added to it, so the layout assertions stay in one file next to the
behaviour they constrain.

### 2.1 Two tiers, one suite

`nimble test` and `nimble testGate` compile the *same* file and differ
only in `GLYPHES_FAST_TESTS`, which shrinks the churn loop from 10⁶
operations to 2·10⁴.

| Task | Churn | Wall | For |
|---|---|---|---|
| `nimble test` | 2·10⁴ | ~2 s | the loop you run while editing |
| `nimble testGate` | 10⁶ | ~5 s | PRD §8's count |
| `nimble bench` | — | ~3 s | the three §7 budgets, non-zero on a miss |
| `nimble benchQuery` | — | ~2 s | C9 at 10⁶ nodes, non-zero on a miss |
| `nimble tck` | — | ~0.1 s | C1 over the committed subset, writes the report |
| `nimble gate` | 10⁶ | ~90 s | everything, in order, including crash, soak and both C gates |
| `nimble soak` | 10 s | ~15 s | T1; pass a budget in seconds for longer |
| `nimble asan` | 10⁶ | ~90 s | both suites under AddressSanitizer |

The split exists because the full count is the gate and a gate that runs
on every save is a gate people stop reading. It is also cheap here: 10⁶
churn operations cost 4.9 s, so the honest answer was to make the gate
the default and not shrink it.

---

## 3.4 When the *harness* is the slow part

Twice at M1, a test was quadratic and the store was innocent. Both times
the fix was to measure the thing under test separately:

- `bench_churn` runs the identical workload against the store with no
  bookkeeping at all. It reports ~9 M ops/s, linear, in both the release
  and the bounds-checked debug build. The churn test was doing
  `seq.delete` on its own id lists — O(n) per operation on a list that
  grows with the op count.
- The invariant checker `check()` is timed separately in the same
  benchmark, because it is the oracle for every mutating suite and an
  oracle that is slow becomes an oracle nobody runs.

The rule: when a test is unexpectedly slow, benchmark the code under test
before optimizing it. Making the store faster for a problem the store did
not have is a real way to spend a day.

---

## 3. The gates, by kind

### 3.1 Correctness gates (must pass, always)

| Kind | Where | Method |
|---|---|---|
| Byte layout | `STORAGE.md` §2 | assert every offset and total size |
| Invariants | `STORAGE.md` §8 | S1–S10 on every fixture, plus a `-d:glyphesCheck` build |
| Crash safety | `WAL.md` §8 W1 | SIGKILL at 100 random points, compare to last commit |
| Truncation | W2 | truncate at every 4 KB boundary |
| Bit-flip | W3 | 10⁶ single-bit flips; `integrity_check` reports, never passes |
| Torn tail | W4 | append 1–31 garbage bytes |
| Idempotence | W5 | recover twice, compare state hashes |
| Isolation | `TXN.md` §10 T2–T4 | generation assertions, serializability trace |
| Adjacency degree | `STORAGE.md` §5 | 10⁶ random ops, recount from scratch |
| Index equivalence | Oracle 2 | indexed vs unindexed, HNSW vs brute force |
| Language | `CYPHER.md` §7 C1 | TCK subset, ≥ 95 % — `nimble tck`, `tests/conformance/` |
| Query rate | `CYPHER.md` §7 C9 | `nimble benchQuery`, 10⁶ nodes |
| Pull model | `EXEC.md` §9 E2 | `LIMIT 10` over 10⁶ rows < 2 ms |
| ABI lifetime | `RUBY.md` §7 R2, R4 | GC stress, stale access |

### 3.2 Budget gates (must pass on the gate machine)

| Gate | Budget | Measured |
|---|---|---|
| create 10⁶ nodes + 4·10⁶ edges | < 8 000 ms | 844–1 360 ms |
| all-traversal of 4·10⁶ edges | < 400 ms | 161–195 ms |
| heap at that shape | < 680 MB | 619 MB |
| W7 fsynced commit | 2 000 txn/s | (M2) |
| I1 recall@10 at `ef`=128 | ≥ 0.95 | (M6) |
| C1 TCK subset pass rate | ≥ 95 % | 100 % (132/132) |
| C9 single-hop query rate | 50 000 /s | 96 977 /s |
| C9 2-hop at 10⁶ nodes | < 3 ms | 0.066 ms |
| R8 10⁶-row CSV import | < 60 s | (M9) |

Ranges rather than single numbers, because the traversal figure moves
with machine load: a concurrent `nim c` on the same box took it from
195 ms to 812 ms. Pinning one reading would make the gate a measurement
of the machine.

These are *gates*, not aspirations — `nimble bench` exits non-zero. A
regression over 10 % is a failure to investigate before merge, and the
benchmark is what makes that visible rather than anecdotal.

**The memory gate had 320 MB of slack removed by the benchmark, and was
later found to be measuring the wrong thing.** 91 tests
passed while a record with a *single* property allocated 64 bytes of slot
array, because no test measured bytes. The lesson is in S14: a memory
budget needs a fixture, and the fixture needs to be the one the gate
asserts. The second half of that lesson arrived at M3: the gate was named
RSS and measured `getOccupiedMem()`, which is not RSS — true peak RSS on
the same fixture is 1100 MB, and the gated figure drifted 595 → 652 MB with
no change in the engine. The benchmark now prints both (`STORAGE.md` §7).

### 3.3 Fuzzing

Four fuzzers, each with a fixed seed corpus so failures reproduce:

| Fuzzer | Input | Invariant |
|---|---|---|
| `fuzz_wal` | random mutation sequences + random crash points | recover to last commit or named error |
| `fuzz_snapshot` | truncation + bit-flips in the snapshot | clean open or `GLY_ERR_IO`, never a crash |
| `fuzz_cypher` | random Cypher from the grammar + random mutations | never a crash; wrong answers allowed only where pinned |
| `fuzz_gc` | Ruby, live `Cell`s held across batch boundaries, forced GC | no segfault, no stale read |

`fuzz_cypher` is the highest-value one and also the most expensive.
Generated from the grammar (`CYPHER.md` §1), so every input parses; the
oracle is "no crash, and the result is one the grammar permits". Wrong
*answers* are the fuzzers' blind spot, which is why the TCK and
differential suites exist alongside.

---

## 4. Reproducibility

Every gate is reproducible from one command:

```
nimble test                              317 Nim tests, churn shrunk        ~2 s
nimble testGate                          317 Nim tests, full 10^6 churn   ~25 s
nimble fixture                           rebuilds social.glyph from Nim     ~2 s
nimble gemtest                           106 Ruby tests                    instant
nimble bench [n]                         M1 budgets, non-zero on a miss   ~3 s
nimble benchQuery [n]                    C9 query budgets, 10^6 nodes     ~2 s
nimble tck                               C1 over the committed subset     ~0.1 s
nimble crash                             W1 crash gate, 25 kills           ~40 s
nimble soak [seconds]                    T1, 10 s by default               ~15 s
nimble gate                              all of the above, in order        ~90 s
nimble asan                              both suites under ASan           ~90 s
```

Plus, once they exist: `nim c -r tests/fuzz/run.nim -- --seed=42
--rounds=10000`, and `nim c -d:release -r tests/run_all.nim` for the
budget gates against the optimized build.

Note that `nimble gate` chains plain `exec` calls rather than
`exec "nimble ..."` — re-entering nimble from inside a nimscript
deadlocks on the package lock, which is why the command list is spelled
out rather than composed.

`nimble build` does not run the `build` task in `glyphes.nimble`:
nimble 0.24 defines a `build` task of its own, which wants a `bin` key
this package deliberately does not have, so the built-in wins and the
command dies with "Nothing to build". Until the task is renamed, build
the library with the `nim c` line from `glyphes.nimble`'s `gate`.

**The build is pinned to arm64 in `config.nims`,** because a build
started from a Rosetta shell (an x86_64 terminal, an x86 Ruby, anything
under `arch -x86_64`) otherwise links an x86_64 `libglyphes.so` and the
Ruby suite fails at `dlopen` with `mach-o file, but is an incompatible
architecture (have 'x86_64', need 'arm64')` — a failure that points at
`lib/glyphes/ffi.rb` rather than at the build. A cache created before
the pin keeps the wrong target; move it aside
(`mv ~/.cache/nim/glyphes_r{,.bak}`) or build with
`--nimcache:tmp/nimcache`. DEVLOG, "the wrong slice incident".

- `tests/ORACLE` pins Nim, Ruby, and SQLite versions plus the flags.
  It changes only by explicit decision, as in `../nimblyru`.
- Benchmarks pin `m`, `ef_construction`, HNSW seed, and dataset
  generator seed (`INDEX.md` I11 — determinism is what makes
  golden-testing an index possible at all).
- Corpus generation is seeded and committed, so a 10⁶-node benchmark
  dataset is reproducible from its seed rather than checked in. The M1
  churn test uses seed 20261007 and the label-index test 99, both inline
  so a failure is reproducible from the file alone.
- The M1 churn fixture is generated, not checked in: 10⁶ operations of
  create/delete on ~4·10⁵ nodes is a few hundred MB of ids, and a seed
  is a better artifact than the data.

The ASan build (`--passC:-fsanitize=address"`) runs both suites. For an
FFI library the bugs are mostly memory bugs, and ASan finds them in
minutes where manual review finds them in weeks.

**On macOS, `nimble asan` sets `DYLD_INSERT_LIBRARIES`** to the ASan
runtime. ASan cannot install its interceptors from a `dlopen`ed library:
without the preload the suite runs and reports green while ASan watches
nothing, which is the worst possible failure mode for a sanitizer. The
run ends with `ERROR: Failed to munmap` — Nim's ORC allocator returns
pages in a way ASan's shadow mapping does not tolerate. That is a known
Nim/ASan interaction, appears *after* the results line, and is not a
glyphes bug (`M0-NOTES.md` §8).

---

## 5. TCK subset management

The openCypher TCK is run against glyphes; most of it is outside the
0.1 contract (`CYPHER.md` §5), and the subset file records which tests
are in-contract.

```
tests/conformance/
  tck_subset.txt      committed; the stable denominator
  tck_report.md       latest run: passed / failed / out-of-contract
```

Rules:

1. The subset is **committed**; the denominator does not drift.
2. A TCK test whose query is out of contract is reported
   "out of contract", never as a pass.
3. A rising out-of-contract count is the **implementation queue** — it
   turns "what should we add to Cypher next" from a guess into evidence.
4. Gate C1 is ≥ 95 % of the subset. The subset may only *shrink* by
   explicit decision, recorded with a reason.

Rule 4 matters: without it, the subset erodes until the gate measures
almost nothing, and nobody notices because the number still passes.

### 5.1 Where the M4 subset stands

`nimble tck` at M4: **71 of 71 in-contract rows pass** (gate 95 %) and
**18 of 18 out-of-contract rows refuse naming their construct**
(`tests/conformance/tck_report.md`). The runner writes the report on every
run, pass or fail, because a committed report that only moves when someone
remembers to move it is a report nobody reads.

Two things about that number, stated rather than left to be discovered:

- **The subset is hand-written from the TCK's scenario families, not
  synced from the upstream repository.** Each entry names the family it
  comes from and carries an expectation written from Cypher semantics, not
  from this engine's output — which is the only way the file can catch a
  wrong answer rather than confirm one. Syncing against the real TCK is
  M5 work, and until it happens "TCK subset" here means "the TCK-shaped
  read surface, hand-derived", which is weaker than the name.
- **Every write row is self-contained** and runs against a store seeded for
  that row alone (`run_tck.nim`). The first version seeded one store and let
  rows accumulate, which made the subset order-dependent: a row that deleted
  `:Made` silently emptied every row after it, and sorting the file — which
  nothing forbids — changed results. A subset whose denominator moves when
  you sort it is not a denominator.
- **100 % is not the same as 100 % coverage.** The subset is 71 rows
  because that is what the 0.1 read surface is. A pass rate on a small
  denominator is a weak signal, which is why the out-of-contract count is
  reported next to it: 18 named refusals is the honest measure of how much
  of Cypher is *not* here yet.

---

## 6. Ruby-side testing

Two layers, and the second is the one that matters:

**Unit** (`tests/e2e/`): the gem-level suite, 92 tests at M5.3, per
`RUBY.md` R6. The M4 twenty-eight are the read path across the seam:
column names, every scalar kind, parameters, ordering and paging,
streaming batches, and one test per refusal class.

**ABI torture** (`tests/fuzz/fuzz_gc.rb`): the FFI boundary, tested like
C code, because that is what it is. Hold `Cell`s past their statement,
force GC at every batch boundary, close a database with live statements,
reopen after an exception mid-transaction. Expect `ClosedError` or
`StaleError`; anything else is a bug.

The FFI boundary is where a database embedding is uniquely fragile, and
it is the part of this project that cannot be validated by the engine's
own tests. A segfault here takes down the host process, which is the one
thing a library must never do.

---

## 7. What is not tested, and why

Stated explicitly so the gaps are decisions, not oversights:

| Not tested | Why |
|---|---|
| Behaviour under a second *process* | Phase 2. `flock` covers the common case; the rest is unverified |
| Crash-consistency on real power loss | Simulated by truncation (W2). Real power loss adds device-level reordering we cannot reproduce; SQLite has the same exposure |
| Performance on non-gate hardware | Gates are relative to a pinned machine. Absolute numbers elsewhere are meaningless |
| Vector recall against *production* embeddings | Measured on a synthetic corpus with known ground truth. Real embeddings have different cluster structure; the recall figure is optimistic |
| Long-running behaviour beyond the 5-day soak | 5 days is what fits in CI. Week-long leaks are not excluded |
| Memory behaviour under extreme fragmentation | Bump allocation plus `ORC` makes this unlikely to matter, but it is not measured |

The power-loss row is the one to be honest about in the README. Truncation
simulation is a good proxy and it is not the same thing, and a user who
needs certainty about power loss should run their own test on their own
hardware — which is what SQLite's own test suite does.

---

## 8. Pins

| # | Pin |
|---|---|
| Q1 | SQLite is the semantic oracle; brute force is the index oracle; specs are the layout oracle |
| Q2 | Every gate runs from one command, from a committed seed corpus |
| Q3 | Byte layouts are asserted against the spec offsets, not the implementation |
| Q4 | Index results must equal unindexed/brute-force results; a difference is a bug |
| Q5 | The TCK subset is committed and may only shrink by explicit decision |
| Q6 | Out-of-contract TCK tests are reported, never counted as passes |
| Q7 | ASan runs the fuzzers in CI; the FFI boundary is fuzzed from Ruby |
| Q8 | Budget gates fail the build; a >10 % regression blocks a merge |
| Q9 | HNSW and dataset generation are seeded and deterministic |
| Q10 | §7's gaps are documented in the README before release, not after |

---

## 9. Open questions

- **Crash-gate cost.** W1 (100 SIGKILLs during a 10⁶-node import) is
  minutes per run. Daily or on-merge-only? Leaning: reduced W1 (10
  points) on every merge, full W1 nightly.
- **Fuzz corpus sharing.** The `fuzz_wal` sequences are useful for
  `fuzz_snapshot` too. Sharing a corpus across fuzzers is standard
  practice, but the two fuzzers have different invariants, so a shared
  corpus couples their failure reports. Not resolved.
- **Property-based testing.** No `std/quickcheck` equivalent committed.
  Most property tests here are hand-written loops, which is more work but
  keeps the dependency list empty (`PRD.md` P2) and makes every case
  reviewable. Writing a small `nimble`-free property helper is probably
  worth it by M5.
- **Serializability trace checking.** T4 asserts no anomaly in a
  concurrent run, which is weaker than verifying the trace against a
  serial order. A real serializability checker (Jepsen-style) is a
  significant piece of work and might be worth it if `TXN.md`'s
  single-writer claim is ever relaxed.
