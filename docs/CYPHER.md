# glyphes — CYPHER: the language contract

> **Status:** normative. The read half is built and gated (M4); the write
> half is built through M5.6 — `CREATE`, `SET` / `REMOVE` /
> `DELETE` / `DETACH DELETE`, `MERGE` with `ON CREATE` / `ON MATCH`,
> aggregates and grouping, `OPTIONAL MATCH`, variable-length patterns,
> `Sort` with spill, and — at M6.1 — the range index. `FOREACH` is the
> last write clause refused.
> Anything described here as refused is refused *by name* with
> `GLY_ERR_UNSUPPORTED`, and `tests/conformance/tck_subset.txt` carries one
> out-of-contract row per refusal so the list cannot rot.
>
> Companions: `EXEC.md` (how it runs), `INDEX.md` (the callable indices),
> `TXN.md` (what a write does), `STORAGE.md` (what is stored).

---

## 0. What is built

### 0.1 The read surface

| Clause | State |
|---|---|
| `MATCH` — one pattern chain, any number of hops | built |
| `OPTIONAL MATCH` — left-outer, one per query | built |
| `WHERE` on the match, on the `WITH`, three-valued | built |
| `RETURN` with aliases and the `*` form's column names | built |
| `ORDER BY` (alias or source variable, `ASC`/`DESC`), `SKIP`, `LIMIT` | built |
| `ORDER BY` with spill over a row budget | built |
| `RETURN DISTINCT` | built |
| `UNWIND … AS x`, `WITH … [WHERE …]` | built |
| Variable length `-[r*1..3]->`, `*`, `*2..` | built |
| Properties: `n.age`, index and map subscript, string predicates | built |
| Arithmetic, comparison, `AND`/`OR`/`XOR`/`NOT`, `IN` | built |
| Aggregates (§2.8) and the grouping they imply | built |
| Parameters by name | built |
| Reading functions (§2.7), including `range()` | built |
| Pattern predicates `all`/`any`/`none`/`single`, `CASE` | refused (§5) |

### 0.2 The write surface

**M5.1 — `CREATE`**: node patterns, relationship patterns, inline property
maps, parameters, and the per-row form (`MATCH … WHERE … CREATE …`)
through `glyphes_exec` / `db.exec`.

**M5.2 — `SET` / `REMOVE` / `DELETE` / `DETACH DELETE`**, through the same
`db.exec` door, joining an open transaction or starting one. A transaction
reads its own writes; a statement does not read its *own* (§0, pin C4).

**M5.3 — `MERGE`**, match-or-create, with the action clauses:

```cypher
MERGE (n:Person {name: 'Ana'})
MERGE (a:Person {name: 'Ana'})-[:KNOWS {since: 2024}]->(b:Person {name: 'Bo'})
MERGE (n:Tag {name: $tag}) ON CREATE SET n.created = true() ON MATCH SET n.seen = n.seen + 1
```

Three rules that are not obvious, each with a named test:

1. **`MERGE` creates the *whole* pattern or nothing.** If any element fails
   to match, every element is created — so `MERGE (a:P {n:'a'})-[:R]->(b:P)`
   against an existing `a` creates a *second* `a` rather than reusing it.
   "Make sure this node exists exactly once" wants a uniqueness constraint
   (M6) or a match-then-create; a MERGE that matched the half it liked would
   be a semi-join wearing MERGE's name.
2. **A MERGE is constrained by what the query already bound.** Under
   `MATCH (a)`, `MERGE (a)-[:R]->(b)` looks for a relationship *from that
   `a`* — the match half carries one `id(v) = …` constraint per bound
   variable. Without it the match finds "a relationship" rather than "a
   relationship from this `a`", and binds `b` to the wrong node.
3. **MERGE depends on transactional visibility.** A MERGE whose match half
   could not see the transaction's own writes would create a duplicate per
   row — the exact opposite of the clause.

MERGE costs one match plan per row (a plan is a stateful cursor, and each
row needs a fresh one; `EXEC.md` §1). An importer should prefer `CREATE`, and
reach for `MERGE` only when "or create" is the semantics wanted.

**M5.4 — aggregates** — `count`, `sum`, `avg`, `min`, `max`, `collect`,
`stdev`, `DISTINCT` on all of them, and the grouping rule that makes a
projection containing an aggregate a group-by (§2.8).

**M5.5 — `OPTIONAL MATCH` and variable length** (§2.2, §2.9).

**M5.6 — `Sort` with spill** (§2.10) and the E gates: `LIMIT 10` over a
10⁶-row traversal in 0.62 ms (gate 2 ms), and a 10⁷-row sort that spills
200 runs and completes in 88 s.

---

## 0. Pins

The rules below are quoted by name from code and tests. Changing one is a
contract change, not a refactor.

| Pin | Rule |
|---|---|
| **C1** | **Never a wrong answer.** Invalid input is refused by name. A construct that cannot be answered correctly is refused rather than approximated, and a clause after `RETURN` is an error rather than a silently dropped clause. |
| **C2** | A node's label is not its type: a scan filters on the label the caller wrote, and an unknown label is an empty result, never an error. |
| **C3** | `CASE` without `ELSE` yields `null`, and `null` is not truthy — so a `CASE` used as a condition with no matching branch filters the row out. |
| **C4** | A statement's reads never see its own writes. A *transaction* sees its own writes (pin C4's other half); the separation is what makes `MATCH … SET` mean what it says and what makes `rowsAffected` countable. |
| **C5** | `int` is i64 and `int` and `float` are never `=`. An int and a float holding the same number are different types with different semantics (overflow, precision). `3.0 = 3` answering true is how a boundary bug hides inside a `WHERE`. |
| **C6** | Three-valued logic: `null` is not `false`. Every predicate is asserted on both sides of the third value. |
| **C7** | Relationship uniqueness: a path may not use the same relationship twice. It is a *relationship* rule — a path may revisit a node through a different edge. |
| **C8** | Cross-kind equality is false, as any other kind mismatch. Only *ordering* mixes int and float, because a sort needs a total order and equality does not. |
| **C9** | A single-hop query over 10⁶ nodes answers in ≲ 20 µs; the 2-hop query over 10⁶ nodes in ≲ 3 ms. (`ROADMAP.md` carries the measured numbers.) |
| **C13** | A node carries **exactly one** label. `CREATE (n:A:B)` and `SET n:Admin` are refused by name; the store's structures assume it (`STORAGE.md` §2). |

---

## 1. Grammar shape

```
query      := clause+
clause     := MATCH … [WHERE …] | OPTIONAL MATCH … [WHERE …]
            | WHERE … | WITH … [WHERE …] [ORDER BY …] [SKIP n] [LIMIT n]
            | UNWIND expr AS var | RETURN … [ORDER BY …] [SKIP n] [LIMIT n]
            | CREATE … | MERGE … [ON CREATE …] [ON MATCH …]
            | SET … | REMOVE … | DELETE … | DETACH DELETE …
pattern    := nodePattern (relPattern nodePattern)*
```

Rules that are grammar rather than preference:

- **`RETURN` ends the query.** Only `ORDER BY`, `SKIP` and `LIMIT` may
  follow it. A second clause after `RETURN` is an error (pin C1): the first
  version parsed it, ran both projections, and answered with the first one's
  rows — invalid Cypher becoming a plausible answer.
- **`WITH` is a projection plus a boundary.** Everything after it sees only
  the projected variables.
- **`ORDER BY` resolves to the projected column**, so `RETURN n.name AS name
  ORDER BY n.age` and `ORDER BY name` are both the column named `name`.
- **Identifiers are case-sensitive**; keywords are not.
- **Variables must be defined before use.** A projection naming a variable
  no pattern bound is refused at prepare time — and the difference between
  "undefined variable" (an error) and "missing property" (null) is asserted
  on both sides.

---

## 2. Reading

### 2.1 `MATCH`

```
MATCH (a:Person) RETURN a
MATCH (a:Person)-[:KNOWS]->(b) RETURN b.name
MATCH (a)-[r:KNOWS|WORKS_AT]->(b)      -- alternation: refused (§5)
MATCH (a:A:B)                           -- more than one label: refused (C13)
MATCH (a), (b)                          -- cartesian product: refused (§5)
MATCH p = (a)-[]->(b) RETURN p          -- path binding: refused (§5)
```

One pattern chain, any number of hops; each relationship is one Expand, so
a three-hop pattern is three rows deep without a join operator. An
undirected pattern reports each edge once per direction, which is what
makes `MATCH (a)-[r]-(b)` over three edges produce six rows. A *directed*
pattern with no edge produces nothing; an undirected one produces the row
with its relationship variable unbound — that is what `-[r]-` means for an
isolated node.

`()` is anonymous and binds nothing; internally such a node is given a
name beginning with `_`, which Cypher's identifier rule forbids for a
caller's identifier and so cannot collide with one.

**Property maps in a MATCH pattern are filters**; in a CREATE pattern they
are values to store (§3.1). Same grammar, opposite meaning, and the
difference is the milestone.

### 2.2 `OPTIONAL MATCH`

```
MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_AT]->(c) RETURN p.name, c.name
MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_AT]->(c) WITH p, c WHERE c IS NULL RETURN p.name
```

Left-outer: every row the left side produced comes out. Rows whose pattern
matched get the pattern's bindings; rows that matched nothing come back with
the pattern's variables set to `null` and **the left side's own variables
untouched** — nulling `p` too would erase the row the join promised to keep.

**A `WHERE` after `OPTIONAL MATCH` belongs to the pattern**, so it filters
the right side *before* the null-filling:

```
MATCH (a) OPTIONAL MATCH (a)-[:R]->(b) WHERE b.n = 'x3'   -- every a comes back
MATCH (a) OPTIONAL MATCH (a)-[:R]->(b) WITH a, b WHERE b.n = 'x3'   -- what it looks like
```

The first is not the second. It reads like "the nodes with no x3
neighbour", but a node that matched a *different* neighbour also comes
back — null-extended, because pattern-plus-predicate matched nothing. The
`WITH` spelling puts the predicate on the join's *output*, which is what
"and then filter" means. Both are pinned by named tests.

Refused: a second `OPTIONAL MATCH` in one query, and an `OPTIONAL MATCH` as
the first clause (nothing to its left — a full scan with a null case that
cannot occur).

The right side is planned per row: a plan is a stateful cursor, and a
correlated one has to be a fresh cursor per input row. Whether the pattern
is correlated or free is a property of *this row* — `OPTIONAL MATCH (a)-[:R]->(b)`
is correlated for a row carrying `a` and a product for one that does not,
which is what happens after another optional match null-filled `a`. So the
correlated form is the one to prefer.

### 2.3 `WHERE`

```
WHERE a.age > 30 AND a.city = 'Lyon'
WHERE a.name IN ['Ana', 'Bo']        WHERE a.name STARTS WITH 'A'
WHERE a.x IS NULL                   WHERE NOT (a.x = 1)
```

Three-valued (pin C6): a comparison against `null` is `null`, and `null`
is not truthy, so `WHERE NOT (a.x = 1)` does **not** keep the rows where
`x` is null — `NOT null` is null too. A missing property is null, not an
error; a missing *variable* is an error at prepare time.

### 2.4 `WITH`

```
WITH a, a.name AS n WHERE n STARTS WITH 'A' RETURN n
WITH count(*) AS c ORDER BY c DESC LIMIT 10
WITH a, collect(b.name) AS friends
```

A projection plus an aggregation boundary plus an optional
`WHERE`/`ORDER BY`/`SKIP`/`LIMIT`. Everything after it sees only the
projected variables. An aggregate in `WITH` **groups by** all
non-aggregated items, per Cypher — required, and getting it wrong is a
classic bug, so it is a named test.

### 2.5 `UNWIND`

```
UNWIND [1, 2, 3] AS x RETURN x
UNWIND range(1, 10) AS i RETURN i
UNWIND [] AS x RETURN x          -- zero rows
UNWIND null AS x RETURN x        -- zero rows
```

One output row per element, the input row's bindings carried forward. An
empty list and `null` produce no rows, which is what makes `UNWIND` a
filter by existence.

### 2.6 Paths

A pattern is not a value in 0.1. `MATCH p = (a)-[]->(b) RETURN p` is refused
by name (§5): a path has node ids, edge ids and a direction per edge, and
binding one as a value means building it per walk and rendering it at the
ABI — a surface with no consumer in the contract yet. `nodes(p)`, `relationships(p)`
and `length(p)` exist in the function table for the day it does, and return
an empty list rather than refusing — so a query written against the full
surface fails on the *semantics* it is missing, not on the spelling.

Direction matters in the value model: a relationship has a source and a
destination, and `(a)-[:R]-(b)` is `(a)-[:R]->(b)` *or* `(b)-[:R]->(a)`,
which is why it produces two rows per edge.

### 2.7 Reading functions

| Function | Notes |
|---|---|
| `id(x)` | node or relationship → int |
| `labels(n)`, `type(r)` | list of one, or the string (§2.1: one label) |
| `keys(x)`, `properties(x)` | a map; null-safe |
| `toString`, `toInteger`, `toFloat` | `toInteger('nope')` is **null**, not an error |
| `abs`, `size`, `length`, `head`, `last`, `reverse` | `size` on a list, a string, or a relationship list |
| `coalesce(a, b, …)` | first non-null |
| `toLower`, `toUpper`, `trim`, `replace`, `substring` | strings |
| `startsWith`, `endsWith`, `contains`, `=~` | `=~` is bytewise |
| `nodes`, `edges`, `relationships` | present for §2.6's path value and return an empty list while paths are refused — a named shape rather than an "unknown function", so a query written for the full surface fails on the *semantics* and not on the spelling |
| `range(a, b)` / `range(a, b, step)` | inclusive at both ends; with no step the range runs *toward* the end, so `range(3, 1)` is `[3, 2, 1]`. Capped at 10⁷ elements because the list is materialised |
| aggregates | §2.8 |

Every other name is refused by name: "no such function" and "returned
null" are different problems, and conflating them is how a typo becomes a
silent empty result set.

### 2.8 Aggregates

```
RETURN count(*)                          -- one row, whatever the graph holds
MATCH (n:Person) RETURN n.city AS city, count(*) AS c
MATCH (n:Person) RETURN sum(n.age) AS total, avg(n.age) AS mean,
                       min(n.age) AS lo, max(n.age) AS hi
MATCH (n:Person) RETURN collect(n.name) AS names, collect(DISTINCT n.name) AS unique
MATCH (n:Person) RETURN count(DISTINCT n.city) AS cities
MATCH (n:Person) RETURN stdev(n.age) AS sd
MATCH (n:Person) WITH n.city AS city, count(*) AS c WHERE c > 1 RETURN city
```

Seven aggregates: `count`, `sum`, `avg`, `min`, `max`, `collect`, `stdev`.
`DISTINCT` is a property of any of them and dedupes on the values, first
occurrence winning.

**A projection with an aggregate is a grouping.** The non-aggregated items
form the group key and each distinct key produces one row, so
`RETURN n.city, count(*)` is one row per city. With no key there is one
group — a statement *about* the whole input, not a filter over it. The key
is the *values*, so a node with no city is a group of one keyed by null
rather than a member of a default bucket: `count(*)` and the sum of the
group counts must agree, and skipping nulls is how they stop agreeing.

| Aggregate | Empty input | Nulls | Type |
|---|---|---|---|
| `count(*)` | `0` | counts rows, nulls included | int |
| `count(x)` | `0` | skips nulls | int |
| `sum(x)` | `0` | skips nulls | int if every value is an int, else float |
| `avg(x)` | `null` | skips nulls | float |
| `min(x)` / `max(x)` | `null` | skips nulls | orderable values; refuses a list, map or vector |
| `collect(x)` | `[]` | skips nulls | list, input order preserved |
| `stdev(x)` | `0.0` | skips nulls | float, **sample** deviation (n−1) |

`sum` of nothing is `0` and `avg` of nothing is `null`: a total over an
empty set has its identity, a mean over an empty set does not exist. An
integer `sum` stays an integer — widening to float would print `6.0` and
lose exactness above 2⁵³, which is where a caller counting things is. One
value's `stdev` is `0.0`: nothing varies. `min`/`max` check the *type*
before folding, so `max(x)` over a single list value is refused rather than
answering with the list.

**`WHERE count(*) > 1` is refused** (`GLY_ERR_UNSUPPORTED`, naming the
aggregate) rather than evaluated per row. Evaluated, it is *always false* —
an empty result that looks like data. Aggregates live in `RETURN` and
`WITH` projections and nowhere else; to filter on one, group and filter
after, as in the `WITH` example above.

### 2.9 Variable length

```
MATCH (a)-[r*1..3]->(b) RETURN b, size(r)     -- r binds the *list* of edges
MATCH (a)-[*]->(b)                            -- 1..∞; uniqueness is what stops it
MATCH (a)-[r*2..2]->(b)                      -- a two-hop walk, not a relationship
MATCH (a)-[r:KNOWS|SIMILAR_TO*2]->(b)         -- refused: an alternation needs a set
```

One row per **walk**, not per endpoint: two different walks ending at the
same node are two rows. The relationship variable binds the whole path as a
list of relationships, so `size(r)` is its length. `p = (…)` path binding is
still refused (§2.6).

**Relationship uniqueness** (pin C7) is what makes this finite: a path may
not use the same relationship twice, which bounds an unbounded `*` by the
edge count even on a cyclic graph. It is a relationship rule, not a node
one — a walk may revisit a node through a different edge, and `*3..3` over
a 3-cycle returns to where it started.

`*2..2` is *not* a plain relationship: it is a two-hop walk with
uniqueness, and writing it with one number does not turn it into one.

Cost: a variable-length step enumerates every walk from its bound node, so
an unbounded `*` over a dense graph is a lot of walks. Bound the range in
a query that runs over data you did not choose.

### 2.10 `ORDER BY` with spill

`ORDER BY` is a barrier: every row is compared before the first is handed
out, so it is the one operator that buffers. Under a row budget it writes
sorted *runs* to disk and k-way merges them — ten million rows buffered is
measured in gigabytes, so "sort it in RAM" is a size limit, not a tuning
decision.

A spilled sort answers exactly what a buffered one does, row for row and
order for order: the budget is a memory knob and not a semantic one. Below
the budget nothing is written at all, which is the path every ordinary
query takes. `LIMIT` above a spilled sort stops the merge after the rows
it wants — the runs are written as the input arrives either way, so a query
that wants ten rows pays for ten rows and not for ten million.

The runs live in the database's directory (the OS temp directory when there
is none) and are deleted when the statement closes — including when the
caller abandons the statement after a few rows, which is the path most
likely to leak. A run file that is not one is refused by its header rather
than decoded.

---

## 3. Writing

### 3.1 `CREATE`

```
CREATE (n:Person {name: 'Ana', age: 34})
CREATE (a)-[:KNOWS {since: 2020}]->(b)
CREATE (a:P), (b:P)
UNWIND [1,2] AS i CREATE (:Row {i: i})
MATCH (a:Person) WHERE a.age > 30 CREATE (a)-[:ADULT]->(:Marker)
```

Per row: one row in, one row out, with the variables it just bound. That is
why `CREATE (n) RETURN n` answers with the node it made, and why
`MATCH (a) CREATE (a)-[:R]->(b)` connects the existing `a` and makes `b`.
Nodes are created left to right so a relationship always has both
endpoints.

Property maps here are **values to store**, where in a MATCH pattern they
are filters (§2.1). An anonymous `CREATE (:X)` binds nothing, and a row
count that looked the variable up would miss every node whose pattern had
no name — so the count happens where the write does.

`rowsAffected` counts **entities** created, not rows and not property
writes: `SET n.age = 1` updates a node and an importer asking "how much
landed" wants nodes.

### 3.2 `SET` / `REMOVE`

```
MATCH (n:Person) SET n.age = 34
MATCH (n:Person) SET n.city = 'Lyon', n.age = n.age + 1
MATCH (n:Person) SET n = {name: 'Ana', age: 34}
MATCH (n:Person) SET n += {city: 'Lyon'}
MATCH (n:Person) REMOVE n.age
```

`SET n = map` **replaces** the property set; `SET n += map` merges it.
`SET n.x = null` is `REMOVE n.x` — the same statement, and refusing it
would mean two ways to say one thing. A property path `n.a.b` is refused:
`SET` writes on a node, never through one. `SET n:Label` is refused (C13).

### 3.3 `DELETE` / `DETACH DELETE`

```
MATCH (n:Person {name: 'Ana'}) DELETE n
MATCH (n:Person) DETACH DELETE n
```

`DELETE` refuses a node with relationships unless every one is given in the
same clause — deleting a node and orphaning its edges is not an answer.
`DETACH DELETE` removes them. Both are transactional and both are counted
per entity.

### 3.4 `MERGE`

See §0.2. The clause is:

```
MERGE pattern [ON CREATE SET … | ON MATCH SET …] … [ON CREATE REMOVE …] [ON MATCH REMOVE …]
```

Both action clauses may appear, and each runs on exactly one of the two
outcomes. The match half is planned per row and constrained by every
already-bound variable.

### 3.5 Expressions

Precedence, lowest to highest: `OR` → `XOR` → `AND` → `NOT` → comparison
(`= <> < <= > >= IN CONTAINS STARTS WITH ENDS WITH =~ IS NULL`) →
additive `+ -` → multiplicative `* / %` → power `^` → unary `-` → postfix
`.` and `[...]`.

```cypher
RETURN 2 + 3 * 4 AS x          -- 14, not 20
RETURN [1, 2, 3][1] AS x       -- 2
RETURN {a: 1}.a AS x           -- 1
```

`CASE` is refused in 0.1 (pin C3 names its semantics so the refusal is
about the milestone and not about the rule).

---

## 4. Callable indices

The hybrid-retrieval surface, and the reason glyphes exists. `INDEX.md`
specifies how the indexes store and retrieve; this section is the shape
they take *in a query*: a traversal and a retrieval in one statement,
composed (`EXEC.md` §2.5).

```cypher
MATCH (p:Person) WHERE p.age > 30 RETURN p          -- range index
CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score   -- BM25
CALL db.idx.vector('Doc.embedding') AGAINST $v YIELD doc, score
MATCH (d:Doc) WHERE d.year = 2024 RETURN d            -- filtered traversal
```

**M6.1 — the range index is built.** It is not a `CALL`: it is reached the
way Cypher reaches one, transparently, through a predicate:

```cypher
db.index_create(kind: :range, label: "Person", property: "age")
MATCH (n:Person) WHERE n.age > 30 RETURN n     -- seeks
```

The planner picks it for `=`, `<`, `<=`, `>`, `>=` and `IN` on an indexed
property (EXEC.md §4.1 rules 2 and 3), and the predicate still runs above
it — an accelerator can lose a row, it cannot invent one. A query that
needs no index behaves exactly as before, because an index is not in the
file format and a reopened database starts with none.

Still **refused** in 0.1: `UNION`, Cypher-level constraint DDL, and a
`MATCH` after a retrieval — that composition is a join (a cartesian
product or a semi-join), and the operator set does not have one; the
filtered traversal is answered with the pushdown below, which is where
the filter belongs.

**M6.2 — the text family and the constraint client are built.**

```cypher
db.index_create(kind: :text, label: "Doc", property: "body")
CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score
  WHERE score > 0.5 RETURN doc, score
```

The retrieval is a *source*: it produces rows from the index rather than
filtering rows that already exist. The query is data — a parameter or a
string literal, refused otherwise — analyzed by the index's own analyzer
(`standard`: case-folded, no stemming, no stopwords; terms under two
characters are not terms). Terms OR by default; scores are raw BM25
(k1=1.2, b=0.75), best first, and `score` is a float. Yields one or two
names, document then score; both are ordinary variables, so `WHERE` and
`RETURN` compose above them.

What a statement inside the writing transaction sees is governed by pin C4,
and the retrieval honors it: the transaction's own documents are analyzed
at step time and merged over the committed hits, scored against the
committed N and avgdl (exact after the commit). A deleted node is never
returned (I8), tombstoned or not.

Refused by name: any other procedure, `CALL { … }` subqueries,
`CALL … IN TRANSACTIONS`, and a `CALL` after another clause — either
direction of a CALL/MATCH composition is a join, and the operator set
does not have one. Filter with `WHERE` on the yielded variable instead:
that is the pushdown, and it is where the filter belongs.

**M6.3 — the vector family is built.** Same shape, one flag:

```cypher
db.index_create(kind: :vector, label: "Doc", property: "embedding")
  # metric: "cosine" (default) | "l2" | "dot"; m / ef_construction
  # overridable; ef_construction < 200 is refused at creation
CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score
  WHERE doc.year = 2024 RETURN doc, score
```

The query is a vector value or a list of numbers — a JSON array is what
the Ruby binding hands over, and refusing it there would make the Ruby
surface unable to pass embeddings. Terms of art: scores are
similarity-shaped (cosine similarity; `1/(1+d)` for l2; the dot), best
first (I12); the metric is per index and changing it needs a rebuild
(I13). A `WHERE` above the retrieval is *split*: conjuncts over the
yielded node are pushed into the walk and evaluated per candidate — the
engine's own expression evaluator, so comparison semantics are one
implementation — while conjuncts over `score` or other variables stay a
plain filter above. The pushed filter sizes the walk by selectivity
(over-fetch, I10): from a range index on the property when one exists
(0.5 prior), otherwise 0.1, capped at 4096 candidates — a wrong estimate
costs time, not correctness. A statement inside the writing transaction
sees its own vectors scored exactly (per-pair distances have no global
statistics to approximate), and a deleted node is never returned (I8).
Recall and determinism are gated in `nimble benchVector`: 0.960
recall@10 at the defaults on 10⁵ 64-dim vectors, byte-identical rebuild
(I11).

**M6.2 — constraints (I9).** A constraint is the range index with a second
client (TXN.md §5), created through the same call as the index it rides:

```ruby
db.index_create(kind: :range, label: "User", property: "email",
                constraint: :unique)   # or :exists, :not_null
```

Enforced at commit, before anything is durable: a violation fails the
transaction with `GLY_ERR_CONSTRAINT`, naming the offending value and the
conflicting key or node. `exists` and `not_null` are one check with two
spellings (a stored null does not exist — `SET n.x = null` is a removal).
`unique` bounds values: nulls do not collide, an int and a float of the
same magnitude are one key, and a value the index cannot key (a bool, a
list) refuses the write rather than pass unchecked. Creating a constraint
over data that already violates it is refused, so a constraint is never a
no-op that looks like a guarantee. Two documented limits: constraints are
the range family only (a text or vector index cannot enforce one), and
uniqueness is checked against the store through `seekEq`, which is a
per-write walk of one posting list, not a second copy that could disagree.

---

## 5. Rejections

Refused with `GLY_ERR_UNSUPPORTED` and a message **naming the construct**,
one out-of-contract row each in `tests/conformance/tck_subset.txt`, all
checked by `nimble tck`:

| Construct | Message names |
|---|---|
| a second `MATCH` clause (a join) | "second MATCH" |
| a comma-separated `MATCH` (cartesian) | "cartesian" |
| `OPTIONAL MATCH` as the first clause | "left" |
| a second `OPTIONAL MATCH` in one query | "second" |
| path binding `MATCH p = (a)-[]->(b)` | "path binding" |
| relationship type alternation `[:A\|B]` | "alternation" |
| more than one label per node | "more than one label" (C13) |
| an aggregate outside a projection | "aggregate" |
| an aggregate that cannot fold its values | "needs numbers" / "orderable" |
| `CASE` | "CASE" |
| pattern `EXISTS` | "EXISTS" |
| list comprehension `[x IN xs \| …]` | "comprehension" |
| quantifiers `all`/`any`/`none`/`single`/`reduce` | the keyword |
| `shortestPath` / `allShortestPaths` | the keyword |
| `UNION`, `CALL` other than `db.idx.text`, `CALL … IN TRANSACTIONS`, `FOREACH` | the keyword, or the procedure's name |
| an unknown function | the function's name |
| a nested property path in `SET` | "nested property writes" |
| `SET n = <not a map>` | "needs a map" |
| a write clause with no transaction | the clause |

Two more that are refused with `GLY_ERR_SQL` rather than unsupported,
because the query *is* malformed: a variable nobody bound, a map subscript
on a non-map, a comparison between incomparable types.

---

## 6. Types

The property value model is `STORAGE.md` §2.4; what the query layer adds is
the three reference kinds, so that a row can bind a node, a relationship or
a path without a conversion at every literal and every property read:

```
null  bool  int (i64)  float (f64)  string  bytes  vector<f32>  list  map
                                                        ├── the reference kinds
                                                        node  relationship  path
```

A node or relationship cannot become a property: `setProp` and the blob
codec reject them, so they never reach the snapshot and adding them changed
no stored bytes and no pin.

**Comparisons.** Numbers compare across `int` and `float` — a sort needs a
total order, and refusing to order them would leave the sort undefined.
Strings compare bytewise, which is what openCypher does for `<`. Booleans
order `false < true`. Anything else — a node against a number, `null`
against anything — is *incomparable*, and the caller turns that into an
error by name.

**Equality does not mix kinds** (pin C8): `3 = 3.0` is `false`, and
`null = null` is `null` rather than `true`, so `WHERE n.x = n.x` does not
keep every node.

---

## 7. Conformance

`tests/conformance/tck_subset.txt` is the committed denominator for gate C1.
It is a **hand-derived subset** of openCypher's scenario families, not a
sync of the upstream TCK repository — a sync would bring a licence and a
build we do not have, and the rows would then change under us. Each row is
`in` (in the 0.1 contract, with its expected JSON answer) or `out` (out of
contract, with the substring its refusal must contain).

Out-of-contract rows are **never** counted as passes: they are the
implementation queue. Gate C1 passes at ≥ 95 % of the `in` rows and requires
every `out` row to be refused *by name*.

---

## 8. The surface above it: GLYPH QUERY

GLYPH QUERY (PRD-GLYPH-QUERY.md) is the language a child types, and it
is a **surface over this one**: every statement it accepts compiles to
Cypher and runs here, on the same statements, the same cells and the
same transactions. It is not a second engine, and it adds no semantics
of its own — with one exception, below.

**The exception is `link`.** Two nodes that are *already bound* cannot be
joined in this language: two `MATCH` clauses are a join (§2.1 refuses
them), a comma-`MATCH` is a cartesian product and is refused, and a
`MERGE` would *create* the missing far end instead of refusing it
(§3.4). So the edge between two existing nodes is one write door of its
own — `glyphes_link` (ABI.md §2) — rather than a second execution path.

Everything else the surface needs, this language already has: `find` is
a labelled scan, `go` is an expansion, `count` is an aggregate, `add` is
a `CREATE`, `set` is a `SET`, `drop` is a `DETACH DELETE`, and `where`
is this language's own expression syntax with the bare property names
rewritten to `n.<name>`. The rewrite is *positional* — it inserts a
prefix and changes nothing else — so a float literal or a string with an
escape keeps its exact spelling.

**The values never travel as text.** A literal in the surface becomes a
parameter, and a client's own values are parameters too: the compiled
text is a fixed string whatever the value is, which is what makes the
surface safe to hand to a child (pin GQ4).
