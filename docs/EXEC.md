# glyphes — EXEC: the pull pipeline

> **Status:** specification for M5. Normative. Companions:
> `CYPHER.md` (what to run), `INDEX.md` (the scanning operators),
> `TXN.md` (writes), `STORAGE.md` (the records).

This specifies the execution model, the operator set, the planner rules,
and the memory contract. The central decision is PRD pin P6: **pull-based
volcano operators, materialization forbidden except in `Sort`.**

---

## 0. Why this shape, and why it is not reversible

A pull (iterator) model means each operator produces rows on demand, one
at a time, holding only a cursor into its child. A push or materialize
model means an operator produces a whole result set, and its parent
consumes it.

The difference in codebase size is the whole project. Materializing at
operators requires: an intermediate-result abstraction, memory
accounting, a spill-to-disk path per materializing operator, and
lifetime rules for when buffers are freed. The pull model needs none of
that — an operator holds a cursor, and memory is bounded by the number of
live cursors, which equals the query depth.

It also gives short-circuiting for free. `LIMIT 10` never pulls an 11th
row. `MATCH (a)-[:KNOWS]->(b) RETURN a LIMIT 10` pulls 10 edges, not 10⁶.
`WHERE` before `ORDER BY` means the sort sees filtered rows only. Every
one of those is free in pull and requires explicit machinery in push.

**In practice this is a one-way door.** Operators that materialize can be
added later; a push-based plan cannot be converted back to pull without
rewriting the whole layer. So the rule is enforced at review, not at
runtime: a new operator that buffers a whole child result to answer one
call is a design failure, and the only permitted buffer is `Sort`'s.

---

## 1. Operator interface

```nim
type
  Operator = ref object of RootObj
    init(ctx: QueryCtx): OpStatus      # plan-time, may throw/skip
    next(): bool                       # pull one row; sets cursor state
    close()                            # release resources
    columns(): seq[string              # output schema (arity)
```

Two entry points, not one. `init` runs once per execution and returns
`OpSkip` when the operator is eliminated by the planner (constant
folding, an empty `LIMIT 0`, an unsatisfiable `WHERE`) — skipping at init
rather than returning zero rows keeps the fast path free of per-row
checks.

`next` returns `true` when the cursor is valid. Row values are read from
the operator's own slots, which are borrowed arena memory owned by the
statement (`ABI.md` B3). An operator must not retain a child cursor after
its own `next` returns.

Every operator is **single-use**: `init` once, then `next` until `false`.
Re-executing a plan re-runs `init`. There is no reset, no rewind, and no
`next` after `false` — a query that needs to iterate twice gets a second
execution, and the planner is responsible for knowing when that is
required (`WITH` after an aggregation, for example).

---

## 2. Operator set

Complete for the §2–§4 contract of `CYPHER.md`.

### 2.1 Scans

| Operator | Produces | Notes |
|---|---|---|
| `ScanAll` | every live node | the fallback; no index |
| `ScanByLabel` | nodes in one label's id list | the label index (`STORAGE.md` §4.3) |
| `IndexSeek` | nodes matching one property predicate | range / text / vector; `INDEX.md` |
| `AllNodes` | every live edge | for `MATCH ()-[r]->()` |

`ScanAll` walks the node array by id, skipping tombstones. It holds the
generation and re-reads `nodes[id]` per step, so a concurrent commit is
invisible (rule: operators hold ids, never pointers, `STORAGE.md` §6).

`ScanByLabel` walks a snapshot of the label's id list. Deletion during a
scan cannot mutate the list, so the cursor is safe; a node tombstoned
mid-scan is filtered at read time, and the list is not compacted until
checkpoint.

### 2.2 Traversal

| Operator | Semantics |
|---|---|
| `Expand` | all edges of a type (or any type) out of one bound node, or in |
| `ExpandVar` | variable-length: one operator per hop count, concatenated |
| `LeftOuterExpand` | `OPTIONAL MATCH`; emits the bound node with `null` on no match |
| `EndNode` / `StartNode` | the other endpoint |
| `PathProject` | builds a `GLY_PATH` cell from accumulated nodes/edges |

`Expand` is where degree pruning belongs: with a degree hint from
`out_count`/`in_count` (`STORAGE.md` §2.1) the planner can decide a
traversal is a full scan before running it.

`ExpandVar` for `*1..3` is three `Expand` instances whose outputs are
concatenated — a union, not a chain, because each is a distinct path
length. Because the pull model makes this lazy, `*1..100` with `LIMIT 10`
pulls ~10 hops, not 100.

### 2.3 Row shaping

| Operator | Semantics |
|---|---|
| `Filter` | boolean predicate per row |
| `Project` | expression evaluation into named columns |
| `Alias` | rename / reorder; folds into `Project` |
| `Distinct` | hash on the projected columns |
| `Sort` | ordered output; **the only buffering operator** |
| `Skip` / `Limit` | count and truncate |
| `Unwind` | one row per list element |
| `Aggregate` | group-by hash table, or global when no keys |

### 2.4 Writes

| Operator | Semantics |
|---|---|
| `CreateNode` / `CreateEdge` | append to the delta |
| `MergeNode` / `MergeEdge` | match-then-create, `ON CREATE`/`ON MATCH` actions |
| `SetProp` / `RemoveProp` / `SetLabel` | delta mutation |
| `DeleteNode` / `DeleteEdge` / `DetachDelete` | tombstone + unlink |
| `EagerWrite` | materializes its input |

**`EagerWrite` is the one exception to the no-materialization rule, and
it is not really one.** A Cypher statement's write phase sees a snapshot
of all rows the read phase produced (rule 2 of `CYPHER.md` §1), so a
write operator *must* fully consume its input before the first write
lands — otherwise it would see rows that its own writes changed. So
`EagerWrite` buffers the input row-ids, then applies writes. It buffers
**ids and scalar property values only** — never a materialized result
set, never a nested join — and its memory is bounded by
`max_result_rows`. This is the documented, bounded cost of read/write
ordering, and it is why that ordering rule exists.

### 2.5 Index operators

| Operator | Semantics |
|---|---|
| `VectorScan` | filtered HNSW traversal; `YIELD node, score` |
| `TextScan` | inverted-index query + BM25; `YIELD node, score` |

Both are `IndexScan` subclasses with the same interface, so the planner
treats them as ordinary scans and every downstream operator is
unaffected. This is the hybrid-retrieval mechanism (`CYPHER.md` §4).

---

## 3. The plan shape

```
   ScanByLabel ──┐
   IndexSeek ────┤
   ScanAll ──────┼──▶ Filter ──▶ Expand ──┬──▶ Filter ──▶ Project ──┐
   VectorScan ───┤                        │                         │
   TextScan ─────┘                        └──▶ ExpandVar ──────────┤
   AllNodes ─────┤                                              │
   Unwind ───────┘                                              │
                                                               ▼
                              ┌──────────────┐   ┌──────────────────────────┐
                              │ Aggregate    │   │ Sort ──▶ Skip ──▶ Limit  │
                              └──────┬───────┘   └────────────┬─────────────┘
                                     ▼                        ▼
                              Project ────────────────▶ EagerWrite ──▶ RETURN
```

Two plan forms, and only two:

**Streaming.** Every operator is a pass-through pull chain. Zero
intermediate buffers. Memory O(depth).

**Aggregating.** `Aggregate` or `Sort` terminates the streaming chain and
buffers. Memory O(groups) or O(rows), and `Sort` spills past
`max_sort_bytes`.

The planner picks between them structurally: does the query contain an
aggregate, a `DISTINCT`, or an `ORDER BY`? If yes, aggregating form. If
no, streaming. There is no hybrid, and no partial buffer.

---

## 4. The planner

No cost model, no cardinality estimation, no join reordering (PRD pin
P7). A rule set, ~300 lines, evaluated per node pattern.

### 4.1 Node pattern → scan operator

Evaluated in order, first match wins:

| # | Rule | Operator |
|---:|---|---|
| 1 | Label has ≥ 32 members | `ScanByLabel` |
| 2 | Label + equality on an indexed property | `IndexSeek` |
| 3 | Indexed property with `=`, `<`, `<=`, `>`, `>=`, `IN` | `IndexSeek` |
| 4 | `CALL db.idx.vector/text` on this variable | `VectorScan` / `TextScan` |
| 5 | otherwise | `ScanAll` |

Rule 1 before rule 2 is deliberate: a label index is a contiguous array
scan, which beats an index seek that resolves to the same set. The 32
threshold is empirical; below it the label array is small enough that
scanning beats seeking, above it the seek's selectivity pays off.

For a conjunctive `WHERE` with two indexed predicates, **no selectivity
estimation** is done. The first predicate in source order wins. A
cost-based planner would pick the more selective one; without
cardinalities we cannot know which that is. Pinned as a known weakness
with a phase-2 remedy (`ANALYZE`, then costing).

### 4.2 Expand direction

`Expand` direction is chosen by which endpoint is already bound:

| Bound | Pattern form | Operator |
|---|---|---|
| `a` | `(a)-[r]->(b)` | `Expand` out of `a` |
| `b` | `(a)<-[r]-(b)` | `Expand` in of `b` |
| both | `(a)-[r]-(b)` | prefer the side with lower degree |
| neither | `(a)-[r]->(b)` | `ScanAll` then `Expand` both |

Preferring the lower-degree side is the one piece of costing in the
planner, and it is free: degree is already maintained eagerly
(`STORAGE.md` §2.1). It is the difference between an O(degree) and an
O(N) start for the unbound case.

### 4.3 Predicate placement

Predicates are pushed to the operator that evaluates them cheapest, in
this order:

1. A predicate referencing only variables bound *before* it moves to the
   earliest operator where that holds.
2. A predicate fully constraining a node's properties joins that node's
   scan as an inline filter.
3. What remains sits after the last binding it needs.

`WHERE` after a `MATCH` that binds three patterns can therefore execute
partially inside the first scan, which is the common case for the
selective query people actually write.

### 4.4 Elimination

At plan time, constant-folded away:

- `LIMIT 0` → `OpSkip` on the whole plan
- `WHERE false` → `OpSkip`
- `1 = 2` → `OpSkip`
- `WITH` projections not used downstream → dropped from the projection
- An unused `RETURN` alias → dropped
- `OPTIONAL MATCH` with no right-side pattern → dropped

Rule 4 and 5 matter more than they look: they are what keeps
`RETURN a.name, a.age` from evaluating expressions nobody reads.

### 4.5 `OPTIONAL MATCH`

`LeftOuterExpand`, with the right-side pattern planned normally and its
rows buffered per left row. The buffer holds one left row's matches, so
memory is O(matches per left row), not O(total).

This is the one place a per-row buffer exists, and it is unavoidable:
left-outer semantics cannot be evaluated without knowing whether the right
side produced anything for that row. Bounded, documented, and not the
general materialization this document forbids.

---

## 5. Memory contract

| Operator | Memory |
|---|---|
| All scans, `Expand`, `Filter`, `Project`, `Limit`, `Skip` | O(1) |
| `Aggregate` (no `GROUP BY`) | O(1) |
| `Aggregate` with `GROUP BY` | O(distinct groups) |
| `Distinct` | O(distinct rows) |
| `Sort` | O(rows), spilling past `max_sort_bytes` |
| `ExpandVar` | O(1) per hop count |
| `EagerWrite` | O(rows in the read phase) |
| `LeftOuterExpand` | O(matches per left row) |

Total worst case: `O(groups + sort buffer + read-phase rows)`, all three
capped by budgets (`TXN.md` §6). `Sort` is the only operator with a
spill path, and it spills by writing sorted runs to a temp file and
k-way merging them — the standard external sort, ~200 lines, used only
when a query actually orders more than 256 MB.

**`Sort` must not be skipped for optimization.** The tempting change —
"push `LIMIT 10` into a top-N sort" — is real and valuable, and it is
phase 2. In 0.1 the sort buffer is capped and spills; that is correct and
boring, which is the point.

---

## 6. Cancellation and budgets

Budget checks (`TXN.md` §6) at operator boundaries, not per row:

- `init` checks `max_query_ms` and `max_txn_ops`.
- `Aggregate` and `Sort` check `max_result_rows` per group / per row
  inserted.
- `EagerWrite` checks `max_result_rows` per buffered row.

A budget trip returns `GLY_ERR_LIMIT` from the `next` that crossed it.
Partial work inside the transaction is **not** rolled back — the caller
decides, matching `TXN.md` §6.

No query cancellation API in 0.1: there is no separate thread to signal,
so cancellation would mean a flag check per row, which is the per-row
check this document avoids everywhere else. Ruby can abandon a statement
by closing its handle; the engine notices at the next boundary.

---

## 7. Concurrency

One execution per `stmt` handle. Operators hold no shared mutable state,
so two statements over the same database are independent — the only
shared thing is the read-only store plus the generation counter, both
read without a lock.

A statement's operators read from the arrays of the generation captured
at `prepare`. A concurrent commit swaps array references; a running
operator re-indexes by id per step and therefore never touches the new
arrays (`STORAGE.md` §6). This is why the pipeline needs no MVCC inside
the executor.

`EagerWrite` is the exception: it holds a write transaction, so
concurrent `tx_begin` gets `GLY_ERR_BUSY`. That is the entire concurrency
story for the executor.

---

## 8. EXPLAIN

Not in the Cypher surface (`CYPHER.md` §5 rejects it). Exposed as
`glyphes_schema` / a debug-only `glyphes_explain(db, cypher, json_out)`
for development builds. Rationale: `EXPLAIN` in Cypher would need the
planner's cost strings to be stable public API, and a cost model is
exactly what 0.1 does not have.

---

## 9. Gates

| # | Gate |
|---|---|
| E1 | Every operator is O(1) memory except the six listed in §5 |
| E2 | `LIMIT 10` over a 10⁶-row traversal returns in < 2 ms (pull-model proof) |
| E3 | `Sort` of 10⁷ rows spills to disk and completes correctly |
| E4 | `ExpandVar` `*2..` over a 3-cycle terminates and is relationship-unique per path |
| E5 | A concurrent writer during a read never changes what a running statement returns; assert one generation per statement |
| E6 | `LeftOuterExpand` with no match yields exactly one row with `null`, not zero rows |
| E7 | Predicate pushdown verified by operator-shape assertions: a selective `WHERE` on the first pattern plans into that scan |
| E8 | Constant folding: `LIMIT 0`, `WHERE false`, unused projections all skip at `init` |
| E9 | All 5 budgets trip from inside the pipeline and return `GLY_ERR_LIMIT` |
| E10 | `UNWIND` over a 10⁷-element list with `LIMIT 10` consumes 10 elements |

E2 is the gate that justifies the whole architecture. E10 catches the
most likely regression: someone "optimizing" `Unwind` by pre-sizing.

---

## 10. Pins

| # | Pin |
|---|---|
| E1 | Volcano pull model. `init` once, then `next` until false. Single-use |
| E2 | Materialization is forbidden except `Sort`, `EagerWrite`, and `LeftOuterExpand` |
| E3 | Operators hold ids, never pointers into record arrays |
| E4 | Two plan forms only: streaming and aggregating. No hybrid |
| E5 | Greedy planner, source-order predicate choice, no cost model |
| E6 | Expand direction picks the lower-degree side, using the eagerly-maintained degree |
| E7 | Eliminations happen at plan time via `OpSkip`, not per-row checks |
| E8 | `Sort` is the only operator with a spill path; no top-N optimization in 0.1 |
| E9 | Budgets checked at operator boundaries, never per row |
| E10 | Queries are single-threaded; operators hold no shared mutable state |
| E11 | `EXPLAIN` is not Cypher in 0.1; it is a debug ABI call |
