# PLAN — CYPHER extensions: the five constructs, and the three decisions

> The five constructs below are the ones `limitations.md` publishes as
> *not implemented*. This plan says what each one means, what it costs,
> and in what order they land. Three more are **decided against** and
> stay refused, with the reasons recorded here rather than left as a
> shrug.

The discipline is the repo's: a construct is refused **by name** until
it is implemented, the TCK carries one out-of-contract row per refusal
so the list cannot rot, and nothing lands without a **measurement** —
a cost that has not been measured is a claim, and a claim is not a
gate.

---

## 1. The order, and why

| # | Construct | Why here |
|---|---|---|
| **X1** | `FOREACH` — **landed** | the cheapest: it reused the write operators that already exist |
| **X2** | graph-pattern predicates — **landed** | a filter over the adjacency the engine already has |
| **X3** | the type discipline — **landed** | a *foundation*: a date is a type, and there is no point adding types before the types are named and checked |
| **X4** | shortest-path functions — **landed** | a traversal with a real cost, and it must be measured before it is offered |
| **X5** | temporal/spatial types — **X5a landed (DATE)** | the largest: new value kinds, new literals, new functions, new storage |

X3 sits in the middle rather than the start because it touches every
operator, and touching every operator before anything else exists makes
the diff unreviewable. It sits before X5 because X5 *is* types.

---

## 2. X1 — `FOREACH`

```
FOREACH (n IN $nodes | SET n.age = 1)
FOREACH (n IN $nodes | REMOVE n.age)
```

**The semantics.** The list is a **parameter** — the engine refuses
`UNWIND`, so a subquery or a literal list are the only other sources
and neither exists. The variable is bound to each element in turn, and
the update applies to it. Only `SET` and `REMOVE` are allowed inside:
a `CREATE` or a `DELETE` inside `FOREACH` is refused by name, as
openCypher refuses it — the write set of a statement is what the
transaction logs, and a statement that creates *and* deletes in a loop
is a different thing to reason about.

The writes go through the **existing** `SET`/`REMOVE` operators, so
they reach the WAL by the path that already works (the client's link
door was fixed for exactly this reason: a write that does not reach
the log is a memory that a restart forgets).

**What it is not.** It is not a join, and it does not bind anything
outside the loop. Pin C4 still holds: a statement never sees its own
writes, and a `FOREACH` inside a transaction sees the transaction's
writes like any other clause.

**The pins.** A new one: **C14 — `FOREACH` writes only through `SET`
and `REMOVE`, and the list is a parameter.** A new one: **C15 — a
`FOREACH` is one statement and one transaction**, like every other
write.

**The gates.** The grammar in `CYPHER.md` §3; a refusal by name for
`CREATE`/`DELETE` inside it; the WAL row (the write survives a
reopen); the TCK's out-of-contract row becomes an `in` row; the cost
measured (the engine's C9 pin is about single-hop queries, and this is
N writes, so the plan says what N writes cost).

---

### X1 — landed (M5.7)

`FOREACH` is in: the parser (`parseForeach`, reusing `parseSetItems` and
`parseRemoveItems`), the plan (`newForeach`), the operator (`okForeach`),
the scope check (the loop variable is taken back out of the scope), and
the tests (the per-element count, the refusals by name, the scope, the
write door, and a reopen). The TCK row `write-foreach` is an `in` row and
C1 is 133/133; `limitations.md` no longer lists it.

### X1's recipe — the five edits, in order

*(Kept as written: it is how the clause was built, and the shape recurs
for every write clause.)*

The clause is a *write clause* like `SET`, and it is worth spending one
sentence on why that is the cheap shape: a `FOREACH` applies the **same
`SetItem`s** a `SET` applies, to a list of nodes instead of to the
current row. So the whole implementation is "evaluate a list, bind a
variable per element, apply the items" — and the "apply" is already
written (`applySetItem` in `ops.nim`, used by `okSet`).

| # | file | the edit |
|---|---|---|
| 1 | `src/cypher/ast.nim` | a `qpForeach` part: `list*: Expr`, `varName*: string`, `setItems*: seq[SetItem]`, `removeItems*: seq[PropRef]` — the same item types `SET` and `REMOVE` use, for the reason `MERGE`'s `ON CREATE SET` reuses `SetItem` |
| 2 | `src/cypher/parser.nim` | `parseForeach`: `FOREACH ( n IN <expr> | SET … \| REMOVE … )`. The list is a **parameter** (`UNWIND` is refused, so there is no other source); the body is `SET`/`REMOVE` only — `CREATE` or `DELETE` inside is refused by name, as openCypher refuses it. The existing `parseSet`/`parseRemove` bodies are reused rather than re-written, so a `SET` inside a `FOREACH` and a `SET` outside it are the same code |
| 3 | `src/cypher/execute.nim` | the scope arm: the variable is added to the scope (the `qpUnwind` precedent — it leaks the same way an `UNWIND`'s variable does), and the items' targets are checked against it with `checkWriteTarget` |
| 4 | `src/cypher/plan.nim` | `of qpForeach:` → `seed = newForeach(ctx, seed, part)` — beside the other write clauses, so it takes a row to act on the way they do |
| 5 | `src/cypher/ops.nim` | an `okForeach` operator: per row, evaluate the list expression; for each element, copy the row, bind the variable to the element, and apply the items with `applySetItem` / the `REMOVE` path — **and the row count must not change**: a `FOREACH` is not an `UNWIND`, it writes and passes the row through |

**The two traps, named.**

- **The rows must not multiply.** An `UNWIND` turns one row into N;
  a `FOREACH` must turn one row into one. The operator therefore
  applies the items *in place* and leaves the row alone.
- **The element must be a node.** `FOREACH (n IN $ids | SET n.x = 1)`
  with `$ids` holding node ids is the shape that works; an element that
  is not a node is refused by name, the way `DELETE`'s target is.

`rowsAffected` counts the writes, as it does for `SET`.

## 3. X2 — graph-pattern predicates — landed (M5.8)

Implemented as the *filter* form, with every variable already bound
(`ekPatternPred`, `patternHolds`). The measured cost is 0.31 µs per row
for one hop over a 10 000-node graph with three relationships each
(a plain property comparison: 0.13 µs). The refusals by name are the
ones §3 above predicted, plus two the implementation made explicit:
a label or a property map *inside* the predicate matches the shape only
and is refused rather than ignored, and a predicate must start at a
bound node.

The original section follows, because the reasoning is what a reader
wants when changing it:


```
MATCH (a:Person), (b:Person)
WHERE (a)-[:KNOWS]->(b)
RETURN a.name, b.name
```

**The semantics.** A pattern over **already-bound** variables, used as
a filter: the row survives if the pattern holds. Every variable in the
pattern must already be bound by the enclosing `MATCH`; a pattern that
introduces a new variable is refused by name, because binding one
would be a semi-join, and the engine refuses joins (CYPHER.md §2.1,
and the limitation that follows from it).

This is the *filter* form of the standard's pattern predicate. The
subquery form — `EXISTS { … }` — is a **decision**, below.

**The cost.** The check is the adjacency the engine already has: one
hop is O(1) from the source's edge list. A pattern with a bounded
length (`[*1..3]`) is a bounded walk; an unbounded one is refused,
because an unbounded walk on a cyclic graph is a hang, and the engine
does not hang (the client's loops refuse rather than run forever —
the same rule).

**The pins.** A new one: **C16 — a graph-pattern predicate binds
nothing**: every variable in it is already bound, and a pattern that
would introduce one is refused.

**The gates.** The grammar in §2.3; the refusal by name for an
unbound variable and for an unbounded length; a differential test
against the equivalent hand-written `WHERE`; the TCK row; the cost
measured (a pattern filter multiplies the per-row cost by the pattern's
hops, and the plan says by how much).

---

## 4. X3 — the type discipline — landed (M5.9)

`typeof()` answers with the contract's names (a node's label is its type,
a relationship's type name is its type), and every operator refuses a
wrong-typed operand by naming both types. Two things the implementation
settled that the plan above did not say:

- **The check precedes the value's decision.** `1 OR true` answers `true`
  mathematically and is a type error nonetheless, so `AND`/`OR` check both
  sides as soon as both are evaluated. The left side's own short-circuit
  still skips the right entirely — a value never evaluated cannot be
  type-checked.
- **A node created in the same statement has a type.** `labelOfNode` /
  `typeOfEdge` were snapshot-only, so reading the label of a node the
  transaction had just made indexed past the snapshot's arrays. They are
  delta-aware now, which `typeof` needed and `labels(n)` wanted.

`limitations.md` no longer lists "most of the type system"; what remains
there is the temporal/spatial half (X5).

The original section follows:

## 4. X3 — the type discipline

Not a static type system — the engine is dynamically typed, as Cypher
is, and it is not going to stop being that. This is the **runtime**
discipline: types are named, checked and reported.

| piece | what it is |
|---|---|
| `typeof(expr)` | the name of a value's type: `INTEGER`, `FLOAT`, `STRING`, `BOOLEAN`, `NULL`, `LIST`, `MAP` |
| **operand typing** | every operator declares the types it accepts, and refuses a mismatch **by name** |
| **parameter typing** | a parameter's type comes from the JSON that carries it, and is reported the same way |
| **the node's type** | a node's label is its type — one label per node (C13), and `typeof(n)` on a node is its label |

**Why it is a foundation.** C5 already says an `int` and a `float` are
never `=`. Today that is a *rule* in a few operators; after X3 it is a
property of the whole expression layer, and adding a temporal type
(X5) means adding it to one table rather than to every operator.

**The pins.** A new one: **C17 — every operator names the types it
accepts and refuses the rest by name.** C5 is restated as a case of
C17 rather than replaced.

**The gates.** `typeof()` in §2.7; the operator table in §3.5; a test
per operator per mismatch (the table is the test list — a refusal
table that is not a test list rots); the TCK rows.

---

## 5. X4 — shortest-path functions — landed (M6.4)

`shortestPath(a, b [, type [, maxDepth]])` and `shortestPathLength(…)`,
undirected, with the three outcomes §5 above named: found, no path
(`null`), and **too deep** (refused by name, pin C18). The measured cost
(10 000-node ring, three relationships each) is 0.01 ms for a neighbour,
0.8 ms for 300 hops, and 2.6 ms for a bound hit after ~3000 nodes — the
graph, not the query, which is why the bound is a pin.

`allShortestPaths` stays refused: a list of paths is a second shape with
a second cost.

The original section follows:

## 5. X4 — shortest-path functions

```
RETURN shortestPath(a, b, 'KNOWS')
```

**The syntax is a function, not a pattern.** The standard's
`shortestPath((a)-[*]-(b))` is path *binding*, and the engine refuses
path binding (CYPHER.md §2.6). The function form takes the two
endpoints and an optional relationship type, and returns:

- the **length** in hops, as a number, or
- the **path** as a value — the engine's ABI already has a `GLY_PATH`
  cell and the Ruby binding already has a `Path` class, so a path as a
  *value* exists; only path *binding* does not.

No path between the two nodes is `null`, not an error: a graph is not
obliged to connect two things, and "no path" is a fact, not a failure.

**The traversal.** A breadth-first search over the typed edges, with a
visited set — a cycle must not make it loop. The visited set is the
one piece of machinery that does not exist yet: the engine has no
per-query set, so it has to have one, or the traversal has to be
bounded.

**The cost, and the reason this is late.** A shortest path is O(V + E)
in the worst case and unbounded in the graph's size: it is the one
construct in this plan whose cost depends on the *whole* graph rather
than on the rows. That is why it is measured before it is offered, and
why the plan insists on a **bound**: a `maxDepth` argument, and a
refusal when the bound is exceeded rather than a search that never
ends.

**The pins.** A new one: **C18 — a shortest path is bounded**: the
search has a depth limit, and exceeding it is refused by name.

**The gates.** The grammar in §2.7; the null case; the cycle case (a
graph with a cycle answers, and does not hang); the refusal for an
exceeded bound; the TCK row; **the cost measured against the C9 pin**
and published, because a construct whose cost is unbounded is a
construct that belongs in a report rather than in a prompt.

---

## 6. X5 — temporal and spatial types — X5a landed (M6.5)

`DATE` is in, end to end: the value kind (a count of days since
1970-01-01), the codec's tag (`GLY_DATE` in the store and the ABI), the
comparisons (both of them — the expression layer's and ORDER BY's), the
`date()` and `toString()` functions, the component accessors
(`d.year`/`d.month`/`d.day`, as properties of the value rather than
stored keys), the round trip through a reopen, and the refusals by name
(`date('2026-02-30')` is not a date).

What it cost, measured in edits rather than hours: six `case` arms in the
value model and the codec, two comparators, one ABI tag, one Ruby
constant. Which is the point of X3: a new type is a case in a table, not
a string in every operator.

**X5b landed too:** the date's components (`d.year`/`d.month`/`d.day`, as
properties of the value rather than stored keys), and **`POINT`** — two
`f64`, cartesian, with `point.distance`. `point.distance` is the one place
a dot starts a name rather than ending one, and the parser tells it from
`n.age` by a two-token lookahead. A point is not orderable: the standard
has no `<` for one, and a distance is a function, not an ordering.

**Still to come in X5:** `datetime`, `time`, `local datetime`,
`local time`, `duration`; arithmetic between temporal values; and the
polygonal types (`LINE`/`POLYGON` are Neo4j extensions, not openCypher,
and I would want a reason before adding them). The ABI crosses a date as
`GLY_DATE` and a point as `GLY_POINT`; a Ruby `Date`/`Point` class is the
next Ruby-side step.

The original section follows:

## 6. X5 — temporal and spatial types

**Temporal:** `DATE`, `LOCAL DATETIME`, `DATETIME`, `TIME`,
`LOCAL TIME`, `DURATION`.
**Spatial:** `POINT` (2D and 3D).

This is the largest of the five, and it is staged:

| stage | what it lands |
|---|---|
| **X5a** | the **value kinds** — the store's `Value`, the ABI's `GlyType`, the Ruby binding's cell classes, and the *encoding*: a temporal is a tagged binary, a point is a tagged binary — the same way a vector is |
| **X5b** | the **literals** — `date('2026-10-21')`, `datetime(...)`, `point({x: 1, y: 2})` — and the **functions**: `duration.between`, `duration.days`, `point.distance`, `point.within` |
| **X5c** | the **arithmetic and comparison** — a duration plus a duration, a datetime plus a duration, points compared by distance, a temporal ordered against a temporal |
| **X5d** | the **storage and the round trip** — a value written and read back is the same value, and it survives a reopen (the durability rule the client's link door was fixed for) |

**Not in X5:** indexing (a temporal index and a spatial index are two
more index families, and the index families are a project of their
own), timezone arithmetic beyond the offsets the standard names, and
the polygonal types (`LINE`, `POLYGON` are Neo4j extensions, not
openCypher — the engine implements openCypher's subset).

**The pins.** A new one: **C19 — a temporal or a spatial value is a
value**: it compares, it survives a reopen, and it crosses the ABI
without becoming text. The last clause is the one that matters: a
value that crosses as text is a value that a client cannot use.

**The gates.** The grammar in §6 (types); the round trip; the
durability; the TCK rows; the cost of a comparison measured.

---

## 7. The three decisions

These are **refused on purpose**, and the reasons are recorded so that
"not yet" does not quietly become "never" and then "why is this
missing?".

### D1 — subqueries (`CALL { … }`)

**Refused.** A subquery is a *second execution path*: its own plan,
its own variables, its own answer for what a row is, and its own
semantics for what an outer row sees. The engine's discipline is one
path (ABI pin B6 — "one mutation path = one set of WAL semantics"), and
a subquery is a second one.

The engine refuses joins (two `MATCH` clauses) for the same reason and
with the same cost argument. A subquery would not be *hard* — it would
be a second thing to keep honest, and the honest cost is not yet paid.

**What would change it.** A cost model and a plan cache: the two
things a second execution path needs to be worth having. Until then the
refusal is a decision, not a gap.

### D2 — `EXISTS { … }`

**Refused**, and it is a special case of D1: `EXISTS { … }` is a
subquery whose result is a boolean.

What the engine *does* have is the **pattern predicate** (X2) — the
same idea with the subquery taken away, where every variable is already
bound and the pattern is a filter. That is the form the engine can
answer correctly and cheaply, and it is the form a client's `WHERE`
actually wants.

**What would change it.** D1. Or a separate, narrower decision: an
`EXISTS` that is rewritten into the pattern predicate's plan, which is
a planner feature and not a parser feature.

### D3 — multi-database

**Refused.** The engine is an *embedded* store: one database per
handle, one writer, one snapshot, one WAL (ABI pin B7). A
multi-database engine needs a catalog, a name resolution step, a plan
that spans databases, and a durability story for a commit that touches
two of them — none of which are extensions of this engine, and all of
which are a different engine.

The engine's answer to "the data is in another database" is that the
other database is a **client** — and the client already has a door
(ABI.md §2), a language (GLYPH QUERY) and a prompt (GLYPH BASIC).

---

## 8. What each construct owes the house

Every one of the five, before it is done:

- [ ] the grammar in `CYPHER.md`, and the pin that goes with it
- [ ] the refusal by name for what it does *not* do
- [ ] the tests: the golden output, the refusal table, the differential
      against the hand-written equivalent where one exists
- [ ] the TCK row: an out-of-contract row becomes an `in` row
- [ ] `limitations.md`: the limitation is **lifted**, with the
      measurement that replaces it
- [ ] the cost, measured and published — C9 is a pin, and a construct
      that changes what a query costs has to say so
- [ ] the two languages are unaffected: GLYPH QUERY and GLYPH BASIC
      are *subsets* of Cypher by design, and none of these five is
      needed by a child (the client's control flow is the client's, and
      a `FOREACH` in the engine would not make the client smaller)
