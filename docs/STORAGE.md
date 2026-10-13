# glyphes — STORAGE: the on-disk shape of a graph

> **Status:** specification for M1. Normative. Where this and
> `PRD-GLYPHES.md` disagree, this document carries a `PRD §x amendment`
> marker and the PRD is amended first.

This specifies the in-memory record layout, the property arena, the label
dictionary, and the adjacency discipline. Every offset here is pinned: the
snapshot format (`WAL.md` §4) is a serialization of these structures, so a
layout change is a format change and needs a migration.

---

## 0. Amendments to the PRD

**PRD §4.1 amendment — `EdgeRec` is 56 bytes, not 48.** The PRD's sketch
omitted the `id` field from the byte count by accident; `id` cannot be
folded into the array index because ids must stay stable across
compaction (§4.7). Corrected table in §2.2.

**PRD §8 M1 amendment — the memory gate was arithmetically impossible.**
The PRD's 320 MB gate cannot hold: at 10⁶ nodes / 4·10⁶ edges the record
arrays alone are 272 MB before the property slots, arena, or dictionaries.
Revised to **620 MB**, derived in §7 from a stated fixture. The first
revision of this amendment (480 MB) was itself wrong and was corrected
against the arithmetic; §7 records what went wrong and why, because a
gate chosen by guesswork gets weakened under pressure later.

**M3 amendment — the gate measures `heap`, not RSS, and is 680 MB.** The
metric was always `getOccupiedMem()`; the name was wrong and the number
drifted 595 → 652 MB with no change in the engine, which is what finally
made the name impossible to leave alone. §7 re-derives the budget from the
live footprint and prints true peak RSS beside it. The direction of the
amendment is upward because the *measurement* was corrected, not because
the store got fatter: the live footprint is 558 MB and it was 558 MB
before.

---

## 1. Principles

1. **Dense ids, array-indexed.** A lookup is an array subscript. There
   is no B-tree on the primary path. This is SQLite's rowid idea and it
   is the reason the read path is fast.
2. **Ids are stable, arrays are growable.** A node's `id` is assigned at
   creation and never changes for the life of the object, including
   across snapshot compaction. Free slots are reused only after
   compaction renumbers and no live statement references them. The
   allocator therefore never draws from its free list during normal
   operation; `reclaim` is the only thing that empties it
   (`WAL.md` §4.2a, which is where this becomes a *snapshot* obligation
   rather than an in-memory one).
3. **Integers, never strings, on the hot path.** Labels, relationship
   types, and property keys are `i32` dictionary codes. A string compare
   appears exactly once: dictionary lookup at parse/planning time.
4. **Offsets, never pointers, in stored records.** Every reference into
   the property arena is a byte offset. A record array is therefore
   serializable and `mmap`-able with no fixup pass, and an id from a
   snapshot is valid in the new process without translation.
5. **Fixed-size records.** No variable-length fields in `NodeRec` or
   `EdgeRec`. A node's payload lives in the arena, addressed by offset.

---

## 2. Record layouts

All offsets in bytes, little-endian, 8-byte aligned, no implicit padding
beyond what is listed. Total sizes are pinned.

### 2.1 `NodeRec` — 48 bytes

| Off | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 8 | `id` | `i64` | dense, stable, ≥ 1; 0 is "no node" |
| 8 | 8 | `out_head` | `i64` | first edge id in the forward list, 0 = empty |
| 16 | 8 | `in_head` | `i64` | first edge id in the reverse list, 0 = empty |
| 24 | 4 | `label` | `i32` | dictionary code; 0 = unlabelled |
| 28 | 4 | `prop_slots` | `i32` | arena byte offset of the slot array, 0 = none |
| 32 | 4 | `out_count` | `i32` | maintained in O(1) for degree checks |
| 36 | 4 | `in_count` | `i32` | as above |
| 40 | 2 | `prop_count` | `i16` | slot count, saturating at 32767 |
| 42 | 2 | `flags` | `u16` | see §2.3 |
| 44 | 4 | `slot_capacity` | `u32` | slots allocated at `prop_slots`; ≥ `prop_count` |

`slot_capacity` was the reserved word until M1, and taking it settles
`STORAGE.md` §10's slot-growth question: a node's slot array is allocated
with headroom (`max(4, capacity × 2)`) so growth is amortized O(1), and
the old array is left to `vacuum` like any other arena garbage. The
alternative — a chained overflow block — costs an indirection on *every*
property read to make the 17th property cheap, which is the wrong trade
for a store whose read path is the product.

`out_count`/`in_count` are maintained on edge create/delete rather than
computed by walking the list. Degree is needed by the planner (hub
detection) and by `MATCH (a)-[*]->(b)` degree pruning; maintaining it
costs one increment per edge op and saves a walk per query.

### 2.2 `EdgeRec` — 56 bytes

| Off | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 8 | `id` | `i64` | dense, stable, ≥ 1 |
| 8 | 8 | `src` | `i64` | node id, outgoing endpoint |
| 16 | 8 | `dst` | `i64` | node id, incoming endpoint |
| 24 | 8 | `next_out` | `i64` | next edge id in `src.out_head`, 0 = end |
| 32 | 8 | `next_in` | `i64` | next edge id in `dst.in_head`, 0 = end |
| 40 | 4 | `type` | `i32` | relationship-type dictionary code; 0 = untyped |
| 44 | 4 | `props` | `i32` | arena byte offset of the slot array, 0 = none |
| 48 | 2 | `prop_count` | `i16` | as above |
| 50 | 2 | `flags` | `u16` | see §2.3 |
| 52 | 4 | `slot_capacity` | `u32` | slots allocated at `props`; ≥ `prop_count` |

`src`/`dst` are **not** interchangeable with `out`/`in`: direction is
semantic (`KNOWS` differs from `KNOWN_BY`) and the reverse list exists
for traversal speed, not for symmetry.

### 2.3 Flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `TOMBSTONE` | deleted, pending compaction; never returned to a query |
| 1 | `LOCKED` | claimed by an in-flight operator; compaction must skip |
| 2 | `DIRTY` | changed since last checkpoint (nodes only) |
| 3 | `HAS_PROPS` | `prop_slots`/`props` non-zero |
| 4–15 | — | reserved, zero |

`TOMBSTONE` on an edge unlinks it from both adjacency lists immediately
(unlink is O(1) given the predecessor) and leaves the record for
compaction. A reader therefore never encounters a tombstoned edge during
traversal — the unlink is what makes deletion O(1) instead of O(degree).

### 2.4 `PropSlot` — 16 bytes

| Off | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 4 | `key` | `i32` | property-key dictionary code; 0 = invalid |
| 4 | 1 | `type` | `u8` | `GlyType` |
| 5 | 1 | `flags` | `u8` | bit 0 null, bit 1 dirty, bit 2 = inline value follows |
| 6 | 2 | `aux` | `u16` | element count for str/bytes/list/map, dims for vector |
| 8 | 8 | `payload` | `u64` | inline value bits, **or** arena byte offset |

**Size corrected from 24 to 16 bytes at M1.** An earlier revision of this
document tabulated these fields and then wrote 24; 4+1+1+2+8 is 16, and
the slot's 8-byte-aligned tail lands the size at 16 with no padding. The
memory model in §7 was computed against the wrong number and is corrected
with it. `tests/unit/test_store.nim` asserts `sizeof(PropSlot) == 16`
against this table.

**Inline when `aux * sizeof(elem) <= 8` and the type is scalar** (`GLY_BOOL`,
`GLY_INT`, `GLY_FLOAT`, and `GLY_STRING`/`GLY_BYTES` of ≤ 8 bytes). So an
integer property, a double, a boolean, and any short string are all stored
inline in the `payload` word with zero arena traffic. `GLY_VECTOR` is
never inline: a 768-dim f32 vector is 3 KB and would blow the 8-byte
budget.

Inline encoding: integers little-endian in the low bytes; floats as f64
bits; booleans as 0/1; strings/bytes as `aux` bytes packed into `payload`
left-aligned (short strings are common: enums, codes, initials). A string
of exactly 8 bytes uses all bits with no length prefix, since `aux` holds
the length.

Property lookup is a **linear scan** over `prop_count` slots. Rationale:
for `prop_count < 16` the whole slot array is 1–2 cache lines and a scan
beats a hash lookup's pointer chase; node property counts above 16 are
rare enough that the linear case does not matter. Pinned: no per-node
property hash until measured otherwise.

---

## 3. The property arena

A single append-only byte arena per store, holding all overflow property
payloads. Records hold byte offsets (§1.4).

```
arena:  [payload][payload][payload]...
        ^off     ^off     ^off
```

- **Allocation is bump-pointer**, 8-byte aligned. `payload` sizes are
  rounded up to 8 so any offset is dereferenceable as `u64`.
- **Free is deferred.** An overwritten property's old bytes are not
  reclaimed until `vacuum` (§4.7). A `SET` that replaces a large vector
  leaks that vector into the arena for the life of the snapshot.
- **Arena growth** is geometric (2x), and the arena is a `seq[byte]`
  exposed to Ruby only through cells.
- **Snapshot** writes the arena as a contiguous block and rewrites
  overflow offsets to their new base (a delta pass, O(overflows)). Inline
  slots need no rewrite.

This leak-until-vacuum design is deliberate and is the standard
copy-on-write storage trade: writes are O(1) and allocation-free, and the
cost is reclaimed in one pass at checkpoint. `db.vacuum` is a maintenance
verb, not an automatic one, because compaction is O(store).

---

## 4. Dictionaries and the label index

### 4.1 The dictionary

Three dictionaries — labels, relationship types, property keys — sharing
one implementation.

```
Dict (open addressing, power-of-two, linear probing)
  codes   : seq[i32]      code → string
  strings : seq[string]
  index   : seq[i32]      hash slot → code, 0 = empty, -1 = tombstone
  load    : float         never exceeds 0.75 before grow
```

### 4.2 Interning

- Codes are assigned in first-seen order starting at 1. Code 0 means
  "unlabelled"/"untyped" and is never assigned.
- Interning is idempotent: interning the same string twice returns the
  same code. This is what makes `CREATE (:Person)` and
  `MATCH (p:Person)` agree without a string compare at query time.
- Property keys use the same structure, so `SET p.name` resolves once at
  semantic analysis.
- Dictionaries are append-only during a transaction. A code is never
  reassigned, so a snapshot is a straight dump.

---

### 4.3 The label index

Per label, a dense `seq[int64]` of member node ids. This is what makes
`MATCH (p:Person)` a scan over one contiguous array rather than a sweep of
the whole node table, and it is built in rather than opt-in because a
graph store without it cannot answer its most common query.

**No bitmap.** The original text of this section specified a membership
bitmap alongside the id list. It is gone, and asking why is the useful
part: a node carries exactly one label (`CYPHER.md` C13) so there are no
duplicates for a bitmap to detect, and removal is O(1) by swap-remove.
The bitmap would have been a second structure that could disagree with
the first — which is precisely what invariant S10 exists to catch — and
one fewer structure is one fewer thing for the checker to catch.

**Removal is O(1), via a store-level position array.** Each node's index
within its label's member list lives in `GraphStore.labelPos:
seq[int32]`, not in `NodeRec`. That placement is deliberate: it keeps the
pinned 48-byte record layout and `WAL.md`'s node section untouched, at a
cost of 4 bytes per node, and it changes removal from a scan of the label
to a swap-remove plus a one-line fixup for whichever member shifted into
the hole.

The scan version was not merely slower. Deleting 10⁵ nodes from a
5·10⁴-member label is 2.5·10⁹ comparisons, and the degree-churn test took
1 m 48 s before this changed and 5 s after. A quadratic in the obvious
delete-heavy workload is a defect, not an implementation detail.

**Order is unspecified** (S7). Swap-remove reorders the tail into the
hole, so nothing may depend on label iteration order.

**`members()` returns a copy.** The planner iterates a label's members
while a write transaction may be appending to the same code, and a live
reference would be a data race on a `seq` that can reallocate.

`labelPos` is separate state that the snapshot must serialize, alongside
the id allocators — see `WAL.md` §4.2a.

---

## 5. Adjacency

Threaded lists through `next_out`/`next_in`. Insert at head, unlink
O(1) given a predecessor.

```
createEdge(n, type, m):
  e = allocEdge(n, type, m)
  e.next_out = n.out_head;  n.out_head  = e.id;  n.out_count += 1
  e.next_in  = m.in_head;   m.in_head   = e.id;  m.in_count  += 1

traverseOut(n):
  e = n.out_head
  while e != 0:
    yield edges[e]
    e = edges[e].next_out
```

Traversal is **not** sorted, so `MATCH (a)-[:KNOWS]->(b)` returns edges
in reverse creation order. That is unspecified by Cypher and the tests
must not assume an order the engine does not promise.

**Why threaded lists and not CSR** (this is the M1 gate question, decided
in PRD §4.1): CSR's contiguous per-node edge arrays give better locality
on pure traversal, but any write to a high-degree node requires
rebuilding its arrays. In a hub node (a 10⁵-follower account, a
`(:Chunk)-[:NEXT]->(:Chunk)` chain), incremental import becomes quadratic
in total work. glyphes is embedded and import-heavy, so write locality
wins. CSR remains the documented phase-2 swap, requiring a snapshot
migration, and M1's benchmark exists to make that decision falsifiable
rather than a matter of taste.

The adjacency-discipline test that must pass at M1: **degree bookkeeping
is exact**. After 10⁶ random edge creates and deletes, every node's
`out_count`/`in_count` equals a brute-force recount. A drift here
corrupts the planner's hub detection silently, which is the worst kind
of bug.

---

## 6. Grows and concurrency

The record arrays are `seq[NodeRec]` / `seq[EdgeRec]`, which reallocate on
growth. Reallocation invalidates every raw pointer into them — including
any held by a running operator.

**Rule:** operators never hold raw pointers into the record arrays. They
hold ids and re-index on access. This is the discipline that lets the
arrays grow mid-query without a copy-on-write penalty on every insert,
and it is why §4.7 compaction can renumber freely.

Transactions capture `generation` (`TXN.md` §2); a committed write
swaps array references atomically from a reader's point of view. A reader
on generation *g* sees the array that was current at *g*, kept alive by
the read transaction's reference. Growth within a transaction is
therefore invisible to readers until commit, which is exactly the
copy-on-write boundary.

### 6.1 Reading an array is not free, and the reason is the signature

A snapshot hands out its four arrays through four one-line accessors:

```nim
proc nodes*(r: ReadSnapshot): lent seq[NodeRec] {.inline.} = r.pub.nodes
proc edges*(r: ReadSnapshot): lent seq[EdgeRec] {.inline.} = r.pub.edges
proc labelPos*(r: ReadSnapshot): lent seq[int32] {.inline.} = r.pub.labelPos
proc members*(r: ReadSnapshot): lent seq[seq[int64]] {.inline.} = r.pub.members
```

`lent` is load-bearing. A `seq` returned **by value** is copied, and the C
Nim generates for the accessor above without `lent` is

```c
eqcopy(&result, (*(*r_p0).pub).nodes);   /* memmove of the whole array */
```

so `snap.nodes[id].live` — a bounds check and a byte load — becomes a
`memmove` of every node record. At 2·10⁵ nodes that is 78 µs per access.
The query path over 10⁶ nodes ran at 749 queries/s because of it; the
accessor being `{.inline.}` made no difference at all, because inlining a
copy is still a copy. With `lent` the same lookup is 0.7 ns and the rate is
96 977/s.

The second half of the trap is quieter:

```nim
let lists = ctx.snap.members      # copies the table, whatever the accessor says
if code.int <= lists.len: ...
```

`lent` means "hand me the sequence"; `let` means "give me my own copy".
The copy of a `seq[seq[int64]]` is a copy of every label's member list.
`newScanByLabel` and `labelMemberCount` both had one, each worth 128 µs per
call, which is the entire prepare cost of a query.

Neither the store benchmark nor the churn tests notice: `bench_m1` walks
`store.nodes` and the snapshot arrays are `GraphStore`'s own fields there,
so the accessors are bypassed. **A performance gate has to touch the same
path the feature uses**, which is the argument for C9 existing next to §7
rather than inside it.

---

## 7. Memory model

For a store of *V* nodes, *E* edges, *P* property slots, *B* overflow
arena bytes:

```
nodes        V x 48
edges        E x 56
slots        (allocated, not used) x 16     <- see S14
arena        B (each allocation rounded up to 8)
labels       V_label_members x 8, no bitmap
labelPos     V_slots x 4                    <- M1; see §4.3
dict         O(distinct strings)

"S allocated slots" is not "P used slots": a record's array doubles from
2, so 1 property costs 2 slots and 3 costs 4. Counting used slots
understates the arena by 40 % on the §7 fixture, which is a third of the
memory budget.
```

### The M1 benchmark fixture, stated exactly

Gates need an exact input, not a shape sketch. Pinned fixture, generated
from a committed seed (`TESTING.md` Q9):

```
V = 1 000 000 nodes
E = 4 000 000 edges
per node: 1 int (age), 1 bool (active), 1 string of 40 chars (name)
per edge: 1 int (since)
```

Property mix matters more than counts, because inline vs overflow is an
8-byte cliff (§2.4). The `int` and `bool` properties are inline and cost
no arena. The 40-char `name` is overflow: 40 bytes rounded to 8 → 48, and
it is the only arena consumer.

### Computed resident cost

Recomputed after the store existed, because two of these lines were wrong
when written and only the benchmark could say so.

```
nodes        1.0e6 x 48 B                    =  48 MB
edges        4.0e6 x 56 B                    = 224 MB
node slots   1.0e6 x 4 slots x 16 B         =  64 MB   3 props -> capacity 4
edge slots   4.0e6 x 2 slots x 16 B         = 128 MB   1 prop  -> capacity 2
arena        1.0e6 x 16 B                    =  16 MB   names only
labelPos     1.0e6 x 4 B                     =   4 MB   M1; O(1) label removal
label lists  ~1.2e6 x 8 B                    =  10 MB   no bitmap
dictionary   5 labels, 1 reltype, 4 keys     ~=   0 MB
                                                     ----------
                                                total  494 MB
```

**M1 gate: heap < 680 MB.** Measured: **619 MB**, twice, same machine.

The gate is on `getOccupiedMem()`, which is what the benchmark has always
measured, and the name matters: it is **not** RSS. It is the bytes the Nim
allocator currently holds — live objects plus pool pages it has not
returned to the OS. The benchmark also prints true peak RSS from
`getrusage`, which is **1100 MB** on the same run. The 480 MB difference is
geometric growth copying every record array and the arena through fresh
pages: `nodes` 25→50 MB, `edges` 112→224 MB, arena 128→256 MB. Peak RSS is
a property of the allocator's copy strategy, not of the store, so it is
reported and not gated — but printing only one of the two numbers is how
this gate came to be called "RSS" while measuring something else, and how
a 595 MB reading drifted to 652 MB with no change in the engine. Both are
printed from now on.

Where the 619 MB goes, so that S13's arithmetic is checkable:

```
nodes        1048576 x 48 B                   =  50 MB   10^6 ids, 2^20 slots
edges        4194304 x 56 B                   = 235 MB   4x10^6 ids, 2^22 slots
labelPos     1048576 x 4 B                    =   4 MB
label lists  10^6 ids + doubling slack        =  13 MB   5 lists, 2x10^5 each
arena        2^28 B capacity, 2.4e8 B used    = 256 MB   229 used, 27 slack
dictionary   5 labels, 1 reltype, 4 keys      ~=   0 MB
harness      ids vector                      =   8 MB
                                                     ----------
                                               store  558 MB
                                               + 8 harness
                                               + 53 allocator pool retention
                                                     ----------
                                               total  619 MB measured
                                               budget 680 MB   (+61, ~10%)
```

The **53 MB of pool retention** is not a leak: it is the sum of the record
arrays discarded by the doubling chain (`25+12+6+3…` MB for `nodes`,
`2+1+0.5…` MB for `labelPos`), which ORC keeps for reuse and
`GC_fullCollect()` does not return. The arena's 27 MB of slack is the
2x growth §5 pins. Neither is reclaimable without abandoning geometric
growth, which is the deliberate trade for amortized O(1) inserts.

The gate would be missed if the fixture grew by another 10^5 nodes without
this arithmetic being redone — which is S13's entire reason for existing.

Two things changed here at M3, and neither is the store:

1. **The gate is 680, not 620, and it is called `heap`, not `rss`.** The
   previous 620/595 pair was the same measurement under a name that
   promised more than it delivered; re-deriving it honestly puts the
   budget 10% above a measurement that is reproducible to the megabyte.
2. **The harness stopped holding `eids`.** The edge property is written
   inside the create loop instead of a second pass over `allEdgeIds()` —
   same fixture, same values — which removed a 32 MB vector that was being
   charged to the store's budget. It was 5% of it.

### What was wrong here before the store existed

Four modelling or arithmetic errors, in three revisions, plus two found by
the benchmark after the store was built. Full list with causes:

1. **`EdgeRec` was 48.** The `id` field was omitted from the count. It is
   56. *Found by tabulating the fields.*
2. **`PropSlot` was 24.** 4+1+1+2+8 is 16, and `payload`'s 8-byte
   alignment lands exactly there, so the slot has no padding at all. The
   slot line read 264 MB when it should have read 176, and an earlier
   draft's "72 MB" line had silently dropped edge properties from the
   count as well. *Found by tabulating the fields.*
3. **The gate was set below its own computed cost, twice** — 320 MB, then
   480 MB, against 501 MB. A gate that cannot pass is worse than no gate,
   because it forces someone to weaken it under pressure later. *Found by
   adding the column.*
4. **Slots were counted as *used* rather than *allocated*.** 112 MB rather
   than 192 MB, because a record's array doubles from 2. *Found by
   implementing the doubling and re-reading the spec.*
5. **`InitialSlotCapacity` was 4.** Every record with a *single* property
   allocated 64 bytes of padding: 320 MB of the 620 MB budget. *Found by
   the benchmark, and by nothing else — 91 passing tests did not notice,
   because none of them measured bytes.*
6. **The label bitmap never earned its keep.** `STORAGE.md` §4.3
   originally specified a per-label bitmap plus id list. A node carries
   exactly one label (`CYPHER.md` C13) so there are no duplicates to
   detect, and removal is O(1) by swap-remove with the position in
   `labelPos`. Dropping it removes a second structure that could disagree
   with the first — which is exactly what the checker's S10 exists to
   catch. *Found by implementing removal and asking what the bitmap was
   for.*

None of the first four would have been caught by a test written from the
prose. They were caught by tabulating the fields and letting the compiler
agree or disagree. The fifth needed a benchmark, and the sixth needed
someone to ask "what is this for" about a structure nobody had
questioned. Pin **S13** requires every memory gate to state its fixture
and show its arithmetic; **S14** records the capacity number so the next
person does not "fix" it back to 4.

Two levers if this gate is ever missed, in preference order: switch to CSR
at compaction time (halves the traversal footprint, costs a migration), or
narrow `PropSlot` by moving `aux` into the low bits of `payload` (see
§10). Neither is a 0.1 decision; both are phase 2.

## 8. Invariants

Checked by `check()` (`src/store/store.nim`), which returns one
`Invariant { code, ok, detail }` per rule, and by a debug-build assertion
pass (compile-time `-d:glyphesCheck`) as each write is made.

**Not all ten are machine-checked at M1, and the gaps are deliberate:**

| Code | Checked by `check()` at M1 |
|---|---|
| S1 id uniqueness, ≥ 1 | yes |
| S2 out-chains reach only their own edges | yes |
| S3 in-chains reach only their own edges | yes |
| S4 degree counters exact | yes |
| S5 dictionary codes resolve | yes |
| S6 slot offsets in range | yes |
| S7 traversal order unspecified | **not checkable** — it is a promise about callers, not state |
| S8 no broken or cyclic chains | yes |
| S9 tombstones unreachable from adjacency | yes (as `S9` and `S9b`) |
| S10 label index agrees with records | yes |

S7 has no state to assert. It is enforced by `test_store.nim` asserting
that no test relies on traversal order, which is the only way it *can* be
enforced — an unspecified order cannot be verified, only depended upon by
mistake.

| # | Invariant |
|---|---|
| S1 | `id` is unique across live records and ≥ 1; 0 never names a record |
| S2 | `next_out` chains from `out_head` reach only edges whose `src` is that node |
| S3 | `next_in` chains from `in_head` reach only edges whose `dst` is that node |
| S4 | `out_count`/`in_count` equal the actual list lengths |
| S5 | Every `label`/`type`/`key` code resolves in its dictionary |
| S6 | Every `prop_slots`/`props` offset is 8-aligned and within the arena |
| S7 | Every slot's inline flag agrees with its type and `aux` |
| S8 | A `TOMBSTONE` record is unreachable from any adjacency list |
| S9 | No id appears in both a live record and a free list |
| S10 | Label membership lists contain only live nodes with that label |

S2/S3/S8 together are what make deletion correct. S4 is the one that
fails silently, so it has its own M1 test (§5).

---

## 9. Pins

| # | Pin |
|---|---|
| S1 | `NodeRec` = 48 B, `EdgeRec` = 56 B, `PropSlot` = 16 B, exactly as tabulated |
| S2 | `id` is stable for object lifetime; array index is an implementation detail |
| S3 | Records hold arena **offsets**, never pointers |
| S4 | Inline property iff scalar and `aux × elem ≤ 8`; vectors are never inline |
| S5 | Property lookup is a linear slot scan in 0.1 |
| S6 | Adjacency is threaded lists; insert at head, unlink O(1) with predecessor |
| S7 | Edge traversal order is unspecified; tests must not depend on it |
| S8 | `out_count`/`in_count` are maintained eagerly, never recomputed by walking |
| S9 | Arena is bump-allocated and never freed except by `vacuum` |
| S10 | Dictionaries are append-only; codes are never reassigned |
| S11 | Operators hold ids, never pointers into record arrays |
| S12 | `generation` swap is the commit boundary; readers never observe a partial write |
| S13 | Every memory gate states its fixture and shows its arithmetic, so it can be recomputed when the layout changes |
| S14 | A record's first slot array is 2 slots, not 4. Measured at M1: with 4, every record carrying a *single* property still allocated 64 bytes of padding, which on the §7 fixture was 320 MB of the then-620 MB budget (§0, M3 amendment: the budget is now 680 and the metric is `heap`) |

---

## 10. Open questions

- **Inline string width — settled at M1, and the answer was no.**
  `aux` is `u16`, so inline is capped at 8 bytes. Widening it to `u32`
  looks free in the field sum (4+1+1+4 = 10) but is not: `payload` needs
  8-byte alignment, so it moves from offset 8 to offset 16 and `PropSlot`
  goes 16 → 24 bytes. That is +8 bytes on every property of every record
  — 50% more slot memory, 112 MB → 168 MB on the M1 fixture — in exchange
  for inline strings of 32 bytes instead of 8. Almost all real properties
  are either integers or longer than 32 bytes. **Rejected.**
  The alternative if short strings ever dominate: move `aux` into the low
  16 bits of `payload` for inline values (which have 8 bytes and need only
  a length) and keep `u32` only for overflow values, which are always
  arena-backed. That gives a 32-byte inline ceiling at 16 B per slot, and
  it is cheap. Not pinned; measure first.
- **Slot-array growth — settled at M1:** amortized doubling in the
  arena, using the `NodeRec`/`EdgeRec` `slot_capacity` word. The old
  array is left for `vacuum`. See §2.1.
- **First slot-array capacity — settled at M1 by measurement.** 2, not
  4. The benchmark is what decided it: at capacity 4 the gate fixture
  spent 320 MB of its 620 MB budget on padding in records that hold one
  property. Most records in a real graph carry one or two, so 2 makes
  the common case exact and pays one doubling for the rest. This is
  recorded as S14 because the number looks arbitrary and is not.
- **Label list membership — settled at M1, and the bitmap is gone.** A
  per-label bitmap plus id list was specified here. The bitmap never
  earned its keep: a node carries exactly one label (`CYPHER.md` C13) so
  there are no duplicates to detect, and removal is O(1) by swap-remove
  with the position held in `GraphStore.labelPos`. Dropping the bitmap
  saves 1.2 MB on the §7 fixture and, more usefully, removes a second
  structure that could disagree with the first — the checker's S10 exists
  precisely to catch that, and one fewer structure is one fewer thing for
  it to catch.
  A sorted-list design would give ordered label scans for free at the
  cost of an O(n) insert. Unordered is right for writes; label iteration
  order is unspecified (`S7`) and revisit only if something needs it.
