# PLAN — GLYPH QUERY: the coding plan

> Companion to [`PRD-GLYPH-QUERY.md`](PRD-GLYPH-QUERY.md). The plan for
> the client language is [`PLAN-GLYPH-BASIC.md`](PLAN-GLYPH-BASIC.md).
>
> **The order matters and it is not the obvious one.** GLYPH BASIC
> compiles *to* GLYPH QUERY, so GLYPH QUERY lands first — but the
> *grammar* of GLYPH BASIC is written first, on paper, because it is the
> part that is hard to change later. The engine work underneath is
> untouched except for the two doors in §5.

---

## 1. The shape of the work

| # | Cut | What it delivers | Gate |
|---|---|---|---|
| **Q1** | the grammar, on paper | the statement table, the compilation table, the refusal table | a review, not a test |
| **Q2** | the compiler | GLYPH QUERY text → Cypher text + parameters | GQ-A |
| **Q3** | the doors | `glyphes_gq_prepare` / `_step` / `_columns` / `_compile` | GQ-B, GQ-D |
| **Q4** | `link` | the one write door GLYPH QUERY cannot express | GQ-B |
| **Q5** | the whole surface | `labels`, the write verbs, the refusal table | GQ-C, GQ-E |

## 2. Q1 — the grammar, before the code

A page, in `docs/`, that fixes:

- the **statement table**: every GLYPH QUERY statement, its operands and
  its compiled Cypher (the PRD §3 table is the draft; this is the
  version that gets coded);
- the **value rules**: what a literal may be (a number, a string, a
  parameter reference `$name`), and how each becomes a parameter;
- the **refusal table**: every malformed statement and the message it
  produces, so the messages are written before they are needed;
- the **expression rule**: `where` takes the engine's expression syntax
  unchanged, and the *boundary* is drawn exactly — the GLYPH QUERY lexer
  stops at the first token the expression lexer would not accept, and
  the rest is handed to the engine verbatim.

**Why this cut is first and not later:** the language is the thing that
is hard to change. The compiler is easy to change; a grammar that
children have learned is not.

## 3. Q2 — the compiler

New module `src/gq/`:

| File | What it holds |
|---|---|
| `src/gq.nim` | the whole compiler: the lexer (the engine's, borrowed), the parser, the compiler, and the public entry `compileGq*(text): GqProgram` |

It is one file rather than five, because the language is small: the
statement kinds are `Find`, `Go`, `Count`, `Labels`, `Add`, `Link`,
`Set` and `Drop`, and the only interesting part is the `where` rewrite
and the parameter discipline.

**The compiler's one hard rule: it never concatenates a value into the
text** (pin GQ4). A literal becomes a parameter; a *label* or a
*relationship type* is not a value — it is part of the pattern — and it
is checked against the identifier rules before it goes in. A type name
that is not a plain identifier is refused, which is what makes the
concatenation safe.

**The `where` boundary.** The GLYPH QUERY lexer reads `where`, then hands
the *rest of the line* to the engine's expression machinery unchanged.
That is the trick that keeps GQ5 true without writing a second
expression evaluator: GLYPH QUERY does not parse expressions at all; it
finds the keyword and passes the remainder through.

**The parameter map.** Every literal becomes `$p1`, `$p2`, … in the
order the values were read, and the values go into the parameter map
the engine already has. A client that wants its own names supplies them
through the same door.

## 4. Q3 — the doors

`src/glyphes.nim` gains three exports, mirroring the Cypher ones so that
a client handles both statement kinds with one code path:

```c
int32_t glyphes_gq_prepare(GlyHandle db, char *gq, char *params_json,
                           GlyHandle *out_stmt);
int32_t glyphes_gq_step(GlyHandle stmt, GlyCell *out_cells,
                        size_t cap, size_t *out_rows);
int32_t glyphes_gq_columns(GlyHandle stmt, char **out,
                            size_t *out_len, uint32_t *out_count);
int32_t glyphes_gq_compile(char *gq, char *params_json,
                            char **out_cypher, char **out_params);
```

`glyphes_gq_prepare` is `glyphes_prepare` with the compile step in
front. The statement it produces is a *Cypher statement* — the same
`Statement` type, the same cells, the same `glyphes_stmt_*` accessors —
so the ABI's guarantees are inherited rather than re-stated.

**The `glyphes_gq_compile` door is the interesting one**, and it exists
for the client: a client that wants to show or log what it will run
needs the compiled text, and the *guest* client needs it more (it sends
the GLYPH QUERY line and the host compiles it — so the guest never
needs the compiler at all ✓✓, which is the point ✓).

**What the doors look like as shipped.** The sketch above had
`char **out_cypher`; the shipped ones use the **caller-allocated
buffer with a size-predicting retry** — the convention the schema door
already uses and the header's settled decision (ABI.md §7). Two
answers, two lengths: the Cypher text and the parameters, because they
answer two questions ("what will run" and "with what"). The `_step`
and `_columns` doors are the statement doors' own implementation under
the GLYPH QUERY names: the handle is the same statement handle, but a
client that knows only the child's language should not have to learn
the engine's names to read its rows.

Two refusals the doors make by name, both worth their keep: `labels`
and `link` are not queries (`labels` is the schema door and `link` is
`glyphes_link`), and a parameter that collides with the compiler's own
`$p1` is refused rather than silently overwritten.

## 5. Q4 — `link`, the one engine change

`glyphes_link(db, from_id, type, to_id)`:

- looks both nodes up (refusing a missing one **by name** ✓);
- creates the edge (the **transaction's** `createEdge` ✓ — no planner,
  no statement);
- returns the new edge's id.

**One deviation from the plan above, and it is the whole point of the
plan's own rules.** The sketch said the store's `createEdge` — and the
store's `createEdge` never reaches the log, so an edge written that
way is a memory that a restart forgets. The client found this the hard
way (the GLYPH BASIC door's link, PRD-GLYPH-BASIC.md §3), and the
door here goes through the transaction for the same reason: an edge
that a restart forgets is not an edge.

It is a *write door*, and it obeys the same transaction discipline as
every other write (`docs/TXN.md` ✓): it joins an open transaction or
starts one ✓.

**Why not compile `link` to Cypher:** the PRD §5 says why — the engine
refuses two `MATCH` clauses (a join) and a comma-`MATCH` (a cartesian),
and `MERGE` would *create* a missing endpoint instead of refusing it.
One write door is smaller and more honest than a second execution path.

## 6. Q5 — the rest of the surface

- `labels` → the schema door (`glyphes_schema` ✓), rendered as the
  client's list.
- `add`, `set`, `drop` → compiled to `CREATE` / `SET` / `DETACH DELETE`
  ✓ — with the *values* as parameters ✓.
- The **refusal table** → a test per row (GQ-D) ✓.

## 7. The tests

New file `tests/unit/test_gq.nim`, in the existing suite:

| test | what it holds |
|---|---|
| the compilation golden | every statement in the table compiles to the exact Cypher the table claims (GQ-A) |
| the differential | the compiled statement returns the same rows as the hand-written Cypher, over a fixture with labels, properties, edges in both directions, and a node with no edges (GQ-B) |
| the parameter discipline | a value containing a quote and a semicolon compiles to a parameter, and the compiled text does not contain it (GQ-C) |
| the refusals | every bad line produces the message the table names (GQ-D) |
| the doors | the compile door returns the Cypher and the parameters, and its cap protocol reports the length first; the prepare door returns the same rows as the hand-written query; `labels` and `link` are refused by name; the link door writes an edge that survives a reopen, refuses a missing endpoint by name, and joins an open transaction |
| the existing suite | the 480 tests and the TCK's 132 rows still pass — GQ8 (GQ-E) |

The differential test is the one that matters: it is the same shape as
the eZ80's golden transcript ✓ — *the same work, two ways, compared* ✓.

## 8. The order of the cuts, and why

Q1 → Q2 → Q3 → Q4 → Q5, with the grammar frozen after Q1.

The temptation is to start at Q3 (the doors) because it is the visible
part. The reason not to: the doors are the easy part ✓, and the grammar
is the part every other piece has to agree with ✓ — the BASIC client
(compiled separately) will be written against it ✓, and the eZ80 guest
will be written against it ✓✓. A grammar that changes after the client
exists costs two rewrites; a grammar that changes before it exists
costs one document ✓.

## 9. What this plan does not cover

- The **eZ80 guest** (a cut of its own, in
  [`PLAN-GLYPH-BASIC.md`](PLAN-GLYPH-BASIC.md) §5) ✓.
- The **client** ✓ (that plan) ✓.
- **Aggregates, functions, a `while`** — deliberately absent (the PRD
  §6) ✓.

## 10. The definition of done

- [ ] the grammar page is written and reviewed (Q1) ✓
- [ ] `glyphes_gq_compile` compiles every statement in the table to the
      claimed Cypher, and the golden file is checked in (Q2, GQ-A) ✓
- [ ] `glyphes_gq_prepare` / `_step` / `_columns` exist, and a client
      handles a GLYPH QUERY statement with the same cell code as a
      Cypher one (Q3) ✓
- [ ] `glyphes_gq_compile` compiles without running, and a client can
      see what will run before it runs (Q3) ✓
- [ ] the differential test passes over the fixture (Q3, GQ-B) ✓
- [ ] `glyphes_link` writes one edge, refuses a missing endpoint by
      name, and obeys the transaction discipline (Q4) ✓
- [ ] every refusal in the table is produced by the code (Q5, GQ-D) ✓
- [ ] the 480 existing tests and the TCK still pass (Q5, GQ-E) ✓
- [ ] `docs/ABI.md` and `docs/CYPHER.md` record the new doors ✓
- [ ] the header in `docs/ABI.md` is the *real* header (`src/glyphes.h`),
      not a copy that has drifted from it ✓
