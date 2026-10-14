# glyphes — limitations

This file is published **before** the release, not after, and that ordering is
the point. A limitations document written once the work is done is a press
release with a table. This one is the list of things glyphes is bad at, with
measurements, written by the people who measured them.

glyphes is 0.1. It is an embedded graph store with a Cypher subset, a Rails-
shaped Ruby model layer, hybrid index families, and a write-ahead log. It is
not a database that should be dropped into production, and most of the rest of
this file is about why.

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

**Not implemented:** subqueries, `FOREACH`, shortest-path functions, graph
pattern predicates, `EXISTS { … }` subqueries, most of the type system,
temporal/spatial types, and multi-database.

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

The seek machinery now lives in `ops.nim` and both paths go through it.
Measured on this machine, 3·10³ nodes with an index on the lookup property:

| operation | before | after |
|---|---|---|
| `CREATE (:Person {…})` in a transaction | 21 620/s | 21 620/s |
| `MATCH (x:Person {id: $id}) RETURN x` | 11 843/s | 11 843/s |
| `MATCH (x:Person {id: $id}) MERGE (y:Person {id: $id})` | 275/s | **1 037/s** |
| edge load, end to end | ~150–230/s | **643–892/s** |

**This is still slow, and the remaining gap is a different problem.** A MERGE
inside an open write transaction consults the transaction's delta for nodes it
has not published yet, and that scan is proportional to the transaction's size
— so one long bulk-load transaction is quadratic. Splitting the load into many
smaller transactions is measurably faster (892/s against 643/s at 12 000 edges)
for exactly that reason.

Until the delta is cached per transaction rather than re-scanned per
statement, **do not bulk-load a graph through the query language.** Use the
importer (M9), which uses the store's own write path. That advice is why this
section is a limitation and not a bug report.

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

## 6. Single-process, single-writer

There is no server, no wire protocol, and no network listener. Concurrency is
threads inside one process, and there is **one writer at a time**: a second
writer gets `GLY_ERR_BUSY` (T5) and is expected to retry. The soak
(`tests/soak/soak_leak.nim`) runs 20 threads in one process; it says nothing
about two processes on two machines.

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

## 8. What M11 changed about the engine itself

`limitations.md` is not only about what is missing. M11's benchmark found four
defects, all fixed in the same milestone, all of them the kind a correctness
gate cannot see because the answers came back *right*:

| defect | effect |
|---|---|
| a seek predicate accepted only a literal, never a parameter | every parameterized query full-scanned; 235/s against 46 009/s |
| an inline pattern property `{id: $id}` was never a seek candidate | the common inline spelling full-scanned; 84/s against 9 998/s |
| a seek replaced the whole pattern chain | **every relationship in the pattern was dropped** |
| the variable-length walk popped its stack frame at the hop limit | `*1..2` silently omitted every branch past the first |

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

*Measurements in this file were taken on the development machine. They are
reproducible with `make bench`, and they will differ on yours — the ratios are
the claim, the absolute numbers are not.*
