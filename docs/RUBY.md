# glyphes — RUBY: the gem's contract

> **Status:** normative. The **query** half of §3 landed at M4
> (`db.query`, `db.prepare`, `Statement`, `Cell`, `Result`, `each_slice`);
> `db.exec` and everything below §3 — the model layer, import/export,
> `checkpoint`, `vacuum`, indexes — is M5 onward and is specified here but
> not implemented. Companion: `ABI.md` (the C boundary this wraps).
> Conventions borrowed from `../nimblyru/docs/JZYR-AR.md` §3–§6.

**M5.1 added `db.exec`**, which returns the number of entities written:

```ruby
db.exec("CREATE (a:Person {name: $n})-[:KNOWS {since: 2024}]->(b:Person)",
        { "n" => "Ana" })                 # => 3  (two nodes, one relationship)

db.transaction do                        # an exec inside the block joins it,
  db.exec("CREATE (:Tag {name: 'ruby'})") # so this rollback undoes it too
  db.exec("CREATE (:Tag {name: 'rails'})")
end                                       # one commit, one generation step
```

A read query through `db.exec` is legal and writes nothing (rows affected
0) — it is the same engine, and refusing it would make "run this and tell
me what it changed" impossible to express.

**What M4's Ruby surface looks like in practice:**

```ruby
db.query("MATCH (p:Person) WHERE p.city = $c RETURN p.name AS name ORDER BY name",
         { "c" => "Lisbon" })
# => #<Glyphes::Result ["name"] 6 rows>

st = db.prepare("MATCH (p:Person) RETURN p.name AS name")
st.each_slice(256) { |batch| batch.each { |row| … } }   # one FFI crossing per batch
st.close
```

`Result` is `Enumerable` over rows of plain Ruby values — `Integer`,
`Float`, `String`, `nil`, `true/false`, `Array`, `Hash`, and a node or edge
as its `Integer` id. `Cell` (the view over statement memory) is internal:
`each_slice` converts while the statement is still live, so no Ruby object
holds a pointer into the engine's arena after the batch (`ABI.md` B3).

This specifies the Ruby public surface: `Database`, `Statement`, `Cell`,
the error hierarchy, the model layer, and import/export. It is the door
the project is judged on, and it is where a thin boundary is easiest to
lose.

---

## 0. The one rule

> The Ruby layer **translates** and **marshals**. It never caches, never
> holds state between calls, and never materializes a collection behind
> the caller's back.

Every method that touches the graph issues exactly one engine call and
returns what the engine returned. The moment a Ruby-side cache appears,
`db.query` and the model layer can disagree, and the bug will be reported
as "the database is inconsistent" rather than as a caching bug. The
`neo4j-rails` shape — where the model DSL is rich enough to hide the
graph — is the specific failure mode this rule exists to prevent.

Corollary: `db.query` is always available, is never deprecated, and is the
escape hatch when the model layer feels insufficient.

---

## 1. Layout

```
lib/glyphes.rb              require graph, Glyphes::VERSION
lib/glyphes/version.rb
lib/glyphes/ffi.rb          ffi_lib bindings, struct layouts, constants
lib/glyphes/errors.rb       GlyStatus → exception classes
lib/glyphes/database.rb     Database, transaction blocks, checkpoint, indexes
lib/glyphes/statement.rb    Statement, Result, each_slice
lib/glyphes/cell.rb         Cell value objects
lib/glyphes/node.rb         Node, Edge, Path, Relationship views
lib/glyphes/active_record.rb Glyph::Base
lib/glyphes/relations.rb    has_many / belongs_to / has_one / through
lib/glyphes/validations.rb  the validation door
lib/glyphes/import.rb       CSV / JSONL / Parquet in
lib/glyphes/export.rb       query → CSV / JSONL / Parquet out
ext/glyphes.rb              RubyGems extension stub (not an FFI shim)
glyphes.gemspec
```

`ffi.rb` is the only file that knows FFI exists. Every other file calls
methods on `Database` and `Statement`, which makes the ABI change
impact one file.

---

## 2. Errors

Eleven `GlyStatus` error codes map to six exception classes, all under
`Glyphes::Error`.

```ruby
module Glyphes
  class Error           < StandardError; attr_reader :status, :detail end
  class SqlError        < Error; end   # GLY_ERR_SQL
  class UnsupportedError< Error; end   # GLY_ERR_UNSUPPORTED
  class ConstraintError < Error; end   # GLY_ERR_CONSTRAINT (+ offending value)
  class ClosedError     < Error; end   # GLY_ERR_CLOSED / GLY_ERR_STALE
  class BusyError       < Error; end   # GLY_ERR_BUSY
  class IoError         < Error; end   # GLY_ERR_IO
  class MemoryError     < Error; end   # GLY_ERR_NOMEM
  class LimitError      < Error; end   # GLY_ERR_LIMIT
  class ReadOnlyError   < Error; end   # GLY_ERR_READONLY
end
```

`ConstraintError` carries `detail` — the offending value and the
conflicting key (`TXN.md` §5) — because "constraint failed" in a 10⁶-row
import says nothing about which row to fix.

`UnsupportedError`'s message names the construct and cites this repo's
`docs/CYPHER.md` (`CYPHER.md` §0).

Every status code is reachable from Ruby with a specific class; gate R4.

**Never** rescue-and-return-nil internally. An error that becomes `nil`
becomes a `NoMethodError` three frames away, in application code.

**M7 — landed.** All eleven statuses reach a class (gate **R1**, in
`tests/e2e/test_m7.rb`). Six of them are *raised* there through real
queries — a parse error, a named refusal, a closed handle, a constraint
violation, a second writer, a read-only write — because a status→class
table is only worth what the engine actually returns, and a table that was
never exercised against the engine is a table of intentions.

One Ruby-layer bug this milestone found, which is the kind the ABI's
ownership rule exists to prevent: the two-phase cap protocol
(ask with a small buffer, the engine reports the size, ask again) treats
`GLY_MORE` as *success with a size*, not as a failure. Reading it as a
failure turned every "buffer too small" probe into an exception, and a
deleted node — the case where a status carries real information — into an
`ArgumentError` from the exception constructor instead of a `SqlError`.

---

## 3. `Database`

```ruby
db = Glyphes::Database.open("graph.glyph")
db = Glyphes::Database.open("graph.glyph", create: true, cache_mb: 256)
db = Glyphes::Database.open(":memory:")
db = Glyphes::Database.open("graph.glyph", readonly: true)
db = Glyphes::Database.open("graph.glyph", snapshot: true)   # mmap only

db.exec(cypher, params = nil)                 # autocommit → rows affected
db.prepare(cypher, params = nil) → Statement
db.query(cypher, params = nil) → Result       # prepare + block + close

db.transaction { ... }                        # begin / commit / rollback
db.checkpoint(truncate: true, fsync: true)
db.integrity_check                            # → String report
db.vacuum
db.stats                                      # → Hash
db.schema(labels: true, properties: true, indexes: true) → Hash
db.backup("graph-2026-10-07.glyph")

db.link(from_id, type, to_id) → edge id       # two *existing* nodes
db.link_props(from_id, type, to_id, props) → edge id  # …and properties

db.index_create(kind: :vector, label: "Doc", property: "embedding",
                dim: 768, metric: :cosine, m: 16, ef_construction: 200)
db.index_drop("Doc.embedding")
db.index_build("Doc.embedding")
db.index_list                                 # → [Hash, …]

db.close
```

**M7 added the doors these have always needed.** `checkpoint(truncate:,
fsync:)`, `wal_size`, `backup(path)` (checkpoint-then-copy, so the
destination is a consistent pair — WAL.md §3), `vacuum` (rebuild every
index from live records, INDEX.md I14 — explicit because `close` must not
do it), `schema(labels:, properties:, indexes:)` and `stats`.

**The link doors.** `link` and `link_props` are the one write GLYPH QUERY
cannot express — two existing nodes, one relationship, no join and no
cartesian (ABI.md). `link_props` carries the edge's properties in the same
crossing; without it a bulk loader pays a MATCH/SET per edge, and the
measured difference is two orders of magnitude (`nimble benchLink`).

`checkpoint(truncate: true)` dropping every frame the new snapshot
already contains is the one with teeth: a checkpoint snapshots at the
log's tip, so the whole log is covered and the correct cut is to zero.
The first implementation asked the frame scanner where the last frame
ended and cut there — which is the end of the log, so the flag silently
did nothing and `wal_size` never fell.

**`Database.open` with a block closes automatically.** Without a block the
caller owns the handle. Both forms exist; the block form is preferred and
documented first.

`db.query` is the convenience — it prepares, yields a `Result`, closes.
It exists because most Ruby code writes `db.query(...)` and that should
not require two calls and a `begin/ensure`. `db.prepare` is for the cases
that need the handle: repeated execution, or a cursor that outlives the
block.

`readonly: true` fails on any write with `ReadOnlyError` rather than
silently degrading. `snapshot: true` opens the mmap'd snapshot read-only
with no WAL, for read replicas and analysis.

### 3.1 Transactions

```ruby
db.transaction do
  db.exec("CREATE (:A {id: 1})")
  raise "nope"    # rollback; nothing is written
end
```

Ruby block semantics: the block returning normally commits, raising
rolls back. Nested `transaction` calls join the outer one and their block
return value is ignored — savepoints are not in 0.1 (`TXN.md` pin X14),
and joining rather than erroring is the Rails-shaped choice.

`transaction` raises `BusyError` immediately on a second concurrent
transaction, per `TXN.md` §1.

### 3.2 Threading

Per `TXN.md` §7: distinct `Database` handles are independent; a single
handle is safe for concurrent `exec`/`transaction` (the writer lock
decides) but **a single `Statement` is not thread-safe**.

The GIL means Ruby threads do not run engine code in parallel, so glyphes
gives no query parallelism in 0.1. A Rails app runs one database handle
per Puma worker — 8 processes, 8 independent engines, 8 writers to
different files. That is the documented deployment, and it is the only
one the PRD supports.

Documented explicitly in the README, because "why is my threaded import
not faster" is otherwise a support question.

---

## 4. `Statement` and `Result`

```ruby
st = db.prepare("MATCH (p:Person) WHERE p.city = $c RETURN p", {"c" => "Lyon"})
st.columns                                       # ["p"]
st.each_slice(256) { |batch| ... }               # one FFI crossing / 256
st.each { |row| ... }                             # sugar, batch = 256
st.first                                          # → Row or nil
st.to_a                                           # materialize (capped)
st.count                                          # drain, no materialization
st.reset                                          # re-execute
st.close
```

**`each_slice` is the primitive; `each` is sugar.** There is no per-row
FFI path in the public API (`ABI.md` B2). Per-row FFI is ~1µs per
crossing, so 10⁵ rows is 100ms of pure transition cost — a 30x penalty
on a real traversal. Importing 10⁶ rows through a hypothetical per-row
API would take minutes instead of seconds.

`st.to_a` materializes and is capped by `max_result_rows`; it raises
`LimitError` rather than silently allocating gigabytes.

`st.count` drains the cursor counting rows without materializing — the
right way to answer "how many", and the difference between O(1) memory
and O(n).

### 4.1 Rows and cells

A `Row` is a lazy view. `row.name` reads arena memory owned by the
statement. Values:

| Engine type | Ruby class | Notes |
|---|---|---|
| `GLY_NULL` | `nil` | |
| `GLY_BOOL` | `true` / `false` | |
| `GLY_INT` | `Integer` | i64 |
| `GLY_FLOAT` | `Float` | |
| `GLY_STRING` | `String` | materialized once, memoized |
| `GLY_BYTES` | `String` | `ASCII-8BIT` (binary) |
| `GLY_VECTOR` | `Glyphes::Vector` | `f32` array, lazily read |
| `GLY_NODE` | `Glyphes::Node` | id + label + properties view |
| `GLY_EDGE` | `Glyphes::Edge` | id + type + endpoints |
| `GLY_PATH` | `Glyphes::Path` | nodes/edges/directions |
| `GLY_LIST` | `Array` | lazily, element by element |
| `GLY_MAP` | `Hash` | string keys |

Integers and floats come out of `GlyCell#aux` with no engine round-trip
(`ABI.md` Rule 3) — the cheapest path in the whole API.

**Lifetime, the one hard rule in this document.** A `Cell`, `Row`,
`Node`, `Edge`, or `Path` borrows memory owned by its `Statement`. Using
one after `close`, or after the statement has moved to a new batch, raises
`ClosedError`. `each_slice` holds the native reference for the duration of
its block, so this is a Ruby exception rather than a segfault
(`ABI.md` B3).

`Node`, `Edge`, and `Path` are **views, not copies**. `node.properties` is
resolved lazily against the statement's generation, so a `Node` handed to
another method re-reads current state. They hold ids, not data — which is
what makes `Node` cheap to pass around.

### 4.2 Reading a node without Cypher — *landed (M7)*

```ruby
n = Glyphes::Node.new(db, id)
n.labels       # → ["Person"]
n.properties   # → {"name" => "Ana"}
n["name"]      # → "Ana"
```

A `Node` is a view: it holds a handle and an id, never a property map, so
a node handed around re-reads current state (a node renamed after the
query still reports its new name). A node that does not exist raises
`SqlError` — "this node has no labels" and "this node is gone" must not
look the same. A `GLY_NODE` *cell* materializes as a `Node` for the same
reason: a bare integer makes `row.n.properties` a `NoMethodError` three
frames from the query that caused it. `Edge` is a view too — id, type,
endpoints — so `row.r.type` is one engine call, not a Cypher round-trip.

Three small conveniences for graph-shaped work where a Cypher round-trip
would be silly. Each is one engine call. `db.query` remains available for
everything else.

---

## 5. The model layer — `Glyph::Base`

Rails-shaped, borrowed from `../nimblyru/docs/JZYR-AR.md`, over the
graph.

```ruby
class Person < Glyph::Base
  has_many :knows, class_name: "Person", via: :knows
  has_many :likes, class_name: "Like"
  has_one  :profile

  validates :name, presence: true
  validates :age, numericality: { greater_than: 0 }

  before_save do |person|
    person.name = person.name.strip
  end

  scope :adults, -> { where("age >= $min", {min: 18}) }
end
```

### 5.1 Verbs

**Class:** `create`, `new` (+ `save`), `create!`, `find`, `find_by`,
`first`, `last`, `all`, `where`, `order`, `limit`, `offset`, `pluck`,
`count`, `exists?`, `find_or_create_by`, `first_or_create`, `update_all`,
`delete_all`, `destroy_all`, `upsert`.

**Instance:** `save`, `save!`, `update`, `update!`, `reload`, `destroy`,
`valid?`, `errors`, `persisted?`, `changed?`, `touch`, `freeze`.

Names and semantics follow Rails exactly. `where` accepts a hash
(`where(city: "Lyon")`), a string with `$params`, or both.

### 5.2 Translation

Every class verb compiles to one Cypher statement, cached by
`(method, where keys, order, limit)` in a **per-class** `Hash` cleared on
schema change and bounded at 512 entries. The key is the *shape* — the
where keys, not their values: `where(age: 1)` and `where(age: 2)` are the
same statement with different params, and keying by values would give an
app filtering on a moving value no reuse at all. This is the only cache in the Ruby layer and it is
exempt from §0, because a compiled-statement cache is deterministic —
the same inputs always produce the same query. It is pinned in §8.

```ruby
Person.where(city: "Lyon").order(:age).limit(10)
# → MATCH (p:Person) WHERE p.city = $city
#   RETURN p ORDER BY p.age LIMIT 10
#   {"city" => "Lyon"}

person.update(city: "Nice")     # → MATCH (p:Person) WHERE id(p) = $id SET p.city = $city
person.destroy                  # → MATCH (p:Person) WHERE id(p) = $id DETACH DELETE p
```

### 5.3 Relations

| Macro | Cypher |
|---|---|
| `has_many :knows, class_name: "Person", via: :knows` | `MATCH (a)-[:KNOWS]->(b:Person) RETURN b` |
| `belongs_to :author, class_name: "Person"` | `MATCH (a)-[:AUTHORED_BY]->(b:Person) RETURN b` |
| `has_one :profile` | `MATCH (a)-[:HAS_PROFILE]->(b:Profile) RETURN b LIMIT 1` |
| `has_many :x, through: :y` | two-hop `MATCH`, joined in Cypher |

`through:` composes in Cypher, not in Ruby — no intermediate Ruby
collection, no N+1 beyond what the query itself implies.

Association collections are lazy `Relation` objects (re-queryable,
chainable), **not** materialized Arrays. `person.knows.first(5)` issues
`LIMIT 5`; `person.knows.to_a` materializes. This is the Rails
collection-proxy behaviour and it is also what keeps the §0 rule intact.

### 5.4 Validations

The validation door from `JZYR-AR.md` §8, applied **before** the write is
issued:

```ruby
person = Person.new(name: nil, age: -1)
person.valid?              # → false
person.errors              # → {name: ["can't be blank"], age: ["must be > 0"]}
person.save                # → false, nothing written
person.save!               # → Glyphes::ValidationError
```

`validates` supports `presence`, `uniqueness` (delegated to a real
uniqueness constraint, `TXN.md` §5 — not a Ruby-side check),
`inclusion`, `numericality`, `length`, `format`. `errors` is a `Hash` of
field → array of messages, Rails-shaped.

### 5.5 What the model layer does not do

Named because their absence is the design:

| Not supported | Why |
|---|---|
| polymorphic `belongs_to` | the label *is* the type |
| `joins` | you write `MATCH` |
| lazy-loading / N+1 guard | hides the query, which is the thing being debugged |
| returning full rows from a model query | `RETURN n` is the view (pin Y5); reading an attribute a query did not carry costs one crossing *for that record, when it is touched* — `pluck` is the door for a whole collection in one |
| attribute type casting | no schema-level typing (`CYPHER.md` C6) |
| dirty-tracking attribute queries | `changed?` is enough |
| association caching | §0 |
| `validate` on a relationship | `validates_associated` at 3 hops is a maze |
| a `touch` that skips validation | touch writes the whole row (no dirty tracking), so it goes through the validation door like every write; Rails' touch skips the door because it writes only timestamps it owns |
| attribute names that are not bare identifiers | every name is interpolated into statement text; a name that is not `[a-zA-Z_][a-zA-Z_0-9]*` is an injection and is refused by name (`ArgumentError`) at `[]=` and at every compile |

If you need one of these, `db.query` is the door and it is not
encouraged to be closed.

---

## 6. Import and export

Engine never sees a file format (`PRD.md` P9).

```ruby
db.import "people.csv",  into: :Person, keys: [:name, :city, :age]
db.import "people.csv",  into: :Person, keys: [...], skip: 1,
                        types: {age: :integer}, batch: 5000
db.import "docs.jsonl",  into: :Doc,   vector: :embedding, dim: 768
db.import "nodes.parquet", into: :Doc, types: {year: :integer}

db.export db.query("MATCH (p:Person) RETURN p"), to: "people.csv"
db.export db.query("MATCH (d:Doc) RETURN d"), to: "docs.parquet"
```

### 6.1 Import

One `db.transaction` around the whole file, `exec` in batches of
`db.import`'s `batch:` parameter (default 5 000). `glyphes_exec` is the
autocommit fast path but is skipped here — a single explicit transaction
avoids a merge per statement (`TXN.md` §9).

When a `vector:` is given, the flow is create → import → `index_build`,
not create-with-index-live, because that is 10–40x faster
(`INDEX.md` §4.2).

`skip:` handles headers. `types:` coerces CSV strings, since CSV has no
types. Unknown columns are an error, not a silent drop — a typo in a
header is exactly the bug that silently loses data.

### 6.2 Export

A `Result` drained once into a writer. `to:` infers format from the
extension (`.csv`, `.jsonl`, `.parquet`). Nested `Node`/`Edge`/`Path`
values flatten to their property maps; `to: :parquet` requires flat maps
and raises otherwise, because Parquet has no nested type here.

Both directions are resumable-by-restart only (no offset tracking in
0.1), and both are documented as single-threaded.

### 6.3 What the Parquet support actually is

**PLAIN encoding, uncompressed, one row group, one data page per column**,
written and read by this gem in about 600 lines of Ruby (`parquet.rb`,
`parquet_encoding.rb`, `thrift_compact.rb`). It is not a general Parquet
implementation and does not pretend to be:

| In 0.1 | Refused, by name, not misread |
|---|---|
| flat columns: boolean, int32, int64, double, byte array | dictionary, delta and byte-stream-split encodings |
| one row group | several row groups (`UnsupportedError`) |
| uncompressed | snappy, gzip, zstd, brotli |
| nullable columns (RLE definition levels) | nested/repeated fields, maps, lists |

The reader's refusals are deliberate: a reader that silently mis-decodes a
file it does not fully understand is worse than one that names what it
cannot read. `cell_path` is refused for the same reason — the engine does
not expose paths yet.

This is a *scope* decision, not a limitation discovered later. The
alternative was a dependency: the `parquet` gem is a native extension with
its own load failure modes, and this gem's whole dependency list is `ffi`.
A format this engine never sees (`PRD.md` P9) does not justify pulling an
Arrow stack into a graph database's install.

**R8** is measured by `tests/bench/bench_import.rb`: a 10^6-row CSV import
under 60 s, and a Parquet export within 0.1% of a byte count recomputed
*from the format* — PLAIN widths and RLE level arithmetic — rather than
from a golden file this writer produced, which would only prove it
reproduces itself.

---

## 7. Gates

| # | Gate |
|---|---|
| R1 | 100 % of `GlyStatus` values reachable from Ruby with a specific exception class |
| R2 | Zero segfaults under a 10-minute GC-stress fuzz holding live `Cell`s across batch boundaries |
| R3 | `each_slice` is the primitive; no per-row FFI path exists in the public API |
| R4 | A `Cell` used after its `Statement#close` raises `ClosedError`, never reads freed memory |
| R5 | Model layer adds ≤ 1 FFI crossing per verb beyond its query |
| R6 | 60 unit + 12 integration tests on `Glyph::Base` (Rails-shaped suite) |
| R7 | `db.query` never deprecated; every model verb reachable in raw Cypher |
| R8 | 10⁶-row CSV import < 60 s; Parquet export within 0.1 % of a Ruby reference |
| R9 | `errors` matches Rails' shape; `save!` raises `ValidationError` with all messages |
| R10 | Association collections are lazy; `person.knows.first(5)` issues `LIMIT 5` |
| R11 | Unknown import column raises; no silent data drop |
| R12 | 8 Puma-worker simulation: 8 handles, 8 processes, no corruption |

R2 is the ABI's whole reason for existing. R5 and R7 are the §0
boundary's gates.

---

## 8. Pins

| # | Pin |
|---|---|
| Y1 | Ruby translates and marshals. No cache, no hidden state, no surprise materialization |
| Y2 | Exception per status code; never rescue-and-return-nil internally |
| Y3 | `each_slice(n)` is the primitive; `each` is sugar over batch 256 |
| Y4 | Cells borrow statement-owned memory; staleness raises `ClosedError` |
| Y5 | `Node`/`Edge`/`Path` are views over ids, resolved lazily |
| Y6 | Integer and float cells read from `GlyCell#aux` with no engine call |
| Y7 | `db.query` is permanent, never deprecated, always the escape hatch |
| Y8 | Model verbs compile to one Cypher statement each; only deterministic caches allowed |
| Y9 | Associations are lazy `Relation`s, not Arrays; `through:` composes in Cypher |
| Y10 | Validation runs before the write is issued; `uniqueness` delegates to a constraint |
| Y11 | No polymorphic `belongs_to`, no `joins`, no lazy loading, no type casting |
| Y12 | Import is one transaction with batched `exec`; vector imports build after load |
| Y13 | Unknown import columns raise; silent drops are forbidden |
| Y14 | No query parallelism in 0.1 (GIL); documented as one handle per process |

---

## 9. Open questions

- ~~**Statement cache growth.**~~ **Resolved (M8).** §5.2 caches by
  `(method, where_hash, order, limit)`. Bounded at
  `Glyph::Base::STATEMENT_CACHE_LIMIT = 512`, FIFO, and cleared on every
  schema change (`index_create` / `index_drop` clear all models' caches).
  FIFO rather than LRU: the entries worth keeping are the ones a program
  reuses, and the ones that fill the cache are the ones an interpolated
  `order` made — which were never worth a second lookup.
- ~~**`Relation` vs `Enumerator`.~~ **Resolved (M8).** Both, minus the
  part that hurts: `Relation` is the object, so `person.knows.where(...)`
  reads the way Rails writes it and `to_cypher` can show the statement the
  chain compiles to; `include Enumerable` gives `map`/`select`/`count` for
  free. A bare `Enumerator` cannot report its own statement, and the R10
  gate needs a statement to assert on.
- **Frozen results.** A `Result` that outlives its block is closed, which
  is correct but surprises people who write `r = db.query(...)` then
  iterate later. `db.query` currently returns a closed `Result`; an
  auto-open `Result` that manages the statement would be friendlier and
  leak-prone. Keeping the strict form; the docs must be loud.
- **Gem name.** `glyphes` is taken on rubygems.org (and is a different
  project). Needs a real name before `gem push`. Flagged so it is not a
  day-one surprise.
