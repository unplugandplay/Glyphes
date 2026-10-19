# glyphes — the SQLite of graphs

> *One file. One process. ActiveRecord-shaped. Vector and text search in
> the same statement as the filter and the order.*

An embeddable graph database for Ruby: a labeled property graph in one
file, in your process, driven like ActiveRecord drives SQLite. No
server, no socket, no daemon, no JVM.

```ruby
require "glyphes"

Glyphes::Database.open("memory.glyph", create: true) do |db|
  db.index_create(kind: :vector, label: "Doc", property: "embedding", dim: 768)

  db.transaction do
    db.exec(<<~CYPHER, {t: "Hybrid Retrieval", e: [0.11, 0.42, /* … */]})
      CREATE (a:Doc {title: $t, year: 2026, embedding: $e})
      CREATE (a)-[:CITES]->(:Doc {title: "Graph Databases", year: 2018})
    CYPHER
  end

  # Vector recall, filter, order — one statement, one process.
  db.query(<<~CYPHER, {q: [0.10, 0.44, /* … */]}).each do |title, score|
    CALL db.idx.vector("Doc.embedding") AGAINST $q YIELD doc, score
    WHERE doc.year >= 2020
    RETURN doc.title, score
    ORDER BY score DESC
  CYPHER
  end
end
```

A `MATCH` after a retrieval is refused by name in 0.1 — that composition
is a join the operator set does not have (`docs/CYPHER.md` §6.3). Compose
retrieval and traversal in the model layer instead, or in two statements;
a refusal that names its construct is a to-do list, a query that silently
returns the wrong rows is a bug.

```ruby
Glyphes::Database.open("social.glyph", create: true) do |db|
  db.transaction do
    db.exec("CREATE (a:Person {name: $n, city: $c})-[:KNOWS {since: 2024}]->(b:Person)",
            { "n" => "Ana", "c" => "Lisbon" })
  end                                        # 3 entities written

  db.query("MATCH (p:Person)-[:KNOWS]->(f:Person)
            WHERE p.city = $city
            RETURN p.name AS name, f.name AS friend
            ORDER BY name SKIP 10 LIMIT 20",
            { "city" => "Lisbon" }).each { |name, friend| puts "#{name} → #{friend}" }
end
```

The store below it holds a graph — 10⁶ nodes and 4·10⁶ edges in ~1.6 s,
traversable in ~0.2 s. Reads *and* writes are Cypher (`db.query`,
`db.exec`) — mutation is Cypher-only by design (ABI.md B6), so a
hand-written node API never appears: it would be a second divergent path
with its own constraint and WAL semantics.

On top of the seam sits the model layer (`Glyph::Base`), and on top of
that, import/export:

```ruby
class Person < Glyph::Base
  validates :name, presence: true
  has_many :knows, class_name: "Person", type: "KNOWS"
end
Person.store = db

Person.create!(name: "Ana", age: 34)
Person.where("age >= $min", "min" => 30).order(:name).limit(10).to_a
ana = Person.find_by(name: "Ana")
ana.knows.first(5)                    # LIMIT 5, not "everything, take five"

db.import "people.csv", into: :Person, types: {age: :integer}
db.export db.query("MATCH (p:Person) RETURN p.name AS name"), to: "people.parquet"
```

## Status

**M0–M11 landed**, then two more arcs on top: **durable version history**
(V0–V1) and a **cross-process follower** (F1–F3). The store holds a graph,
survives a crash, survives being read while it is written, answers a Cypher
query, mutates in transactions, searches text (BM25) and vectors (HNSW) in
the same statement as the traversal's filter, exposes a Rails-shaped model
layer, imports and exports CSV/JSONL/Parquet, and refuses a damaged file by
name instead of serving it.

On top of that, every commit is recorded: a durable `.vhist` sidecar gives
each transaction a revision (node liveness and properties), and a second
process — a **follower** — can observe that history live, reading the log up
to the watermark the writer publishes at each commit. The follower holds no
nodes, issues no Cypher, takes no write lock; it watches commits and answers
`what changed`, not `what is the graph now`. A writer that is SIGKILLed
mid-commit leaves the follower off by exactly the in-flight commit, showing
nothing the database did not acknowledge.

| Milestone | State | Gate |
|---|---|---|
| M0 ABI spine | **landed** | Ruby loads the library; every `GlyStatus` maps to a Ruby exception |
| M1 store | **landed** | `nimble bench`: 10⁶ nodes + 4·10⁶ edges ≈ 1.6 s, traversal ≈ 0.2 s, heap 619 MB |
| M2 durability | **landed** | W1 — `kill -9` over an import, recovery byte-identical to a same-seed oracle |
| M3 transactions | **landed** | single writer, serializable readers, `BUSY` on contention; T1 soak green |
| M4 Cypher read | **landed** | C1 TCK subset 132/132 in-contract, 17 refusals by name; C9 query-rate gate |
| M5 write Cypher | **landed** | `CREATE`/`SET`/`REMOVE`/`DELETE`/`MERGE`, aggregates, `WITH`, `OPTIONAL MATCH`, variable length, spill-sorted `ORDER BY` |
| M6 indexes | **landed** | I5 range seek; I6/I7 text BM25 + phrase; I-vec HNSW recall 0.960@ef128; I9 constraints |
| M7 Ruby surface | **landed** | R1 (12 statuses → classes), R2 GC-stress with live cells; cells, node/edge views, checkpoint/backup/vacuum |
| M8 model layer | **landed** | Rails-shaped suite; R5 ≤1 crossing per verb *measured*; R9 validation door; R10 lazy associations |
| M9 import/export | **landed** | R8: 10⁶-row CSV < 60 s (**~26 s**); Parquet within 0.1 % of a format-derived reference (**0.002 %**); R11 no silent drops |
| M10 corruption & recovery | **landed** | W3: 10⁶ bit-flips → **999 883 named errors, 0 silent**; W2 truncate sweep green |
| M11 benchmarks & docs | **landed** | SQLite/Neo4j comparison published; `limitations.md`; 5-day soak harness |
| V0–V1 version history | **landed** | every transaction records a node revision; `.vhist` sidecar is durable and crash-safe; `diff` is O(changed) |
| F0 cross-process lock | **landed** | two writers over one file refused; `soakShared` two-process soak green |
| F1–F3 the follower | **landed** | SG5 the barrier never lies; SG6 the rebuilt timeline == the writer's; SG7 a crashed writer leaves the follower off by exactly one |
| S1–S4 the surface | **landed** | C ABI, Ruby `Glyphes::Follower`, `glyphes follow` CLI; the crash guarantee holds across the ABI; no write symbol exists anywhere in the surface |

The follower is reachable from **C, Ruby, and the CLI**. Its surface —
attach, poll, `head`/`generation`/`lsn`, and the reason when the watermark
is absent — is deliberately write-free: there is no `glyphes_follower_commit`
to forget to guard, because there is no such function. The structured
timeline reads (`followState`/`followDiff`/`commitsUpTo` across the ABI) are
the planned next increment, not yet built.

### Verification state

Verified **after** the M10 changes, on the full gate (`nimble gate`):

- **474 Nim tests, 0 failures** — store, WAL, recovery, transactions,
  Cypher, all three index families, the model layer's statement compiler,
  version history, and the follower's watermark/timeline gates.
- **228 Ruby tests / 769 assertions, 0 failures** — the seam, the model
  layer, import/export, status mapping.
- `nimble tck` — the committed TCK subset: **132/132 in-contract rows
  pass, all 17 out-of-contract rows refuse by name.**
- `nimble crash` — W1: SIGKILL over a 100-transaction import; every
  recovery matches a same-seed clean run, property values included.
- `nimble bitflip` — W3 (10⁶ bit-flips) and W2 (truncate at every 4 KB
  boundary): every outcome a clean open or a named error, never a crash
  or silent corruption.
- `nimble soak` — T1: 6 readers + 2 writers, no torn read.
- `nimble benchSort` / `benchIndex` / `benchVector` / `benchImport` — E2/E3,
  I5, I-vec (recall + determinism), R8 gates green.
- `nimble asan` — both suites under AddressSanitizer.

Two of the timing gates (M1 traversal, C9 query rate) are absolute
budgets with no load-aware suspension, and on a contended box they fail
by *multiples*, not percentages: measured the same morning, C9 read
96 977 queries/s quiet and 22 000–27 000/s with the machine's load average
at 13–28 — and the *pre-review* commit measured no better on that same
load, which is how the two were told apart. I5 gates on a ratio under
load for exactly this reason, and the other budgets are either
deterministic (recall, GC drift) or ratio-shaped. Treat a timing red as a
question about the machine first: re-run it quiet.

### What a decade of milestones taught

The defects worth reading about were all found by *writing the test
first* or by *sweeping*, never by reading:

- M1's arena blob had no length prefix: every overflow value read back
  empty. Found by reading bytes back, not by the 91 passing tests.
- M10's bit-flip sweep found that a CRC mismatch was treated as a torn
  tail (the file was truncated and opened *successfully*, data silently
  missing), that `txnFlags` — the COMMIT bit — sat outside the frame
  CRC, and that a truncated snapshot raised `AssertionDefect`, which is
  not a `CatchableError` and took the host process down. The WAL.md gate
  table had recorded W3 as "the sweep is not implemented" for months;
  running it is what found them.

The full chronology, with the numbers, is [`DEVLOG.md`](DEVLOG.md).

### What is not done

- **The 5-day soak has not been run.** The harness is built, wired to
  `make soak`, and green over a 100-second 20-node run; the five-day gate
  itself is still to be run, and `docs/TESTING.md` says so rather than
  implying otherwise.
- **Bulk loading through the query language costs ~3 800 edges/second.**
  Three defects made it 20x worse than that; all are fixed and the numbers
  are in [`limitations.md`](limitations.md) §2.
- **The follower's external surface reports counters, not content.** The
  C ABI, Ruby binding, and CLI expose attach/poll/`head`/`generation`/`lsn`
  — how far a follower has seen — but not yet `followState`/`followDiff`/
  `commitsUpTo`. Auditing *what* changed still happens from Nim. That
  structured-reads increment is planned in
  [`docs/FOLLOWER-SURFACE-PLAN.md`](docs/FOLLOWER-SURFACE-PLAN.md).
- **Follower history is node-only.** Edges, labels, and indexes are not in
  the log, so a follower cannot audit a relationship change. That is a
  format change (`vhist.nim`), not a surface one, and is out of scope for
  the surface plan.
- **R12** (8-process worker simulation) and **W7** (fsynced/NORMAL
  commit throughput) are named in the gate tables with no harness yet.
- Fusing a traversal into a retrieval statement (the `MATCH` after a
  `CALL`) is refused by name; the pushdown — `WHERE` on the yielded
  variable — is the supported composition.
- Parquet read/write covers PLAIN encoding, uncompressed, one row group,
  flat columns; anything else is refused by name, not misread
  (`docs/RUBY.md` §6.3).

```
nimble build        the shared library (release, ORC, threaded)
nimble test         474 Nim tests (fast)
nimble testGate     474 Nim tests at full churn
nimble fixture      rebuild tests/fixtures/social.glyph
nimble gemtest      228 Ruby runs / 769 assertions
nimble crash        W1 crash gate
nimble crashFollower  SG7: a writer SIGKILLed mid-commit leaves the follower off by exactly one
nimble bitflip      W3 bit-flip sweep + W2 truncate sweep (GLYPHES_BITFLIPS=N)
nimble soak         T1 concurrency gate
nimble soakShared   F0 two-process writer soak (nightly at 240 s+)
nimble bench        M1 store benchmark
nimble benchQuery   C9 query rate / 2-hop latency
nimble benchSort    E2/E3 sort gates
nimble benchVersion G2: diff is O(nodes changed), not O(graph)
nimble benchIndex   I5 range-index gate
nimble benchVector  I-vec recall + determinism
nimble benchImport  R8 import/export gate
nimble ss2          SS2: no exported follower symbol can write
nimble tck          C1: the TCK subset
nimble gate         everything short, in order, stops at the first red
nimble asan         both suites under AddressSanitizer
```

Sample gate output (quiet machine):

```
$ nimble bench
  PASS  create       1640 <= 8000        10^6 nodes + 4·10^6 edges
  PASS  traversal    224 <= 400          4·10^6 hops
  PASS  heap (MB)    619 <= 680
M1 gate: green

$ nimble benchImport
  CSV import  1000000 rows in ~26s   (~40 000 rows/s)
  R8 CSV: GREEN  (26s < 60s budget)
  R8 Parquet: GREEN  (0.0020% drift <= 0.1%)
```

Timings are ranges in practice: a concurrent compile on the same box
moved the traversal figure from 195 ms to 812 ms during the milestone
it was gated in. The gate is the budget, not a reading.

| Milestone | Scope | State |
|---|---|---|
| M0 | ABI spine, Ruby loads it | **landed** |
| M1 | Store: dense ids, adjacency, dictionaries, property arena | **landed** |
| M2 | Durability: WAL, snapshot, recovery | **landed** |
| M3 | Transactions: single writer, serializable, `BUSY` | **landed** |
| M4–M6 | Cypher read/write, pull pipeline, range/text/vector indexes | **landed** |
| M7–M9 | Ruby surface, model layer, import/export | **landed** |
| M10 | Corruption & recovery: CRC verification, bit-flip/truncate sweeps | **landed** |
| M11 | Benchmark suite vs SQLite, docs, published `limitations.md`, soak harness | **landed** |
| V0–V1 | Version history: revision per transaction, durable `.vhist`, O(changed) `diff` | **landed** |
| F0–F3 | Shared mode: cross-process lock, watermark, the follower and its gates | **landed** |
| S1–S4 | The follower's surface: C ABI, Ruby binding, CLI | **landed** |

**[`limitations.md`](limitations.md)** is the honest list: what glyphes is
bad at, with measurements, published *before* the release rather than after.

Design documents: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the map,
[`docs/ROADMAP.md`](docs/ROADMAP.md) has the gates, and
[`ENHANCEMENTS.md`](ENHANCEMENTS.md) is what is deliberately not next.

## Why

Working with graphs today means one of three bad trades:

1. **Neo4j / Memgraph.** Correct and Cypher-complete, and a
   multi-hundred-megabyte resident process plus a socket for a graph that
   might be 20 MB.
2. **SQLite with edge tables.** Free and embedded, but every traversal is
   a hand-written `JOIN`, and text and vector search are bolted onto
   other tables.
3. **An embedded graph library.** In-memory, or durable only on clean
   shutdown — you lose the file on crash, which is the one property
   SQLite guaranteed you before anything else.

glyphes takes option 3 and adds back crash-safe commit with `fsync`, then
puts vector and text search in the same query surface as the traversal.

## Design, in six decisions

**Nim, ORC, no dependencies.** Deterministic destruction, no GC pauses in
the host process, `cgen` for the C header. Stack: `nim >= 2.2`, the `ffi`
gem, nothing else.

**SQLite's rowid, specialized.** Dense `i64` ids, array-indexed records,
`48 B` nodes and `56 B` edges. Lookups are array subscripts. Adjacency is
threaded through `next_out`/`next_in`, not array-of-arrays, so a node
costs 48 bytes and a delete is O(1) at any degree.

**Serializability without epochs.** One writer, lock-free readers, a
`generation` counter, copy-on-write merge. Memgraph's epoch MVCC serves
a concurrent server; glyphes is embedded, so it takes SQLite's model
instead.

**Pull-based volcano operators.** One operator per clause, each pulling
from its child. Materialization is forbidden except in `Sort`. This is
why `LIMIT 10` over a 10⁶-row traversal returns in under 2 ms, and it is
the decision that keeps the executor at ~3 000 lines.

**Greedy planner, no cost model.** Four rules pick a scan operator;
direction prefers the lower-degree side. A cost-based optimizer would be
better; it would also be the thing that makes this project take four
years.

**The engine knows one byte format: its own snapshot.** No CSV, no JSON,
no Parquet, no Bolt in Nim. Those are Ruby problems (`RUBY.md` §6), which
is why the Nim dependency list is empty.

## Not doing

No server, no socket, no Bolt. No replication, no Raft, no failover. No
multi-tenancy, no auth. No Cypher shell. No streaming/CDC, no Kafka. No
Parquet in the engine. No MAGE, no algorithms, no CUDA. No UDFs, no
procedures, no subqueries. No `UNION`, no `LOAD CSV`. No nested
transactions, no savepoints. No query parallelism (the GIL).

Every one of those is in Memgraph, and every one of them is why Memgraph
is 400 000 lines and a Docker image. The full list with reasons is
[`docs/PRD-GLYPHES.md`](docs/PRD-GLYPHES.md) §7; the deliberate phase-2
candidates are §9; the recurring requests to decline are
[`ENHANCEMENTS.md`](ENHANCEMENTS.md).

Full openCypher conformance is also not on the table. The accepted
surface is a documented subset ([`docs/CYPHER.md`](docs/CYPHER.md));
anything outside it returns `GLY_ERR_UNSUPPORTED` naming the construct,
never a wrong answer.

## Documentation

| Document | Contents |
|---|---|
| [`docs/PRD-GLYPHES.md`](docs/PRD-GLYPHES.md) | what this is, phases, gates, risks, pins |
| [`docs/STORAGE.md`](docs/STORAGE.md) | record layouts, property arena, dictionaries, adjacency, invariants |
| [`docs/WAL.md`](docs/WAL.md) | WAL framing, snapshot format, recovery, durability gates W1–W7 |
| [`docs/TXN.md`](docs/TXN.md) | transactions, isolation, copy-on-write merge, concurrency |
| [`docs/CYPHER.md`](docs/CYPHER.md) | the language contract, semantics, rejections |
| [`docs/EXEC.md`](docs/EXEC.md) | pull pipeline, operators, planner rules, memory contract |
| [`docs/INDEX.md`](docs/INDEX.md) | range, text, vector; filtered HNSW; recall contract |
| [`docs/RUBY.md`](docs/RUBY.md) | gem surface, model layer, import/export, gates R1–R12 |
| [`docs/ABI.md`](docs/ABI.md) | the C boundary, handle lifetime, module map |
| [`docs/TESTING.md`](docs/TESTING.md) | oracles, gates, fuzzers, reproducibility |
| [`docs/M0-NOTES.md`](docs/M0-NOTES.md) | what the Nim→FFI seam actually does, learned the hard way |
| [`docs/PRD-VERSIONING.md`](docs/PRD-VERSIONING.md) | version history: what a revision is, the `.vhist` format, costs |
| [`docs/PRD-SHARED.md`](docs/PRD-SHARED.md) | shared mode: one writer, followers, the watermark, limits |
| [`DEVLOG.md`](DEVLOG.md) | chronological: what landed, what broke, what it taught |
| [`ENHANCEMENTS.md`](ENHANCEMENTS.md) | ranked next steps, with costs and deadlines |

Specs are normative: where code and a spec disagree, the spec leads and
the spec gets amended first. Every spec carries an "Open questions"
section listing what is still undecided.

## Status honesty

M0–M11, version history, and the follower are landed and gated; that is
the claim, and the gate output above is the evidence. What follows is what
is *not* claimed:

- **R12 and W7 have no harness.** The gate tables name them; nothing
  runs them. They are the two honest gaps in the gate inventory.
- **R6's letter is unmet.** The model suite is 58 tests where the gate
  says "60 unit + 12 integration" — close in spirit, short of the letter,
  recorded as such in `docs/ROADMAP.md`.
- **Two timing gates are absolute budgets** (M1 traversal, C9 query
  rate). On a loaded machine they miss by a few percent; the fix is a
  quiet machine or the load-aware suspension I5 already has, not code.
- **Parquet is a deliberately narrow writer/reader** (PLAIN,
  uncompressed, one row group, flat columns). Files outside that subset
  are refused by name.
- **The model layer is a convenience, not a second query language.**
  Every verb is reachable in raw Cypher (R7), and `db.query` is never
  deprecated.

The specifications were detailed, and **six of their numbers were wrong
before the code ran**, plus several more that only a benchmark or a
sweep could find. `STORAGE.md` §0 amends the PRD's `EdgeRec` size (56,
not 48); §7 records that `PropSlot` is 16 bytes and not 24, and that the
memory gate had been set *below its own computed cost* twice. `WAL.md`'s
gate table recorded W3 as "the sweep is not implemented" for months —
and running the sweep (M10) is what found the CRC/torn-tail confusion.

Two general lessons, both now pinned. **Tabulate the fields and let the
compiler agree or disagree** — three of the six wrong numbers were field
lists with a size written beside them and never added up. And **put the
number in a fixture or a sweep** — 320 MB of padding was invisible to 91
passing tests, and the CRC holes were invisible to every unit test,
because none of them flipped a bit the checks were not watching.

## License

MIT (see [`LICENSE`](LICENSE)). A clean-room implementation from
documented specifications — openCypher, and SQLite's published design.
No Memgraph source is copied, and none is needed.
