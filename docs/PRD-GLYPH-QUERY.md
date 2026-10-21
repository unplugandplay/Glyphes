# PRD — GLYPH QUERY: the graph's own query language

> **Status:** proposed. Companion to
> [`PRD-GLYPH-BASIC.md`](PRD-GLYPH-BASIC.md) (the client language) and
> [`discovery.md`](../discovery.md) (the reasoning that produced both).
> The coding plan is [`PLAN-GLYPH-QUERY.md`](PLAN-GLYPH-QUERY.md).

---

## 1. What this is

**GLYPH QUERY** is a small, line-oriented query language for the graph,
served by the engine. It is the *data* language: everything that reads or
writes the graph goes through it.

It is **not** a second engine. Every GLYPH QUERY statement compiles to
Cypher — text plus parameters — and the existing Cypher interpreter,
planner and operators execute it. The engine's matching, its index
seeks, its transaction rules and its pins are untouched.

That is the whole design, and it is the design
[`discovery.md`](../discovery.md) §2 argued for: *re-implementing matching
in a new language is a second implementation of the hardest part of this
codebase*. GLYPH QUERY is a **surface**, not a second engine.

## 2. Why it exists

Three reasons, in the order they matter.

**It is shorter.** The Cypher subset is expressive but it is a *graph*:
`MATCH (a:Person)-[:KNOWS]->(b:Person) WHERE a.age > 30 RETURN b.name`.
GLYPH QUERY says the same thing as `find person where age > 30` and
`go knows`. A child can read the second one.

**It is honest about what the engine can do.** Cypher's refusals — no
joins, one label per node, no `CASE`, no `EXISTS`, no `FOREACH` — are
*features* here, because the language never asks for them. The refusals
stay where they are; GLYPH QUERY simply does not walk into them.

**It is a wire format a small machine can speak.** The eZ80 guest
(GLYPH BASIC, the second PRD) cannot parse Cypher, and does not need to:
it emits GLYPH QUERY lines over a port channel. The language being small
is what makes the guest possible.

## 3. The surface

One statement per line. No multi-line syntax, no semicolons, no brackets.

```
find [<label>] [where <expr>]          the nodes
go [<back>] <type> [from <param>] [where <expr>]   the nodes one hop away
count [<label>] [where <expr>]        how many
labels                                the labels in the graph
add <label> [{<prop> <value>}]        create a node
link <param> <type> <param>           create a relationship
set <param> <prop> = <value>          set a property
drop <param>                          delete a node
```

**The verbs and what they compile to:**

| GLYPH QUERY | Cypher |
|---|---|
| `find person` | `MATCH (n:person) RETURN id(n) AS id` |
| `find person where age > 30` | `MATCH (n:person) WHERE n.age > 30 RETURN id(n) AS id` |
| `find where name = "Ada"` | `MATCH (n) WHERE n.name = "Ada" RETURN id(n) AS id` |
| `go knows` | `MATCH (a)-[:knows]->(b) RETURN id(b) AS id` |
| `go back knows` | `MATCH (a)-[:knows]->(b) RETURN id(a) AS id` |
| `go knows from $p` | `MATCH (a)-[:knows]->(b) WHERE id(a) = $p RETURN id(b) AS id` |
| `count person` | `MATCH (n:person) RETURN count(n) AS n` |
| `labels` | the schema door (`glyphes_schema`) |
| `add person {name "Ada"}` | `CREATE (n:person {name: "Ada"})` |
| `link $a knows $b` | `MATCH (a), (b) … CREATE (a)-[:knows]->(b)` — see §5 |
| `set $n age = 36` | `MATCH (n) WHERE id(n) = $n SET n.age = 36` |
| `drop $n` | `MATCH (n) WHERE id(n) = $n DETACH DELETE n` |

**`where` takes the engine's expression syntax, unchanged.** The
expression evaluator, the three-valued logic and the type rules are the
existing ones (`docs/CYPHER.md` §2.3, §6). GLYPH QUERY adds no
expression language: `where age > 30` means exactly what it means in
Cypher, and a child's first language is therefore also their *last*
language's filter.

**Values are parameters, never text.** Every literal a client supplies
becomes a **named parameter** (`$p1`, `$p2`, …) and the compiled Cypher
carries the values in the parameter map. Nothing a client types is ever
concatenated into the query text, so the language cannot become an
injection surface — the same discipline the ABI's parameter door already
follows.

**Labels and types are exact**, as they are in the store: `find person`
does not find `Person`. The engine's rule is that an unknown label is an
empty result and never an error (pin C2), which is right for a query and
wrong for a prompt — silence reads as "there is nobody here", which is a
different fact from "there is nobody *called* person". So the *client*
is the one that can be helpful about it: it knows the labels and the
relationship types, and says "no label 'person'; the labels are: Person,
Company" instead of returning nothing. That is the client's job, not the
query layer's, and it is the difference between a language a child
trusts and one they give up on.

**Results are rows of cells**, exactly as a Cypher statement's are: the
same `GlyCell` shape, the same `glyphes_stmt_step`, the same accessors. A
GLYPH QUERY statement is a Cypher statement with a different spelling,
and the client's cell handling does not change.

## 4. The pins

| Pin | Rule |
|---|---|
| **GQ1** | **GLYPH QUERY compiles; it does not execute.** The output is Cypher text plus a parameter map, and the existing interpreter runs it. No second planner, no second operator set, no second set of pins. |
| **GQ2** | **Every GLYPH QUERY statement is one Cypher statement.** No statement expands into two, and no statement spans two. (The one exception is `link`, and it is bounded — see §5.) |
| **GQ3** | **A GLYPH QUERY statement has one result shape.** `find`/`go` return node ids; `count` returns one number; `labels` returns the label list; the write verbs return a row count. The client does not have to guess. |
| **GQ4** | **Values are parameters.** No client-supplied text is concatenated into the query. |
| **GQ5** | **The expression language is Cypher's**, including its three-valued logic, its type rules and its refusals. `where` is not a second evaluator. |
| **GQ6** | **Unknown constructs are refused by name.** `goe knows` says "unknown command 'goe'"; a bad type says which type. The engine's C1 rule, inherited. |
| **GQ7** | **A GLYPH QUERY statement is one transaction**, exactly as a Cypher statement is: a statement's reads never see its own writes (pin C4), and the client's transaction discipline is the engine's. |
| **GQ8** | **Cypher stays.** GLYPH QUERY is an addition to the engine's surface, not a replacement of its language. Nothing that speaks Cypher stops working. |

## 5. The awkward one: `link`

`link $a knows $b` needs *two* nodes bound, and Cypher refuses a
comma-`MATCH` (a cartesian product) and a second `MATCH` (a join). The
honest compilation is:

```
MATCH (a) WHERE id(a) = $a
MATCH (b) WHERE id(b) = $b
CREATE (a)-[:knows]->(b)
```

— but two `MATCH` clauses are refused (a join). So `link` is the one
construct GLYPH QUERY cannot express in one Cypher statement, and it has
three options:

1. **Refuse it.** The client links by *id* and the engine gets a new
   write door that takes two ids and a type — a real engine change, and
   a small one (the store already has `createEdge`).
2. **Compile it to a `MERGE`**: `MERGE (a)-[:knows]->(b)` with the
   endpoints bound by id — but `MERGE` creates the whole pattern or
   nothing (`docs/CYPHER.md` §0.2), so a `MERGE` whose endpoint does not
   exist would *create* it ✗ — wrong for a link.
3. **Compile it to a two-step plan inside one statement** using the
   engine's own operator set rather than Cypher text — i.e. GLYPH QUERY
   grows a second execution path ✗ (GQ1 broken ✗).

**The PRD's decision: option 1, and it is the only engine change in this
PRD.** A `glyphes_link(db, from_id, type, to_id)` door, which is two
store calls and no planner at all. It is *not* a second language's
execution path — it is one write, spelled directly.

**What the code found, and it is sharper than the PRD said.** Writing the
fixture for the client's tests made the gap plain: an edge between two
*existing* nodes cannot be created through the query language at all.
A comma-`MATCH` is a cartesian product and is refused; a second `MATCH`
is a join and is refused; and `MATCH (a) MERGE (a)-[:R]->(b {…})` does
not find the existing `b` — it *creates a second one*, because a `MERGE`
creates the whole pattern when any element fails to match. So the query
language cannot say "join these two nodes I already have", and the door
is not a convenience: it is the only spelling of that write that means
what it says. A door that refuses a missing endpoint, where `MERGE`
would create it, is the better behaviour for a language a child uses.

Everything else in GLYPH QUERY is a compiler.

## 6. What is out of scope

- **A second planner, a second operator set, a second set of pins.**
  (GQ1.)
- **New matching power.** GLYPH QUERY cannot join, cannot bind a path,
  cannot filter on a variable-length path, and does not try: those are
  the engine's refusals, and the language is built to stay clear of them.
- **Aggregates beyond `count`.** `count` is the one aggregate the engine
  folds cheaply. `sum`/`avg`/`min`/`max` exist in Cypher and are not
  missing *from the engine* — they are missing from the *first* version of
  the language, because a child's first query language should not open
  with aggregates. A later version may add `count by <label>`.
- **Transactions, schemas, index management.** Those are the engine's
  doors (`glyphes_tx_*`, `glyphes_index_*`), and the client uses them
  directly.
- **The write verbs' `where` clauses.** `set` and `drop` take one id;
  a filtered bulk write is a client loop, and the client language is
  where loops live.

## 7. The gates

| Gate | What it proves |
|---|---|
| **GQ-A** | Every GLYPH QUERY statement compiles to the Cypher the table in §3 claims, byte for byte. A golden file per statement — the same discipline the eZ80's BASIC transcript uses. |
| **GQ-B** | The compiled statements *run*, and return the same rows the hand-written Cypher returns. A differential test: for each GLYPH QUERY statement, the same query written by hand, compared row for row. |
| **GQ-C** | A client-supplied value never reaches the query text. A statement with `"Ada"; DROP"` as a value compiles to a parameter, and the compiled text contains no part of it. |
| **GQ-D** | Every refusal names the construct. A table of bad GLYPH QUERY lines and the message each produces. |
| **GQ-E** | The engine's 480 existing tests and the TCK's 132 rows are untouched — GLYPH QUERY is an addition, and pin GQ8 is proved by them still passing. |

## 8. The surface, concretely

The ABI gains three doors, mirroring the existing ones so that a client
that already handles a Cypher statement handles a GLYPH QUERY statement
with no new code:

```c
int32_t glyphes_gq_prepare(GlyHandle db, char *gq, char *params_json,
                           GlyHandle *out_stmt);
int32_t glyphes_gq_step(GlyHandle stmt, GlyCell *out_cells,
                        size_t cap, size_t *out_rows);
int32_t glyphes_gq_columns(GlyHandle stmt, char **out,
                            size_t *out_len, uint32_t *out_count);
```

and one write door for `link`:

```c
int32_t glyphes_link(GlyHandle db, int64_t from_id, char *type,
                     int64_t to_id);
```

The compile step itself is also exposed, because it is the useful part
for a client that wants to show or log what it will run:

```c
int32_t glyphes_gq_compile(char *gq, char *params_json,
                            char **out_cypher, char **out_params);
```

## 9. The risk, stated

**GLYPH QUERY could be a toy veneer over Cypher.** The defence is that
it is not a *different* thing pretending to be a language: every claim
it makes is checked by a differential gate (GQ-B) against the hand-written
Cypher, and its value — for a child, and for the eZ80 guest — is
measured in *words typed*, not in features. If a GLYPH QUERY statement
ever needs a Cypher feature the engine does not have, the answer is to
add the *engine* feature, not to grow the language.

**The other risk is that it never gets used** because the existing
Cypher surface is already good enough for the people who have it. That
is a *product* risk, not a technical one, and the honest answer is that
GLYPH QUERY is aimed at people who are not the current users.
