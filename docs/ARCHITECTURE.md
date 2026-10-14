# glyphes — ARCHITECTURE

The map. The other documents in `docs/` each own one layer in depth
(`STORAGE.md`, `TXN.md`, `EXEC.md`, `INDEX.md`, `CYPHER.md`, `RUBY.md`,
`WAL.md`, `ABI.md`); this one says how they fit together, in the order a
reader needs them.

---

## 1. What this is

An embedded graph store with a Cypher subset, a write-ahead log, hybrid
indexes, and a Ruby binding. One process, one file, no server, no daemon.

The design commitment that shapes everything else: **the graph is memory, and
durability is a log.** Nodes, adjacency, labels and properties live in
process memory in arrays; the write-ahead log is what makes them survive.

## 2. The layers, outside in

```
  Ruby                  lib/glyphes, lib/glyph (model layer, Rails-shaped)
    │                   FFI, one C entry point per operation
  ───────────────────────────────────────────────────────────────
  ABI                   src/glyphes.nim, src/abi.nim
    │                   status codes, handle lifetime, the three ABI rules
  ───────────────────────────────────────────────────────────────
  Cypher                src/cypher/
    │                   parser → plan → operators (a pull cursor)
  ───────────────────────────────────────────────────────────────
  Indexes               src/index/
    │                   range, text (inverted + BM25), vector (HNSW)
  ───────────────────────────────────────────────────────────────
  Transactions          src/txn/
    │                   one writer, snapshots by generation, MVCC-ish
  ───────────────────────────────────────────────────────────────
  Store                 src/store/
    │                   node/edge records, adjacency chains, arena props
  ───────────────────────────────────────────────────────────────
  WAL                   src/wal/
                        framed, CRC'd, group-committed, truncated at checkpoint
```

Each layer only knows the one below it through an interface, and the
dependency direction is strictly downward. The one deliberate exception is
noted in `ops.nim`: `mergeChain` cannot call the planner, because the planner
imports the operator module. That exception is currently costing a great deal
of performance — see `limitations.md` §2.

## 3. The read path

A query is one pipeline, and every stage is a pull cursor that answers "do you
have a next row":

```
  query text
     │  parser.nim        tokens → AST (QueryPart list)
     ▼
  plan.nim               parts → operator chain, once per prepare
     │                   a seek, a scan, an expand, a filter, an aggregate…
     ▼
  ops.nim (step)         row in, row out; the statement owns the chain
     │                   LIFO execution, no materialisation
     ▼
  store / txn / index    snapshots read at a fixed generation
```

Two properties follow, and both are load-bearing:

- **The plan is built once per prepare, not per row.** `MERGE` is the
  exception, which is why it is slow: it re-plans its match half for every
  row it sees.
- **A seek is a candidate generator, never an authority.** The predicate that
  motivated the seek still runs as a filter above it. So a wrong or stale
  index can *lose* a row, and cannot invent one — and the direction that
  matters is guarded explicitly: a key the index cannot hold (a bool, a list,
  `null`, an unbound parameter) must fall back to the scan, because returning
  nothing is fewer rows than the scan finds.

## 4. The write path

```
  CREATE / SET / DELETE / MERGE
     │
     ▼
  txn.nim                begin → mutate a private delta → commit
     │                   exactly one writer; others get GLY_ERR_BUSY (T5)
     ▼
  WAL frame              header + payload, CRC32C over the whole frame,
     │                   length in the header, group commit
     ▼
  publish                atomically swap the published arrays
     │
     ▼
  indexes                updated inside the same transaction
```

A reader that opened a snapshot keeps its generation for its whole life, so a
concurrent commit is invisible to it. At a checkpoint the log is truncated and
the on-disk shape is compacted.

**Corruption is named, never silent.** A frame that fails its CRC produces
`GLY_ERR_CORRUPT`; a snapshot that cannot be opened produces a named refusal.
W3 verified this across a million-row sweep: 999 883 named errors, 117
explicitly ambiguous final-frame length flips, **0 silent corruptions**.

## 5. Indexes

Three families, one registry, one rule: an index is never stale relative to
committed data (I11).

- **Range** — sorted key blocks plus a delta. Point seek and range scan.
- **Text** — inverted postings with BM25 scoring, pushed-down filters.
- **Vector** — HNSW with a recall gate, deterministic under a fixed seed.

Index choice in the planner is **source order, not cost**: with two indexed
predicates and no cardinality estimates, the first one written wins. That is
deterministic and testable. It is not smart, and `limitations.md` says so.

The planner's seek candidates are, in order: the pattern's own inline
properties, then the conjuncts of `WHERE`. Both accept a literal *or* a
parameter. Getting that wrong is not a performance footnote — see §7.

## 6. The Ruby layer

`Glyphes::Database` is a thin, honest FFI wrapper: no lazy anything, a
`GLY_ERR_*` becomes the matching Ruby exception, and every resource has a
deterministic lifetime. `Glyph::Base` is the Rails-shaped model layer on top
(`where` / `create` / `save` / associations / validations), compiling to the
same Cypher anyone would write by hand.

The model layer is not a second implementation. `P.where(age: 30)` becomes a
parameterized query, which is exactly why the parameter-seek defect of §7 hurt
it 155× more than it hurt hand-written Cypher.

## 7. Reading the benchmarks

`make bench` runs the whole suite. The headline comparison is M11's
`tests/bench/bench_sqlite.rb`: the same seeded graph in glyphes and in SQLite
edge tables, with SQLite given a nodes table, an edges table, and B-tree
indexes on both endpoints and the property column — created *after* the load,
the way a table is really built.

**How to read a row:**

- **`ratio` is sqlite / glyphes.** Above 1.0 means glyphes is faster on that
  workload. It is a ratio, not a verdict.
- **The load row is a statement-cost measurement, not a storage one.**
  glyphes loads a graph by interpreting statements; SQLite bulk-inserts
  integer rows. SQLite wins there and it should.
- **The query rows are the interesting ones** — they are the same graph,
  answered the same way, with the row counts checked equal first. The
  benchmark refuses to print a timing whose answers disagree.
- **Absolute numbers are machine-specific.** The ratios are the claim.

**The measured result, at 5 000 nodes / 20 000 edges** (ratio = sqlite /
glyphes; below 1.0 means SQLite was faster):

| workload | glyphes | sqlite | ratio |
|---|---|---|---|
| load (nodes) | 0.218 s | 0.013 s | 0.1x |
| load (edges) | 108.9 s | 0.051 s | 0.0x |
| point | 0.010 s | 0.002 s | 0.2x |
| one-hop | 0.049 s | 0.012 s | 0.2x |
| two-hop | 0.014 s | 0.006 s | 0.4x |
| filter | 0.002 s | 0.000 s | 0.1x |

**SQLite won every row.** That is the honest result and it is the reason
`limitations.md` exists. Two things are true at once: the engine overheads
here are per-statement and small (a point lookup is 50 µs, not 5 ms), and
SQLite still does the same work faster at this size. glyphes' argument is
the *shape* of the queries and the model layer, not that it wins a
micro-benchmark against a B-tree — and a reader who only read the ratio
column would conclude the opposite.

The edge-load row (108.9 s vs 0.051 s) is the `MERGE` cost of
`limitations.md` §2, measured end to end: 183 edges/second.

**Three things the numbers will not tell you**, all in `limitations.md`:
benchmark scale is small and small favours SQLite's page cache; bulk load
should not be done through the query language at all; and SQLite with edge
tables is a genuinely serious alternative for read-mostly graphs.

### What the benchmark found

M11's benchmark was supposed to measure the engine. It found three defects in
the index path first, all of which had been shipping with *correct answers*:

| | before | after |
|---|---|---|
| `WHERE n.age = $age` (parameter) | 235/s | 46 009/s |
| `MATCH (n {age: $age})` (inline) | 84/s | 9 998/s |
| a seek over a pattern with a relationship | **dropped every edge** | correct |

The third is the one to remember: the planner assigned the seek to the seed
and stopped, so every `Expand` in the pattern was lost whenever it seeked.
`MATCH (a)-[:KNOWS]->(b) WHERE a.age = 30` answered with one row and `b`
unbound. No error, and the wrong answer was *faster*, so no timing gate could
see it either.

It survived because index-seeking had only ever been tested on patterns with
no relationships in them. The lesson generalises past indexes: **a benchmark
that asks a question nobody was asking will find things the test suite was
not looking for**, and the first version of this benchmark did not survive
contact with the engine either — it compared internal ids on one side against
property ids on the other, and printed the difference as a speed.

## 8. Where to read next

| question | document |
|---|---|
| what is on disk, byte by byte | `STORAGE.md` |
| what a transaction guarantees | `TXN.md` |
| what the operator set is | `EXEC.md` |
| what an index guarantees | `INDEX.md` |
| what the language accepts and refuses | `CYPHER.md` |
| what the Ruby layer promises | `RUBY.md` |
| what crosses the FFI boundary | `ABI.md` |
| how to run and trust the gates | `TESTING.md` |
| what is not finished | `../limitations.md` |
| why any of this exists | `PRD-GLYPHES.md` |
