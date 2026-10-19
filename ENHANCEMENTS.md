# glyphes — ENHANCEMENTS

> A ranked list of what matters next, why it matters, and what it costs.
> Companion to [`docs/ROADMAP.md`](docs/ROADMAP.md) (the ordered plan)
> and [`DEVLOG.md`](DEVLOG.md) (what happened).
>
> **Rule for this file:** an item moves here by being argued for, and out
> by being done or killed. Nothing enters the build because it was
> convenient.

**Status:** M0–M11 landed, plus two arcs on top: durable version history
(V0–V1) and a cross-process follower (F0–F3, S1–S4). The whole product
has been reviewed adversarially and the findings are fixed — the ledger,
with what each cost, is the last section of [`DEVLOG.md`](DEVLOG.md). The
priority list below is what the review left open, in order.

**Blocking — these gate the next milestone**

### 1. The `.vhist` format pass, while the format is young — **PARTLY LANDED**

**Landed:** the payload carries the commit's `branch` (versioned, V0
payloads still replay, so no breaking change for V2 — both replay sites had
been passing `""` by hand and a follower disagreed with its writer about
every commit it held); counts are bounded before they allocate, so a
payload cannot ask for 2^60 revisions on its way to being told it was
short; and replay refuses a frame whose generation repeats or reverses one,
with the resuming reader's high-water mark as the seam's other side.

**Still open, and why it is not just an edit:** frames carry no
**database-identity word**, so a sidecar copied from another database is
adopted silently. The identity it should carry belongs in the *snapshot*
header — a database's own creation stamp — and that is a storage-format
change wanting its own evidence (bit-flip, crash, reopen) before it lands.

Also open, and a performance question rather than a correctness one: every
replay reads the whole sidecar into one string, so a follower resuming at a
large offset still pays for the bytes before it. Streaming the scan is a
real change to a hot path with no user-visible defect behind it.

### 2. ~~The minor bounds items~~ — **LANDED**

`propCount: int16` wrapped at 32 768 properties on one record (release read
garbage lengths; a range-checked build died on a legal statement) — the
refusal now sits before the capacity early-return, because the array can be
large enough while the count field cannot hold the next value. The WAL
decoder's `uint32` payload-length compare wrapped above 4 GiB and rejected
*valid* frames in a log that size, after which `logContinuesPast` found good
frames behind the "overrun" and refused the whole database — compared in
`int64` now. The `.vhist` encoder refuses a payload at or above 4 GiB
rather than writing `len mod 2^32` and CRC-failing the frame on replay.
Commit-time `revisionAt` scanned each node's chain from the head; the chain
is append-ordered, so it now scans from the tail with an early exit at the
first older commit — the complexity term is structural, and this machine's
load made the wall-clock delta unmeasurable, so no number is claimed.

---

## Correctness — the ones that quietly corrupt

### 3. ~~Invariant checking in the build~~ — **LANDED (M11 review)**

`-d:glyphesCheck` now exists: `store.checkTouched` walks the S1/S2/S3/S4/S8
rules over every record a transaction touched, at the end of the merge,
and the test that proves it fires corrupts an edge by hand first. The
release build compiles the whole pass out.

The original failure mode for this project was scope growth without a
record — the thing that made the first attempt too big. `ENHANCEMENTS.md`
is the record. An item promoted from here into `docs/PRD-GLYPHES.md` §7
or §9 is a decision with a gate attached, not drift.

---

## Blocking — these gate the next milestone

### 1. ~~The store, so the engine can hold anything~~ — **LANDED (M1)**

Dense `i64` ids; `NodeRec` 48 B and `EdgeRec` 56 B; threaded adjacency
through `next_out`/`next_in`; three dictionaries; `PropSlot` 16 B over a
bump arena with the 8-byte inline threshold and length-prefixed blobs;
per-label member lists with O(1) swap-remove.

Green on `nimble bench` and 91 tests including the 10⁶-op degree recount.
Four things it cost that were not in the estimate, all recorded in
`DEVLOG.md`:

- **320 MB of padding**, invisible to every test, caught by the
  benchmark. `InitialSlotCapacity` was 4 where 2 costs nothing. This is
  now S14, and the reason every memory gate states a fixture.
- **`seq.setLen` allocates exactly**, so N incremental creates are
  O(N²) in bytes moved. Every array that grows by id now doubles.
- **Record copies on the hot path.** `edge(id)` copies 56 B; walking
  4×10⁶ edges spent 180 ms of a 400 ms budget on copies. Field
  accessors now exist alongside the record accessors.
- **Label removal was a linear scan**, i.e. quadratic in the obvious
  delete-heavy workload. The node's position now lives in a store-level
  array, so the record layout stays 48 B and removal is O(1).

**CSR was not chosen and the benchmark is what makes that falsifiable**
(`STORAGE.md` §5). At the gate fixture, all-traversal of 4×10⁶ edges is
195 ms — memory-latency bound, not layout bound, so CSR's locality win
would not show up at this shape. The decision needs a read-heavy
benchmark where traversal latency actually dominates, which is M11.

---

## Correctness — the ones that quietly corrupt

### 2. Crash-safe commit, before anything is worth keeping

**Why.** This is the whole thesis. An embedded graph store that loses
data on `kill -9` has failed at the only thing it was for, and the PRD
repeatedly says so. It is M2, deliberately early: if Phase A does not
land, nothing else matters.

**What.** WAL frames with per-frame CRC and one `write()` per frame;
snapshot with a trailing CRC over the whole body; `mmap` read path;
recovery that replays by `lsn` and truncates at the first bad frame;
auto-checkpoint at a commit boundary.

**Cost.** ~700 lines. The expensive part is not the code, it is the gate:
`kill -9` at 100 random points during a 10⁶-node import, every run
recovering to the last committed transaction.

**Watch for.** Committing to an `fsync` default. `sync_mode = NORMAL` is
an order of magnitude faster and loses the last few commits on power
loss. Default is `FULL`, because the default is what people ship.

### 3. One label per node — the last spare word is now spent

**Why.** `NodeRec.label` is a single `i32`. A real graph needs either
multi-label nodes or the `(:Thing)-[:HAS_TAG]->(:Tag)` modelling
workaround. If the answer is "both", the record needs an arena offset for
a label set.

**Status.** M1 shipped one label and documented the workaround
(`CYPHER.md` §2.1, C13). The `reserved` word in `NodeRec` that was going
to pay for the upgrade is now `slot_capacity` (§4.1), so the upgrade now
costs a *growing* the record: 48 → 56 bytes, +8 per node, which is
~8 MB on the M1 fixture and a snapshot migration regardless.

**Recommendation.** Do not reopen. One label plus `:HAS_ROLE` edges is
better for querying anyway — roles become entities with their own
properties — and the first real workload that needs `(:A:B)` on one node
is the evidence worth acting on. If it comes, pay the 8 bytes; it is not
a design crisis, it is a migration.

### 4. ~~Invariant checking in the build — half done~~ — **LANDED (M11 review)**

**Why.** `STORAGE.md` §8 lists S1–S10. S4 (degree bookkeeping exact) is
the one that fails *silently* — a drift in `out_count` corrupts hub
detection in the planner and shows up as bad plans months later.

**Landed.** `-d:glyphesCheck` is no longer a flag with nothing behind it:
`store.checkTouched` walks the S1/S2/S3/S4/S8 rules over every record a
transaction touched, at the end of the merge, raising a catchable
`StoreInvariantError` that the ABI maps to a status rather than letting a
Defect unwind into the host. The collection and the walk are both behind
the flag, the flag build runs the whole suite with the pass live (474/0,
no false fire), and the test that proves it fires corrupts an edge's
source by hand first. The historical notes below are kept because the
"why" is why the write-path half exists at all.

**Done at M1.** `check()` reports all ten with a code and a count, and
the degree-recount gate compares 10⁶ churned records against a
brute-force walk of their own lists.

**Not done.** `check()` runs *after* a suite, not *during* a write. The
`GLYPHES_CHECKED` flag is threaded through the build and nothing reads it
yet, so `nimble test` and `nimble testRelease` compile identically and
the intended assertions never compile in. ~120 lines.

**Why it is still worth doing.** A violation caught inside
`createEdge` names the record id; the same violation caught by `check()`
two hundred operations later names a count. The M2 crash harness is the
natural place to switch it on — a corruption the checker could have named
at write time is worth much less recovered after the fact.

---

## Performance — cheap now, expensive later

### 5. Per-chunk copy-on-write for the commit path

**Why.** `TXN.md` §4 currently copies the whole published array per
commit. At 10⁶ nodes that is a 48 MB copy per commit — fine for embedded
use, wrong for a commit-heavy workload.

**Why now.** This is the one enhancement whose cost grows with everything
else. Deciding it after M3 means changing the array representation that
M1 and M2 were built against, which is a rewrite rather than an addition.

**What.** Fixed-size records already make the layout chunk-friendly
(`STORAGE.md` §2). Chunked arrays with a per-chunk copy-on-write flag: a
commit copies only the 4 KB chunks holding modified records.

**Cost.** ~250 lines plus a snapshot format change. **Decide by: end of
M3.**

### 6. ~~`PropSlot.aux` widening~~ — **rejected at M1**

Was queued as free. It is not: `payload` needs 8-byte alignment, so
widening `aux` from `u16` to `u32` moves `payload` from offset 8 to 16
and grows `PropSlot` from 16 to 24 bytes. That is +8 bytes on every
property of every record, 112 MB → 168 MB on the M1 fixture, in exchange
for 32-byte inline strings instead of 8-byte ones. Almost every real
property is either an integer or longer than 32 bytes.

`STORAGE.md` §10 keeps the cheaper version of the same idea if short
strings ever turn out to dominate: put `aux` in the low 16 bits of
`payload` for inline values, which leaves overflow values a full `u32`.
Same 32-byte ceiling, still 16 B per slot. Measure before building it.

### 7. Sort top-N instead of full sort

**Why.** `LIMIT 10 ORDER BY score DESC` over 10⁶ rows currently sorts
everything and truncates. A bounded heap makes it O(k log n) and is the
single biggest win for the vector+traversal query that is this product's
reason to exist.

**Why deferred.** `EXEC.md` §5 explicitly pins `Sort` as the only
operator allowed to buffer, and a top-N sort is a *different operator*
with its own correctness surface. Worth it once the pull pipeline is
proven.

**Cost.** ~150 lines. **Decide by: after M5's gate.**

---

## Reach — small surface, large payoff

### 8. A Ruby REPL

**Why.** Every session that touches glyphes currently needs a script.
`glyphes` on the command line, reading Cypher from stdin, is twenty lines
of Nim and removes the largest friction in the early feedback loop.

**Cost.** ~300 lines. **Note.** `CYPHER.md` §5 rejects `EXPLAIN` in the
language surface but exposes it as a debug ABI call; a REPL is the
natural place to hang that.

### 9. `SHOW SCHEMA INFO`

**Why.** Text2Cypher and agent workflows need the ontology. One ABI call
returning labels, relationship types, and properties is cheap and makes
the store self-describing to a model.

**Cost.** ~100 lines, and it is mostly `glyphes_schema`, which is already
declared.

### 10. Property index auto-creation

**Why.** A user who writes `WHERE p.email = $e` and gets a full scan has
no way to know the index is missing. Discovering it from the schema and
suggesting (or creating) the index is the difference between a database
that teaches and one that punishes.

**Cost.** ~400 lines. **Risk.** Automatic index creation on a write path
is a performance cliff. Suggestion is safer than creation, and cheaper.

---

## Operations — needed before anyone trusts it with real data

### 11. A corruption report a human can read

**Why.** `glyphes_integrity_check` returns a status string. When it fails
at 3 a.m. on a 4 GB file, the operator needs to know *which* invariant
(`S1`–`S10`), which record id, and whether the WAL or the snapshot is at
fault.

**Cost.** ~150 lines, and it is much easier to add while the invariants
are being written than after a user reports an unreadable report.

### 12. Backup as a first-class verb

**Why.** "Copy the file" is wrong during a write. `db.backup` is a
checkpoint followed by a copy, so the result is always a single
consistent file. `WAL.md` §1 promises this; M2 has to deliver it.

**Cost.** ~80 lines.

### 13. A `glyphes doctor`

**Why.** Which build is loaded, which file is open, what the WAL is
doing, whether a stale lock exists. Every "why is glyphes behaving
oddly" question is answered by this, and support is cheaper than
diagnosis.

**Cost.** ~120 lines of Ruby.

---

## Explicitly not doing

Recurring requests to decline, so the answer is written down:

| Request | Why not |
|---|---|
| A server, a socket, Bolt | Changes the product from a gem to a deployment. PRD §9 phase 2, deliberately un-budgeted |
| Graph algorithms, PageRank, community detection | This is a store, not an analytics engine. Export the graph and use a library |
| A cost-based optimizer | PRD pin P7. A planner with cardinality estimation is a project; a greedy one is 300 lines and predictable |
| Savepoints | Genuinely wanted by real importers — "commit 900 000 rows, roll back the bad one". ~400 lines, phase 2, the most requested item in that list |
| Parallel query execution | The GIL means Ruby threads do not run engine code in parallel. Processes are the deployment model (`RUBY.md` Y14) |
| Durable versioning, branches, diff | Specified: [`docs/PRD-VERSIONING.md`](docs/PRD-VERSIONING.md). Supersedes the time-travel line that stood here |
| Full openCypher conformance | `CYPHER.md` §5's rejection list is the contract. Conformance is a multi-year project and the subset is the 70% that real queries use |

---

## Order

The next four, in order, and why this order:

1. **Crash-safe commit (M2).** The thesis, and the gate that decides
   whether this project is a database. Everything built so far is
   currently lost on `kill -9`, which means the store is not yet worth
   anything to a user.
2. **Build the W1 harness before the WAL it tests.** 100 `kill -9`s
   during a 10⁶-node import. Write it against the current store so it
   fails, then make the WAL make it pass — a crash test written after the
   durability code is a crash test that only checks the paths its author
   thought of. This is the single most valuable thing to build before any
   feature work: it is the only test in this project whose failure means
   the product is worthless.
3. **Decide chunked COW, inside M3.** Cheap now, expensive later, and it
   changes the array representation M1 just built — so it is pinned to
   the end of M3 rather than left open. (`PropSlot.aux`, the sibling
   decision, was resolved at M1 by computing alignment instead of field
   sums, and rejected.)
4. **The reopen property test**, in M2 as well. Build, write, reopen,
   assert the state hash. It is the only test that catches a format which
   is self-consistent but incomplete, which is exactly what M1's
   `WAL.md` §4.2a gap was.

Then the reach items (8, 9) — cheap, and they shorten every feedback loop
after them — and the operations items (11, 12, 13) before any real data
depends on it.

Performance work (5, 7) is deliberately not first. The store *has* now
been measured, and what that measurement changed was padding and record
copies rather than the layout: all-traversal at ~250 ms over 4·10⁶ hops
is memory-latency bound, so neither a top-N sort nor CSR addresses the
bottleneck yet. Optimizing before the first benchmark is how a project
acquires the wrong shape; optimizing immediately after it is how a
project acquires a wrong *shape of optimization*.

### What M1 changed about the plan

Two items did not survive contact with a real store, and both were
resolved by measurement rather than argument — which is the outcome worth
having, because the argument would have gone the other way:

- **CSR was not chosen, and the benchmark says why not.** At 195–290 ms
  for 4·10⁶ hops, traversal is latency-bound, not layout-bound, so CSR's
  locality win does not appear at this shape. The decision is deferred to
  M11, where a read-heavy benchmark can make it falsifiable. It is still
  on the books (`STORAGE.md` §5), not cancelled.
- **One-label-per-node did not get its cheap upgrade path.** The
  `NodeRec` reserved word it was going to pay for is now `slot_capacity`.
  Multi-label would now cost a growing record, 48 → 56 B, plus a
  migration. Still not worth doing (#3), but it is no longer free, and
  the file says so.

### Three more items M1 added

**Symbolic debugging** (overlaps #11). `check()` returns
`seq[Invariant]` with a code and a count. When it fails at 3 a.m. on a
large store, "S4: degree mismatches: 3" is a start, not an answer. The M2
work touches every write path, and this is the moment to make a violation
name the record id. Cheap now, because the invariants are fresh;
expensive later, because by M4 nobody remembers which invariant number
meant what.

**A `-d:glyphesCheck` write-path assertion.** Folded into #4 above — the
flag is threaded through the build and nothing reads it.

**A reopen test.** Every persistent format in this project will be wrong
the first time it meets a real store, and the question that finds it —
*if these were the only bytes on disk, would a reopen be correct?* — was
asked by hand at M1 and immediately found three missing pieces of state
(`WAL.md` §4.2a). At M2 it should be a **property**: build a store, write
it, reopen it, and assert the state hash is identical, for a store with
tombstones, for a store whose ids were renumbered by a checkpoint, and
for one with an empty WAL. Cheap to write, and the only test that catches
a format that is self-consistent but incomplete.

---

## M4, in the order it gets built

The vertical-slice order, so every step ends with the full gate green and
any of them can be where the work stops:

| # | Slice | Lands |
|---|---|---|
| 1 | **done** | `lexer.nim`, `ast.nim`, `parser.nim`, `errors.nim` — the read subset of `CYPHER.md` §§2–4, with every out-of-contract clause refused by name |
| 2 | **done** | `expr.nim`, `ops.nim`, `plan.nim`, `execute.nim` — `ScanAll`, `ScanByLabel`, `Expand`, `Filter`, `Project`, `Skip`, `Limit`; the greedy planner's five rules; Cypher's three-valued logic |
| 3 | **done** | the statement seam — statement arena under ABI.md B3, nine exported symbols, and Ruby `Statement`/`Cell`/`Result`/`db.query` returning real rows over a real file |
| 4 | **done** | `Sort`, `DISTINCT`, and both C gates: C1 at 71/71 in-contract (gate 95 %), C9 at 96 977 queries/s (gate 50 000) and 0.066 ms two-hop (gate 3 ms) at 10⁶ nodes |

All four slices landed. What the gates cost is in [`DEVLOG.md`](DEVLOG.md)
under M4.3 and M4.4 — five defects the seam found (including two crashes
and one unpinned type rule) and one 130x performance bug that lived in a
function signature.

## Open items from M3, in priority order

**1. ~~Property slot offsets are generation-relative~~ — NOT A BLOCKER.**
A `PropView` holds arena offsets and the arena is mutated in place, so a
snapshot read against a newer arena returns a plausible-looking value from
the wrong bytes — as long as a snapshot and a merge can overlap. They
cannot: `beginRead` holds `s.pubLock` until `endRead`, and the merge takes
that same mutex. TXN.md §2's rule (one `ReadSnapshot` from `prepare` to
close) is sufficient, at the price of the deviation TXN.md §4 already
records — readers serialise. M4 needs no arena-per-generation and no slot
indirection.

What is left of it: `GraphStore.setNodeProp` / `setEdgeProp` mutate the
arena without the lock. Single-threaded by contract, unsafe beside a live
snapshot, and worth a comment on each.

**2. ~~Readers serialise against each other~~ — DONE, and it was a
deadlock, not a slowdown.** Two live statements on one store hung: M3's
`beginRead` held the store mutex for a statement's whole life, and a
statement cannot be re-entered from inside its own snapshot. The store now
has a reader gate — a counter plus a condition, writer-priority —
(`TXN.md` §4), and `--mm:atomicArc` because TSan showed ORC's non-atomic
refcounts racing on every shared `ref`. TSan over the soak is clean.

**3. T4 and T6 are unimplemented.** T4 is a serializability trace over a
concurrent-writer run; T6 is a merge-cost benchmark (the old copy-on-write
path had a 48 MB-per-commit cost that is now gone, and the new number is
unmeasured). Both are benchmarks and neither blocks M4; they are the two
gates M3 closed without.

**3a. Checkpoint and WAL truncation are not exported.** Still true, and
it now has a visible consequence: the e2e fixture is a **log with no
snapshot**, because `make_fixture.nim` commits once and `close` does not
checkpoint. Every M4 Ruby test therefore opens a WAL-only database, which
is a better test than it looks — recovery runs on every one of them — and a
good argument for exporting `glyphes_checkpoint` before M5. `glyphes_checkpoint`
and `glyphes_wal_size` are in the header and were not in M3's scope, so a
database now grows its `-wal` without bound and never writes a `.glyph`
snapshot except through recovery. Opening such a database works — the log
*is* the database until a checkpoint (`STORAGE.md` §7 measured what that
state costs) — but this is the first thing to add after M4, and it is an
M2 leftover rather than new work.

**4. T7 constraints are unimplemented**, deferred to M6 with the index
structures pin X8 makes them reuse.

## What the concurrency gate found, and why it is worth its cost

Five fixes, four of them real bugs invisible to any single-threaded test:
a check-then-act writer claim, a compare-and-swap performed on a *copy*
(`Atomic[T]` is a value type), a multi-field publish that was not atomic
as a set, a reader counter that was itself check-then-act, and a refcount
decrement that raced a publish because Nim `ref` refcounts are not atomic.
The soak also had an off-by-one of its own (`rand(keep)` is inclusive of
`keep`), which is the sort of thing a gate finds in its own harness too.
Details in `DEVLOG.md`.
