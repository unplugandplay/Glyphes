# glyphes — PRD: the SQLite of graphs

> *One file. One process. ActiveRecord-shaped. Vector and text search in
> the same query as the traversal.*

**Status:** PRD, pre-implementation. Every *pin* is normative; every *gate*
is a merge condition. Where code and this document disagree, this document
leads.

**Family:** glyphes is a runes-lang sibling of `../nimblyru` and
`../nimaps`, written in Nim with a Ruby-facing surface. It borrows two
things and nothing else: the Ruby semantic skin and the
ActiveRecord-shaped model layer conventions documented in
`../nimblyru/docs/JZYR-AR.md` §3–§6 (Rails names, the verbs, the
validation door), and the "one small binary, one file, one backup story"
posture of `../nimaps`. The engine is not a JZyr ORM and does not depend
on nimblyru the compiler.

---

## 1. What this is

**glyphes is an embeddable graph database: a labeled property graph that
lives in one file, in your process, driven from Ruby like ActiveRecord
drives SQLite.**

It is SQLite with the triple store taken seriously. SQLite gives you
tables, indexes, transactions and a query language, and it treats a
many-to-many relationship as a foreign key and a JOIN you write by hand.
glyphes gives you nodes, edges, labels and relationships as *first-class
things you traverse*, plus the three index families SQLite cannot express
in a single statement — full-text and vector similarity — in the *same*
query as the traversal.

```ruby
Glyphes::Database.open("memory.glyph", create: true) do |db|
  db.transaction { db.exec("CREATE (:Doc {title: $t, body: $b, embedding: $e})") }

  db.query(<<~CYPHER).each do |row|
    CALL db.idx.vector("Doc.embedding").query($q, 10)
    YIELD node, score
    WHERE node.year >= 2024
    MATCH (node)-[:CITES]->(other)
    RETURN node.title, other.title, score
    ORDER BY score DESC
  CYPHER
  end
end
```

That single statement — vector recall, filter, traversal, order — is the
product. Not the storage. Not the protocol. The **co-location** of
similarity search and graph traversal in one atomic, transactional,
in-process operation.

### The problem it solves

Working with graphs today means one of three bad trades:

1. **Neo4j / Memgraph.** Correct, Cypher-complete, and a resident
   multi-hundred-megabyte JVM or C++ process plus a socket for a graph
   that might be 20 MB. For an agent memory, a Rails app's user
   relationships, or a RAG document set, this is a server you did not
   ask for, cannot commit to git, and cannot `fork`.
2. **SQLite with edge tables.** Free, embedded, ACID. But every
   traversal is a hand-written `JOIN`, full-text is FTS5 bolted onto one
   table, vectors are a blob column plus a brute-force cosine in Ruby,
   and the shape of the data lives in your query strings instead of in
   the schema.
3. **An embedded graph library.** ArangoDB's C driver, or a graph library
   over B-trees. In-memory, no durability, or durability only on shutdown
   — you lose the file on crash, which is the one property SQLite
   guaranteed you before anything else.

glyphes takes option 3 and adds back the one thing it was missing:
**crash-safe durability with atomic commit.** And it ships the Ruby
interface, because a database you cannot call from `db.query` in a Rails
service does not get adopted.

### What we deliberately don't do

No server. No socket. No Bolt. No replication, no Raft, no failover, no
multi-tenancy, no authentication, no authorization, no audit log, no
schema migrations engine, no stored procedures, no user-defined
functions, no Cypher shell as a primary interface, no CDC stream, no
Kafka, no S3, no Parquet reader in the engine, no CUDA, no graph
algorithm library.

Every one of those is in Memgraph. Every one of them is why Memgraph is
400,000 lines and a Docker image. None of them is in scope until the file
format is proven and a second process needs to open it. They live in
§9 as phase-2 candidates, deliberately un-budgeted.

---

## 2. Why Nim, again, and this time concretely

The engine is 90% pointer-chasing over dense integer arrays with hash
lookups on the side, running inside someone else's process for hours.
That rules out a GC language outright: a GC in an embedded library is a
latency source you cannot profile because it belongs to the host, and a
pause inside a transaction that has partially written to the WAL is a
corruption source.

Nim gives us:

- **ORC memory management** — deterministic destruction, no tracing GC,
  no pause in the host process. `nim c --mm:orc`.
- **No exceptions across the ABI** (`ABI.md` B8) — errors are status
  codes, which is what FFI requires anyway.
- **cgen for free** — `{.push header: "glyphes.h".}` gives us a real C
  header without maintaining one by hand.
- **Exact integer and float behaviour** — vector math must not shift
  under us, and the same binary must produce the same HNSW graph on
  every machine.

The Ruby-facing half is Ruby, obviously, because that is the door. The
seam is 100 lines of `ffi_lib` plus the FFI gem, and the ABI is specified
in `ABI.md`.

---

## 3. The scope boundary, drawn once

The rule that keeps this small:

> **The engine knows one serialization format: its own snapshot.**

No CSV, no JSON, no Parquet, no Bolt framing, no HTTP, no JSON-RPC in
Nim. File formats are Ruby problems (`lib/glyphes/import.rb`,
`export.rb`) and they are written in Ruby because Ruby has good CSV and
Parquet gems and because a format bug in an importer should not be able to
corrupt the engine.

Exception, one: the snapshot is `mmap`-ed on open, and the WAL is a
binary frame format. Those are storage internals, not interchange
formats, and they are the only two byte layouts in `src/`.

**Stack inventory: `nim >= 2.2`, `ffi` gem, nothing else.** No nimble
dependencies. If a phase below needs a third-party package, that is a
design failure to be solved in Nim, not a dependency to be added.

---

## 4. The storage engine

### 4.1 Shape — SQLite's rowid, specialized

SQLite's most important idea is the **rowid**: a dense `i64` into a
B-tree, so a lookup is an array index and an insert is an append.
glyphes applies it to both node and edge tables:

```
NodeRec (48 bytes)
  id            i64    dense, never reused within a generation
  label         i32    dictionary code, not a string
  prop_count    i16
  flags         u16    tombstone / lock bits
  prop_slots    i32    offset into the property arena
  out_head      i64    first edge in the forward list
  in_head       i64    first edge in the reverse list
  out_count     i32
  in_count      i32

EdgeRec (48 bytes)
  id            i64
  type          i32    dictionary code
  src           i64    node id  (outgoing)
  dst           i64    node id  (incoming)
  props         i32    offset into the property arena
  next_out      i64    sibling in src's forward list
  next_in       i64    sibling in dst's reverse list
  flags         u16
```

Adjacency is a **linked list threaded through `next_out` / `next_in`**,
not a `HashMap[Int, Array[Int]]`. Array-of-arrays would put a 24-byte
`seq` header in every node record, allocate a heap block per node on
creation, and make degree-1 nodes cost more than degree-50 nodes. A
threaded list makes a node 48 bytes, an edge 48 bytes, and a
`(:Person)-[:KNOWS]->(:Person)` triple cost 96 bytes plus properties.
Delete is an unlink from both lists; tombstone the record, reclaim the
id on the next snapshot compaction.

**Why not CSR (compressed sparse row)?** CSR gives better traversal
locality and no pointer chasing, which is why Memgraph uses it. CSR also
requires rebuilding both arrays on every write to a high-degree node,
which makes the write-heavy import path — the actual reason you adopt an
embedded graph store — quadratic on hub nodes. Threaded lists win for
embedded with mixed read/write. CSR is the documented phase-2
alternative if read benchmarks show traversal latency matters more than
import throughput.

### 4.2 Properties — slots, inline when small

Properties are interned to `i32` keys and stored in a typed slot array.
Values ≤ 8 bytes are inline; blobs and vectors go to an overflow arena
with an offset pointer.

```
PropSlot (16 bytes; STORAGE.md §2.4 corrected this from 24 at M1)
  key       i32
  type      u8      GlyType
  flags     u8      null / dirty / inline
  aux       u16     length for str/bytes, dims for vector
  payload   u64     inline value, or arena byte offset
```

A record's slot array doubles from **2**, so 1 property costs 2 slots and
3 costs 4. That number is set by measurement, not taste: at 4, a record
with a single property still allocated 64 bytes, which was 320 MB of the
620 MB budget on the M1 fixture (`STORAGE.md` S14). That budget was
re-derived at M3 to 680 MB on a corrected metric (`STORAGE.md` §0 and
§7); the slot rule did not change.

Property lookup is a linear scan over `prop_count` slots. For `prop_count
< 16` that beats hashing on cache behaviour — the whole slot array is
one or two cache lines — and property counts above 16 per node are rare
enough that the slow case does not matter. `aux` holds the arena *offset*,
never a pointer, so the store stays relocatable and snapshot-writable
without a fixup pass.

### 4.3 Dictionaries

Label and relationship-type strings are interned to `i32` codes once, in
an open-addressing hash map. Per label we keep a dense `seq[int64]` of
member node ids — this is the label index, and it is what makes
`MATCH (p:Person)` a linear scan over one contiguous array instead of a
full node-table sweep. The list is unordered; a node's index within it
lives in a store-level `labelPos: seq[int32]`, so removal is O(1)
swap-remove rather than a scan of the label (`STORAGE.md` §4.3). That
scan version was quadratic on the obvious workload — deleting 10⁵ nodes
from a 5·10⁴-member label — and it is why `labelPos` is store state that
the snapshot has to serialize (`WAL.md` §4.2a).

### 4.4 Transactions — SQLite's model, not Memgraph's epochs

Memgraph's epoch MVCC exists to serve a concurrent multi-process server.
glyphes is one process, embedded. So:

- **One writer.** A second `tx_begin` returns `GLY_ERR_BUSY`.
- **Snapshot readers.** Each committed state bumps a `generation`
  counter. A statement captures it at `prepare` and holds it until close.
- **Copy-on-write.** Writes go to shadow structures; a reader on an old
  generation keeps seeing the old arrays. Committed mutations are merged
  into the base arrays under a single pointer swap, which is the atomic
  commit point.
- **Isolation: serializable.** Because there is exactly one writer and
  commits are total orders, a reader either sees a whole commit or none
  of it. This is SQLite's answer and it is sufficient.

No epochs, no delta chain, no background advance thread. `P7` in
`ABI.md` pins this. The door is left open — the `generation` counter is
where an epoch scheme would attach — but it is not built until something
needs it.

### 4.5 Durability — the thing that makes it real

I got this wrong in conversation and the PRD corrects it: an embedded
graph store without crash-safe commit is not a database, it is a demo.

**WAL.** Append-only frames of `(lsn u64, checksum u32, mutation)`.
Mutations are typed opcodes — `CreateNode`, `AddLabel`, `SetProp`,
`CreateEdge`, `DeleteNode`, … — not Cypher text, so replay does not need
a parser and cannot be affected by a language change. `fsync` on commit
by default, because the default is the one people ship.

**Snapshot.** Compact binary dump of the whole store, written at
checkpoint, `mmap`-ed read-only on next open. Node array, edge array,
property arena, dictionaries, index blocks, plus a trailing CRC32 over
everything. The snapshot is what makes open O(1) instead of replaying an
unbounded WAL.

**Recovery.** On open: mmap the snapshot, scan the WAL, apply frames with
`lsn > snapshot.lsn`, stop at the first bad checksum. A torn tail — the
last frame half-written because the process died mid-write — is detected
by checksum and truncated. Replay is idempotent by `lsn`, so recovery can
be re-run safely.

**Checkpoint** runs automatically when WAL exceeds a configured threshold
(default 64 MB), and on `close`. Manual via `db.checkpoint`.

### 4.6 Indices — the actual differentiator

Three families, all queryable in the same statement as the traversal:

| Family | Structure | Notes |
|---|---|---|
| label / type | dense id list per dictionary entry | built-in, §4.3 |
| range | sorted block array, 4 KB blocks, B-tree overlay on overflow | `WHERE p.age > 30` without a scan |
| text | inverted index + BM25 | tokenizer: unicode-aware, configurable |
| vector | HNSW (`m=16`, `ef_construction=200`) | cosine / L2 / dot; filtered traversal |

Two details that decide whether the vector index is usable:

**Filtered HNSW.** `WHERE node.year >= 2024` after a `CALL
db.idx.vector(...).query()` must not degrade into a full scan. The
traversal carries the filter as a predicate evaluated during the graph
walk, and the candidate set is over-fetched by `1/selectivity`. This is
the single biggest practical difference between a vector index that works
in a graph context and one that doesn't.

**Explicit build.** `idx.build(name)` populates an HNSW from an existing
store 10–40x faster than incremental inserts. Importers do
`CREATE` → `idx.build` → `query`, and never pay per-insert HNSW cost.

Deleted nodes leave tombstone markers in the index; `ef` search filters
them and over-fetches to compensate. HNSW is approximate by
construction, so `ef` is a tunable, not a correctness knob — but a
deleted node must never be returned, which makes tombstone filtering a
correctness requirement, not an optimization.

---

## 5. The query layer

### 5.1 The subset

Contract, in full:

```
CREATE   (n:Label {k: v, ...})   DELETE n   SET n.k = v   SET n:Label   REMOVE n.k
MATCH    (a)-[r:TYPE]->(b)       OPTIONAL MATCH      variable length: *1..3
WHERE    comparisons, AND/OR/NOT, IN, IS NULL, EXISTS { ... }, string/number fns
WITH     projection + alias       UNWIND list AS x      ORDER BY     SKIP / LIMIT
RETURN   projection, DISTINCT
AGGREGATE count / sum / avg / min / max / collect / stdev
CALL     db.idx.text(...).query()    CALL db.idx.vector(...).query()    YIELD
MERGE    (n:Label {k: $v}) ON CREATE SET ... ON MATCH SET ...
```

Out of contract, and rejected with `GLY_ERR_UNSUPPORTED` rather than
silently mis-evaluated: `UNION`, `CALL {}` subqueries, `FOREACH`,
`LOAD CSV`, user-defined procedures, `USING PERIOD` / temporal, multiple
`DETACH DELETE` semantics beyond the plain one, path pattern expressions
beyond `p = (a)-[*]->(b)`.

Full openCypher conformance is a multi-year project and we are not doing
it. The subset above is the ~70% of Cypher that real application queries
use. Every construct outside it returns a *specific* error naming the
construct, never a wrong answer.

### 5.2 Execution — volcano, pull-based

One operator per clause. Each has `init()` and `next() -> bool` +
`current()`. No operator holds a materialized result set.

```
ScanByLabel ──┐
ScanAll ──────┤
IndexSeek ────┼──▶ Expand ──▶ Filter ──▶ Project ──▶ Aggregate ──▶ Sort ──▶ Limit
Unwind ───────┘                                                    └─▶ DISTINCT
```

**This is the decision that keeps the codebase small, and it is
irreversible in practice.** Materializing at operators is what turns a
3k-line executor into a 15k-line one with a spill-to-disk subsystem and a
memory accountant. Pull-based operators compose with no intermediate
buffers; `LIMIT 10` short-circuits after ten rows; `Aggregate` with a
`GROUP BY` key needs only one hash table, not a sort of the world.

Worst-case memory is O(aggregate group size + sort buffer), and sort is
the only operator allowed to buffer. Sort spills to a temp file above a
threshold. That is the entire memory-management story.

### 5.3 The planner — greedy, deliberately

No cost-based optimizer, no cardinality estimation, no join reordering.
SQLite does not have one either and it is fine for embedded use. The
planner is a rule set evaluated per node pattern:

1. Pattern has a label and the label has ≥ 32 members → `ScanByLabel`
2. Pattern has a label with an equality predicate on an indexed property
   → `IndexSeek`
3. Pattern has a range predicate on an indexed property → `IndexSeek`
4. Otherwise → `ScanAll`, filtered

Then: expand direction is chosen by which side is already bound;
predicates are pushed down to the operator that can evaluate them
cheapest; `OPTIONAL MATCH` becomes `LeftOuterExpand`.

The cost of no optimizer is bad plans on pathologically selective
queries. The benefit is that the planner is 300 lines, fully predictable,
and never the cause of a bug. **Pinned: no cost model in 0.1.**

### 5.4 Vector and text in the same plan

A `CALL db.idx.vector(...).query($v, 10) YIELD node, score` is an
operator like any other — it produces rows. Everything downstream
(`WHERE`, `MATCH`, `ORDER BY`, `LIMIT`) is unchanged. That is the whole
architectural argument for glyphes: because the index is an operator in a
pull-based pipeline and not a separate query language, hybrid retrieval
needs no fusion layer, no result-merging step, and no consistency window
between two systems.

Score is a real Cypher value. `WHERE score > 0.82` works.
`ORDER BY score DESC` works. `WITH node, score ORDER BY score DESC LIMIT
5 MATCH ...` works and is short-circuited correctly by the pull model.

---

## 6. The Ruby surface

### 6.1 The door

```ruby
require "glyphes"

Glyphes::Database.open("social.glyph", create: true) do |db|
  db.exec("CREATE (:Person {name: $n})", {"n" => "Ana"})
  db.transaction { db.exec("MATCH (p:Person) SET p.seen = true") }

  db.query("MATCH (p:Person) RETURN p.name").each do |row|
    puts row.name
  end
end
```

Named parameters only (`ABI.md` B5). `each_slice(256)` is the primitive
so that import of 10⁶ rows is 10⁶/256 FFI crossings, not 10⁶.

### 6.2 The model layer

`Glyph::Base`, shaped like `../nimblyru/docs/JZYR-AR.md` — Rails names,
the missing verbs, the validation door — but over the graph:

```ruby
class Person < Glyph::Base
  has_many :knows, class_name: "Person", via: :knows
  validates :name, presence: true
end

Person.create(name: "Ana", city: "Lyon")
Person.where(city: "Lyon").order(:age).limit(10)
person.knows.create(name: "Bo")
person.update(city: "Nice")     # persists as SET p.city = $city
person.destroy                  # DETACH DELETE
```

The relation vocabulary is the graph's, not the table's: `has_many`,
`belongs_to`, `has_one`, plus `through` for multi-hop. No polymorphic
belongs_to (it needs a type column a graph already has as the label), no
`joins` (you write `MATCH`).

**The hard pin: the model layer is thin.** It must translate method calls
into Cypher and must never cache, never hold a connection, never
materialize a collection behind the caller's back. If you find yourself
wanting the `neo4j-rails` style of a rich model DSL, the boundary has
already leaked — write the Cypher instead. `db.query` is always available
and always the escape hatch.

### 6.3 Import and export — Ruby, on purpose

```ruby
db.import "people.csv",        into: :Person, keys: [:name, :city]
db.import "docs.jsonl",        into: :Doc,   vector: :embedding, dim: 768
db.export db.query("MATCH (p:Person) RETURN p"), to: "people.parquet"
```

Import is a batched `exec` loop inside one transaction, with an optional
final `idx.build`. The engine never sees a CSV. Export is a query plus a
Ruby writer. This split is why the Nim dependency list is empty.

---

## 7. Non-goals

Explicit, so they can be argued against instead of drifting in:

- **Not a server.** No daemon, no socket, no port. Phase 2 at the
  earliest, and it wraps this library rather than replacing it.
- **Not a distributed database.** No replication, no failover, no
  consensus. Your graph is one file on one disk.
- **Not an analytics engine.** No PageRank, no community detection, no
  GNN. Use a Ruby or Python library against an export.
- **Not an OLAP store.** No columnar layout, no compression beyond
  overflow arenas, no column statistics.
- **Not Neo4j-compatible at the protocol level.** No Bolt in 0.1, so no
  existing driver connects. Phase 2, and it is a genuine cost.
- **Not a Cypher reference implementation.** The subset in §5.1, with
  loud errors outside it.
- **Not multi-tenant, not authenticated.** One process, one graph, one
  trust boundary.

---

## 8. Phases

Strictly ordered. Each phase ships with tests and updated docs. Nothing
is done without a passing test at its gate.

### Phase A — the file (M0–M3)

The whole thesis is "one file, crash-safe". If Phase A does not land,
nothing else matters.

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M0 | Spine | `--app:lib`, `glyphes.h`, `abi.nim`, status codes, `db.open/close`, `ffi_lib` binding loads it in Ruby | **LANDED** — Ruby `require "glyphes"` opens `:memory:` and closes clean; `glyphes_version` round-trips; `M0-NOTES.md` |
| M1 | Store | dense ids + free lists, `NodeRec`/`EdgeRec`, threaded adjacency both directions, label dictionary + per-label lists, property slots + arena | **LANDED** — `nimble bench` green: create 1210 ms ≤ 8 s, traversal 162 ms ≤ 400 ms, heap 619 MB ≤ 680 MB (`STORAGE.md` §7 re-derived the metric and the budget at M3); 317 Nim tests incl. a 10⁶-op degree recount |
| M2 | Durability | WAL frames + checksums + `fsync`, snapshot writer, mmap reader, recovery, torn-tail truncation, auto-checkpoint | `kill -9` at 100 random points during a 10⁶-node import; every run recovers to the last committed transaction, byte-identical to a clean shutdown |
| M3 | Transactions | single writer, `generation`, copy-on-write merge, `GLY_ERR_BUSY`, rollback, `integrity_check` | 8 threads, 6 readers + 2 writers, 10 min: no torn read, no deadlock, zero `SIGBUS`; rollback discards 100% of a 10⁵-op transaction |
| | | | **LANDED, with two deviations recorded.** The merge is in place behind the store mutex rather than copy-on-write (TXN.md §4: no copy is needed when no reader can be inside the published arrays, and the copy cost 48 MB per commit at 10⁶ nodes). And the soak has been run at 120 s rather than the 10 min specified here; T4 and T6 remain unimplemented. |

The M2 gate is the project's real test. A graph database that loses data
on crash has failed at the only thing it was for.

### Phase B — the query (M4–M6)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M4 | Cypher read | lexer, parser, AST, semantic pass, planner (greedy), `ScanAll`/`ScanByLabel`/`Filter`/`Project`, `WHERE`, `RETURN`, `ORDER BY`/`SKIP`/`LIMIT` | **LANDED** — TCK subset 71/71 in-contract (gate ≥ 95 %); 96 977 single-hop queries/s (gate 50 000), 2-hop 0.066 ms at 10⁶ nodes (gate < 3 ms) |
| M5 | Cypher write | `CREATE`/`MERGE`/`SET`/`DELETE`/`REMOVE`, `UNWIND`, `WITH`, `Aggregate`, `Sort` with spill, `OPTIONAL MATCH`, variable-length `*1..3`, `LeftOuterExpand` | writes are transactional and WAL-logged; `LIMIT 10` on a 10⁶-row traversal returns in < 2 ms (pull model proof); sort of 10⁷ rows spills and completes |
| M6 | Indexes | range (block array + B-tree overlay), text (inverted + BM25), vector (HNSW, filtered traversal, explicit build) | recall@10 ≥ 0.95 vs brute force at `ef=128`; filtered vector query with 5% selectivity stays < 50 ms at 10⁶ docs; `idx.build` 10x faster than incremental |

### Phase C — the door (M7–M9)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M7 | Ruby complete | `Database`, `Statement`, batched `each_slice`, `Cell` hierarchy, all 11 statuses mapped, transaction blocks, indexes API | 100 % of status codes reachable from Ruby with a specific exception class; no segfault under a 10-min GC-stress fuzz over live `Cell`s |
| M8 | Model layer | `Glyph::Base`, relations (`has_many`/`belongs_to`/`has_one`/`through`), scopes, validation door, callbacks, `find_or_create_by`, `pluck` | Rails-shaped suite passes: 60 unit tests + 12 integration; the model layer adds ≤ 1 FFI crossing per call beyond the query |
| M9 | Import/export | CSV, JSONL, Parquet in Ruby; `import`/`export` DSL; Rails generators | 10⁶ rows CSV → graph in < 60 s; `export` to Parquet matches a Ruby-side reference within 0.1 % |

### Phase D — hardening (M10–M11)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M10 | Corruption & recovery | snapshot CRC verification, WAL replay idempotence, `integrity_check` reporting, `db.vacuum` (id + list compaction) | 1000 fuzzed truncations/bit-flips: every outcome is clean open or a named error, never a crash or silent corruption |
| M11 | Benchmarks & docs | published benchmark suite vs SQLite-edge-tables, `README`, `ARCHITECTURE`, `TESTING`, honest `limitations.md` | 20-node 5-day soak, zero leaks (`--mm:orc` finalizers instrumented); every benchmark reproducible from `make bench`; `limitations.md` published before the release, not after |

---

## 9. Phase 2 — the un-budgeted list

Recorded so the decision is deliberate later, not accidental now. None
of this is promised and none of it is scoped.

| Candidate | Cost | Why it might |
|---|---|---|
| `glyphes-server` + Bolt 4.x | ~3k lines | other clients; wraps this lib, does not change it |
| MVCC epochs | ~1.5k | a second *process* writing the same file |
| CSR adjacency | ~800 + migration | read-heavy workloads where import is done |
| Cypher shell (`glyphes` REPL) | ~300 | debugging; Ruby already has `db.query` |
| Property index auto-creation | ~400 | label property discovery from data |

Bolt is the only one that changes the product's shape, and it changes the
delivery model from "a gem" to "a server you deploy". That is a different
project wearing this one's name. **Recommendation: ship Phase D, then
decide.**

---

## 10. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Adjacency threading loses to CSR on traversal | 2–3x read latency | M1 gate measures it; CSR is the documented phase-2 swap with a snapshot migration |
| cgen/FFI layout drift | silent memory corruption | `ABI.md` B1: opaque handles, no struct by value. Never negotiable |
| Ruby `Cell` outliving its `Statement` | segfault in host process | `ABI.md` B3: statement owns arena memory; `Statement#each` holds the native ref, so staleness is a Ruby exception |
| No optimizer → bad plans | slow queries, user blame | bounded by data size at this scale; cost model is the phase-2 answer, and it is additive |
| WAL growth with a long-lived read transaction | unbounded disk | read transactions get a snapshot generation; checkpoint refuses below the oldest live generation and reports it |
| Cypher subset too small to be useful | adoption fails | §5.1 is the 70% set; every rejection names the construct so the next addition is evidence-driven |
| Scope creep back toward Memgraph | the original failure mode | §7 non-goals and §9 are pinned; adding to either requires amending this document, in writing, with a gate attached |

---

## 11. Pins

| # | Pin |
|---|---|
| P1 | One file, one process, embedded. No server in 0.x |
| P2 | `nim >= 2.2`, ORC, no third-party Nim dependencies. `ffi` gem on the Ruby side |
| P3 | Cypher-only mutation. No node/edge object API |
| P4 | Named parameters only, one JSON object per call |
| P5 | Batched cursors in the ABI and the Ruby API both |
| P6 | Pull-based volcano operators. Materialization is forbidden except in `Sort` |
| P7 | Greedy planner. No cost model, no join reordering |
| P8 | Atomic, fsynced commit from M2 onward. Never a phase-2 feature |
| P9 | The engine knows exactly one byte format: its own snapshot |
| P10 | Label index + range + text + vector, all queryable in one statement |
| P11 | Cypher surface is the §5.1 subset; anything else is `GLY_ERR_UNSUPPORTED`, never a wrong answer |
| P12 | Every phase ships tests and updated docs; §7 and §9 are amended in writing, never by drift |

---

## 12. Related documents

- [`ABI.md`](ABI.md) — the C boundary, handle lifetime, module map
- [`M0-NOTES.md`](M0-NOTES.md) — what building the seam actually required
- [`../DEVLOG.md`](../DEVLOG.md) — chronological: what landed, what broke
- [`../ENHANCEMENTS.md`](../ENHANCEMENTS.md) — ranked next steps, with costs
- `ARCHITECTURE.md` — *(M1)* storage internals and the pull pipeline
- `TESTING.md` — *(M1)* gates, fuzzers, differential testing
- `limitations.md` — *(M11)* published before release
- `../nimblyru/docs/JZYR-AR.md` — the model-layer conventions borrowed
- `../nimaps/docs/PRD-NIMAPS.md` — the sibling PRD whose posture this follows
