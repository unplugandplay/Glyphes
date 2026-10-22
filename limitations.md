# glyphes — limitations

This file is published **before** the release, not after, and that ordering is
the point. A limitations document written once the work is done is a press
release with a table. This one is the list of things glyphes is bad at, with
measurements, written by the people who measured them.

glyphes is 0.1. It is an embedded graph store with a Cypher subset, a Rails-
shaped Ruby model layer, hybrid index families, a write-ahead log, and durable
version history. It is not a database that should be dropped into production,
and most of the rest of this file is about why.

---

## 1. The query language is a subset, and the subset is small

Cypher is large. glyphes implements a part of it, and the part is chosen for a
transactional embedded store rather than for compatibility.

**Refused by name, at prepare time** (the TCK reports 17 of these as
deliberate refusals rather than failures):

- comma-separated `MATCH` — a cartesian product, refused at M5
- a second `MATCH` clause, and any `CALL` after another clause — joins
- path binding, `MATCH p = (a)-[*]->(b)`
- relationship type alternation, `[:A|B]`
- `UNWIND`
- multiple statements in one call

**Not implemented:** subqueries, `EXISTS { … }` subqueries, most of the
temporal/spatial types, and multi-database.

Two types have landed: `DATE` at M6.5 (CYPHER.md §6.3) — a count of days
since 1970-01-01 with its own tag in the store, so it compares as a date,
sorts as a date, and never becomes text — and `POINT` at M6.6 (§6.4), two
`f64` with `point.distance`. `datetime`, `time`, `duration`, date
arithmetic, and the polygonal types (`LINE`, `POLYGON` are Neo4j
extensions, not openCypher) are *planned*,
with the stages written down in
[`docs/PLAN-CYPHER-EXTENSIONS.md`](docs/PLAN-CYPHER-EXTENSIONS.md) (X5).

Three of the five have landed. `FOREACH` at M5.7 (CYPHER.md §3.6). The
graph-pattern predicates at M5.8 (§2.3) — the *filter* form, over
variables that are already bound; one hop costs about 0.31 µs per row on
a 10 000-node graph with three relationships each, against 0.13 µs for a
plain property comparison, because the walk is the node's degree and not
the graph's size. The type discipline at M5.9 (§6.2, pin C17):
`typeof()`, and every operator refusing a wrong-typed operand by the
name of both types.

What is *not* in the type discipline: temporal and spatial values (X5),
and the type system's static half — the engine is dynamically typed, as
Cypher is, and a query's types are checked when a value reaches an
operator, not when the query is prepared.

Shortest paths landed at M6.4 (CYPHER.md §2.7.1): a function rather than a
pattern, undirected, and **bounded** — a search that hits `maxDepth` with
nodes still to explore is refused by name, because `null` means "no path"
and a search that stopped early has not established that. The cost is
O(visited nodes × their edges): on a 10 000-node ring with three
relationships each, a neighbour is 0.01 ms, 300 hops is 0.8 ms, and a bound
hit after ~3000 nodes is 2.6 ms. `allShortestPaths` is still refused: a
list of paths is a second shape with a second cost.

The other three are **decided against**, and the reasons are recorded
in the same document rather than left as a shrug: subqueries and
`EXISTS { … }` are a second execution path, and the engine keeps one;
multi-database is a different engine, and the engine's answer to "the
data is elsewhere" is that it is a *client* — which already has a
door, a language and a prompt.

The cost is not theoretical. Joins are refused, so any query that needs to
relate two patterns has to be rewritten as a traversal from a bound node —
which is exactly why the edge loader below is slow.

## 2. Loading a graph is slow, and it is the dialect's fault

Because a comma-`MATCH` is refused and a second `MATCH` is a join, creating an
edge between two *existing* nodes requires binding both endpoints explicitly:

```cypher
MATCH (a:Person {id: $src}) MERGE (b:Person {id: $dst}) CREATE (a)-[:KNOWS]->(b)
```

That `MERGE` is the bottleneck. It was far worse than it needed to be:
`mergeChain` (src/cypher/ops.nim) built its match half with `scanFor` — a
full label scan — because the seek lived in `plan.nim`, which imports
`ops.nim` and so could not be imported back. Binding a node for `MERGE (b:P
{id: $id})` is the same question as `MATCH (b:P {id: $id})`, and it was
answered two different ways.

Two separate defects made that `MERGE` scan, and both are fixed:

1. `mergeChain` built its match half with `scanFor` — a full label scan —
   because the seek lived in `plan.nim`, which imports `ops.nim` and so
   could not be imported back. The seek machinery now lives in `ops.nim` and
   both paths go through it.
2. The write path never passed the index registry to `prepare`, so
   `ctx.indices` was `nil` inside every write statement and the new `seekFor`
   fell back to scanning anyway. Read statements passed the registry; write
   statements did not, which is why reads were fast and writes quadratic. The
   write paths now pass `db.indices`, exactly as the read path does.

A profile showed the cost inside `label scan → filter → readNodeProp`: every
node visited, its `id` read through a hash lookup, per edge. With both fixed
the `MERGE` seeks, and the load is no longer quadratic.

**Three defects, all found by measurement rather than reading:**

1. `mergeChain` built its match half with `scanFor`, because the seek lived
   in `plan.nim`, which imports `ops.nim`. The seek moved down.
2. The write path never passed the index registry to `prepare`, so
   `ctx.indices` was `nil` inside every write statement and the new `seekFor`
   fell back to scanning anyway. Reads passed it; writes did not.
3. Even with a correct seek, an index learns about writes at **commit**, so a
   node created in the same transaction as the edges is invisible to it. The
   seek fell back to walking the transaction's delta — O(delta) per lookup.
   The transaction now keeps a flat `(label, property, key-hash) → ids` map
   of its own uncommitted rows, maintained as `setNodeProp` runs, so the
   lookup is a hash probe.

| benchmark edge load (20 000 edges, one transaction) | |
|---|---|
| at the start of this work | 108.9 s |
| after the seek reached `MERGE` | 89.2 s |
| after the write path passed the registry | 46.8 s |
| after the delta seek index | **5.3 s** |

An indexed lookup inside a transaction now runs at **75 000/s** and is flat
in the size of the transaction, where it was 6 895/s and quadratic.

**A note on the third fix, because the bug was in the fix.** It was written
first as a table of tables, keyed by index name. Keying by index name needed
the writer to consult `tx.indicesToUpdate` while the reader consulted
`ctx.indices` — two sources of truth, so a test with its own registry
recorded nothing and the seek silently found nothing. Re-keyed by
`(label, property)`, both sides agree. Then the bucket map was *copied* on
every lookup, because Nim's `Table.[]` returns its value by value: the
"O(1)" seek was O(buckets), and the benchmark still moved only 3.8x. A flat
map, read without binding, is the version that works.

Range predicates (`>`, `IN`, …) still walk the delta rather than consulting
the index — an equality key has a bucket, a range does not, and a seek that
*misses* a row cannot be repaired by the filter above it. Slower, and
correct; the M11 test suite pins it.

## 3. Benchmark scale is small, and that is a consequence of §2

`make bench` compares glyphes against SQLite edge tables at **5 000 nodes /
20 000 edges** by default. That is small enough that the SQLite numbers should
be read as generous to SQLite: at this size SQLite's page cache holds the
entire database.

Read the comparison as *"which architecture is doing the same work faster"*,
not as *"what will my production graph do"*. The 10⁶-node fixtures the other
gates use (M1, C9, W3, R8) are the ones with real scale behind them.

The benchmark refuses to print a timing whose row counts disagree between the
two systems. An earlier draft compared glyphes walking internal node ids
against SQLite walking property ids — two different questions — and printed
the difference as a speed. That assertion is now the first thing the benchmark
does.

## 4. SQLite with edge tables won every benchmark

`make bench-sqlite`, at 5 000 nodes / 20 000 edges, ratio = sqlite / glyphes
(below 1.0 means SQLite was faster):

| workload | glyphes | sqlite | ratio |
|---|---|---|---|
| load (nodes) | 0.077 s | 0.014 s | 0.2x |
| load (edges) | 89.2 s | 0.029 s | 0.0x |
| point | 0.005 s | 0.003 s | 0.6x |
| one-hop | 0.036 s | 0.014 s | 0.4x |
| two-hop | 0.008 s | 0.004 s | 0.4x |
| filter | 0.002 s | 0.000 s | 0.1x |

**SQLite was faster on all of them.** This section is not a formality. The
row counts were checked equal first — the benchmark refuses to print a
timing whose answers disagree — so these are two systems answering the same
question correctly, and one of them did it sooner.

What the numbers do support: glyphes' per-statement overhead is small (a
point lookup is 25 µs, and it is 6x closer to SQLite than it was before
`MERGE` learned to seek). The *edge load* gap is §2: 224 edges/second here,
against 643–892/s measured on a smaller graph, because this run loads all
20 000 edges in one transaction and a MERGE re-scans its unpublished delta
per statement.

What they do not support is any claim that glyphes beats SQLite on these
workloads. It does not, at this scale, and publishing the table is the point.

## 5. SQLite with edge tables is a serious alternative

It is free, embedded, needs no daemon, has existed for decades, and has a
B-tree index on every column. For a read-mostly graph queried by id, SQLite
will often match or beat glyphes, and its bulk load is genuinely faster than
anything glyphes does through the query language (§2).

glyphes exists because of the *shape* of the operations — traversal with
per-hop variable binding, a model layer, one transaction spanning many
pattern clauses — not because the storage is faster. The benchmark in
`tests/bench/bench_sqlite.rb` is the honest version of that comparison.

## 6. One writer across processes, and a follower that follows

There is no server, no wire protocol, and no network listener. That part is
unchanged and is `PRD-GLYPHES.md` pin P1.

**One writer is now enforced across processes**, not just within one. A
second process opening a writable database takes an exclusive `flock` on a
`-lock` file beside it, and is refused with `GLY_ERR_BUSY` if another process
holds it (`PRD-SHARED.md` S1). Before this, the writer claim was an
in-process atomic and two processes could each open one graph file and each
believe they were alone — the invariant was true only in the scope the old
version of this section named, and the rest of this file is honest about
which scope that was.

**A reader in another process can now follow** (`PRD-SHARED.md` F1–F3). It
maps a 16-byte watermark the writer publishes at each commit, reads `.vhist`
up to the generation that watermark names, and builds a revision timeline of
its own. `nimble crashFollower` is the gate: it SIGKILLs a real writer
mid-commit, where `.vhist` is durable but the watermark has not moved, and
checks the follower is short by exactly the in-flight commit, shows nothing
the database does not have, and leaves the untrusted tail for its owner.

What the follower is **not**:

- **It is not a graph reader.** It holds no nodes, issues no Cypher, and
  cannot answer `MATCH`. It answers questions about *history* — `followState`,
  `followDiff`, `commitsUpTo` — and the distinction is in the type, not in a
  check someone could forget. A process that wants the live graph still has to
  open it, and a second *writable* open is refused.
- **It follows on `refresh`, not automatically.** There is no notification;
  a caller polls. Polling is cheap — incremental from a byte offset the last
  replay proved good, so O(new commits), not O(history) per tick — but it is
  still the caller's loop, and a follower nobody refreshes does not advance.
- **It sees node history only.** No edges, labels or indexes are in the log,
  so a follower cannot audit a relationship change at all.
- **History is node-liveness and node-properties only**, so a follower cannot
  answer a graph question even in principle. See §8.

What is still **not** supported:

- **The writer role cannot move** between live processes. It is held for the
  life of the writing `Database` (S1); letting it migrate is S4.
- **A shared database grows its WAL** and cannot checkpoint, compact or
  renumber while shared (S9). A maintenance open is what reclaims it.
- **A second writer must still come up to date before it writes.** The lock
  serialises writers; it does not replay the log for one. A process that
  opens, replays at open (as `openDatabase` does) and then writes is
  correct; one that opens raw and writes over another process's ids is not.
- **Network filesystems are refused by name** (S10). POSIX advisory locks
  are unreliable or absent on NFS and SMB, and a database whose correctness
  depends on them does not run on one.

The soak (`tests/soak/soak_leak.nim`) runs threads inside one process;
`tests/soak/soak_shared.nim` (S1) is the two-process writer version.
`tests/unit/test_follow.nim` (SG7) forks a real writer and follows it, and
`tests/crash/crashfollow.nim` does the same with the writer killed mid-commit.
Neither of those is a long-running soak: there is no hours-long two-process
reader soak, so the follower's behaviour over a long-lived writer and a large
`.vhist` is covered by unit gates rather than by endurance.

## 7. Not yet done

Named honestly rather than left to be discovered:

- **T4 and T6** (per the PRD's deviation record) are unimplemented.
- **No crash-consistency proof at scale.** W2 and W3 truncate and corrupt
  deliberately and check that openings are named rather than silent, but 5 days
  of continuous writing on one machine is not the same as a power-cut matrix.
- **The vector index is a tuning target, not a finished answer.** Recall@10
  is 0.893 at ef=64 on 20k uniform vectors. That is a real number and it is
  not competitive with a tuned HNSW.
- **Single-node only.** No clustering, no replication, no sharding.
- **No query planner with cardinality estimates.** Two indexed predicates and
  the first one in source order wins (EXEC.md §4.1). This is deterministic,
  which is testable, and it is not smart.
- **Memory growth under long reads.** The snapshot path is exercised by the
  soak, which found no leak — but the soak is one configuration of one machine.
- **Version history cannot be queried from a graph query.** §8 describes a
  durable, crash-safe history and a `diff` that is O(changed). A follower can
  now reach it from Nim (§6), but there is still **no Cypher statement, no
  Ruby method and no CLI** that asks a question about history — which is the
  part a user would actually reach for. The writer's own surface cannot read
  its history either; only a second process observing it can.
- **A record holds at most 32 767 properties.** `prop_count` is an `int16`
  in both record types. The 32 768th property is refused by name
  (`glyphes: a record carries at most 32767 properties`) rather than
  wrapping the count negative, which is what it used to do: release builds
  read garbage lengths from the count and range-checked builds raised a
  `RangeDefect` on a legal statement. The per-transaction op budget is 10M,
  two orders of magnitude above the wrap, so no ordinary query reaches the
  ceiling — but a bulk loader that stamps one wide record per node will, and
  the right fix is a wider count field rather than a louder error.
## 8. Version history is durable, and it is not free

Added in the same release as everything above, and every cost below is real
and measured rather than anticipated. History is **not** on by default: a
database gets a `.vhist` sidecar only when it is opened by path, and nothing in
the *query* surface can read it. A follower's Nim API can (§6), which is
enough to make the history useful for auditing and not enough to make it part
of the product. It exists, it survives a crash, and only an out-of-band
process can ask it anything.

**A commit is now O(changed) rather than O(1), in a new place.** V0.2 records
the property delta every transaction produced, which is what makes a revision
honest rather than a snapshot of whatever the node happened to look like at
commit time. The cost is that a revision holds a `Value`, so a bulk load that
writes vectors now holds two copies of every vector for the life of the
history. At 10⁶ nodes with 768-dim embeddings that is not a rounding error,
and it has not been measured end to end.

**A large transaction is a large frame.** The sidecar is one frame per commit
rather than one per revision, because a commit is the transaction and a
transaction is atomic — but that means a 10⁶-node bulk load is a single frame
of hundreds of megabytes, held in memory while it is encoded. The framing
choice is right for recovery and wrong for very large transactions, and the
right answer is a commit framing that can span frames, which V1 does not have.

**`diff` is O(changed + depth), not O(changed).** The PRD §5.1 claim holds on
the axis it makes — a 10⁴-node and a 10⁶-node graph cost the same, measured
flat at ~1× — but history depth is a second axis, and a diff resolves each
head's ancestry once into a flag array sized to the whole history. At a 10⁵
commit history that is 8.8× for a 50 000× deeper history: paid once, sublinear,
and still real. Making it O(1) needs per-commit ancestor bitmaps or generation
numbers, which is V1/V2 work that has not been done.

**The history can be ahead of the graph, by one commit, after a crash.** The
sidecar is written and `fdatasync`ed *before* the log's COMMIT frame, so
history is never *behind* the graph — a silent omission is the one incoherence
this feature cannot have. The price is the mirror case: a crash between the two
leaves a commit in the file that the graph never accepted. Each frame carries
the generation it was written against and replay drops anything above the
graph's, so it is repaired at the next open. This is a deliberate trade, not an
oversight, and the alternative ordering is the one that loses commits quietly.

**Renumbering rewrites history.** Compaction (`STORAGE.md` §4.7,
`src/store/ids.nim`'s `reclaim`/`renumberTo`) densifies live ids, so a revision
recorded against id 41 would start describing whichever node became 41. The
machinery has **no caller in `src/`** today, so there is no live bug — which is
exactly why the decision belongs in a PRD rather than in a fix. Versioned node
ids are pinned to never participate in renumbering, which means a versioned
graph gets a dense id space that stops being dense, and compaction of the node
array is partial or absent. That is the price of keeping history.

**What is deliberately absent, and why.** Edge history (a separate document),
historical indexed scans (the index indexes the head; serving "which nodes
matched at commit C" means an index per commit), and merge resolution across
branches (refused by name, like every other out-of-contract row in §1). Branch
history and the read surface are V2 and V3; until then a two-branch graph has
the union of its branches and no way to ask for one of them.

## 9. What M11 changed about the engine itself

`limitations.md` is not only about what is missing. M11's benchmark found four
defects, all fixed in the same milestone, all of them the kind a correctness
gate cannot see because the answers came back *right*:

| defect | effect |
|---|---|
| a seek predicate accepted only a literal, never a parameter | every parameterized query full-scanned; 235/s against 46 009/s |
| an inline pattern property `{id: $id}` was never a seek candidate | the common inline spelling full-scanned; 84/s against 9 998/s |
| a seek replaced the whole pattern chain | **every relationship in the pattern was dropped** |
| the variable-length walk popped its stack frame at the hop limit | `*1..2` silently omitted every branch past the first |
| `query`/`prepare` never joined an open transaction | a read in the middle of `db.transaction` could not see that transaction's writes — every read returned the pre-transaction snapshot |

Two of those are silent *wrong answers*, and they are the ones that matter:

- **A seek dropped the pattern's relationships.** `MATCH (a)-[:KNOWS]->(b)
  WHERE a.age = 30` returned one row with `b` unbound. It existed because
  index-seeking had only ever been tested on patterns with no relationships
  in them, and the TCK runs without indexes so it never seeked at all.
- **`*1..2` forgot its branches.** On `0→1, 0→2, 1→2, 1→3` it answered
  `[1, 2, 2]` and dropped the 3, which then appeared at `*1..3` — one hop
  late. Every variable-length test used a *ring*, where each node has one
  out-edge; with one candidate per frame, "pop the frame" and "back up one
  edge" are indistinguishable.

Both were found by the benchmark asserting that two engines returned the same
rows — the assertion that caught this benchmark's *own* first draft, which
compared internal ids against property ids. The full account is in
`DEVLOG.md`, "the literal gate".

## 10. What the whole-product review changed about the engine

A later pass read all four subsystems adversarially — versioning, follower,
storage/WAL/transactions, Cypher — and then *ran* each finding before
believing it. Roughly thirty came back; eleven were confirmed by execution,
and every confirmed one is fixed and gated. Three of them belong in this file
rather than only in `DEVLOG.md`, because a user can hit them:

| defect | effect, as a user would describe it |
|---|---|
| a rolled-back transaction kept its property overwrites | `SET x = 9` then `rollback()` still read 9 in the committed state — and a concurrent reader could see the half-written slot |
| a seek could lose every row the head variable did not match | with `:Person(age)` indexed, `WHERE b.age = 41` returned **0 rows** where the same query unindexed returned 1 |
| `WHERE true RETURN 1` | segfaulted the host process |

The rest were the same species at lower altitudes: seven `fdatasync`/
`ftruncate` results discarded, a durable phantom commit surviving a refused
append, a checkpoint that could lose an acknowledged commit, a handle the
registry never released, a follower applying three commits for a two-commit
writer, a `backup` that left the history behind.

**What the review changed about the gates, which is the lasting part.** Every
gate that would have caught one of these was present, running, and green —
pointed at a slightly different input. The rollback test only set *new*
keys; the index differential only ever sought on the head variable; the
sidecar corruption test flipped only the last frame; a `Busy` assertion was
passing *because* of a deadlock wedge beside it. So the rule this project
ended on is about oracles, not about bugs:

> A passing test says the thing it was aimed at is fine. It says nothing
> about anything else — and an oracle's *inputs* decide its power, not its
> existence.

Each fix here ships with the test that closes the hole rather than the test
that was extended, and the counts, the arithmetic and the claims behind them
are in `DEVLOG.md`, under the review's own sections.

*Measurements in this file were taken on the development machine. They are
reproducible with `make bench`, and they will differ on yours — the ratios are
the claim, the absolute numbers are not.*
