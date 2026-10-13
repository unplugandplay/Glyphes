# glyphes — INDEX: range, text, vector

> **Status:** specification for M6. Normative. Companions:
> `STORAGE.md` §4 (dictionaries, label index), `CYPHER.md` §4 (the
> callable surface), `EXEC.md` §2.5 (the operators), `WAL.md` §3 (index
> state is not logged).

The three index families that make glyphes worth building: hybrid
retrieval in one statement. The label index is built into the store
(`STORAGE.md` §4.3) and is specified there; this document covers range,
text, and vector, plus the two mechanisms that decide whether the vector
index is usable in a graph context.

---

## Status

**M6.3 landed — M6 is complete.** The vector family is built and gated:
HNSW over f32 with the diversity heuristic and the paper's
keepPrunedConnections, cosine/l2/dot metrics per index (I13),
`ef_construction ≥ 200` pinned at creation, tombstones filtered in the
walk itself (I8), byte-identical rebuilds (I11), the
`CALL db.idx.vector(...) AGAINST … YIELD …` retrieval with WHERE pushdown
and over-fetch by selectivity (I10), and the recall gate: **0.960
recall@10 at ef=128 on 10⁵ 64-dim vectors against brute force** (I-vec,
`nimble benchVector`), p50 0.24 ms. **M6.2 landed.** The text family is built and gated: the analyzer
(`standard`, `keyword`, `whitespace`, unknown names refused), the inverted
index over a corpus-wide term dictionary, BM25 scoring verified against a
reference implementation to well under 0.1 % (I6), exact phrase matching
(I7), and the `CALL db.idx.text(...) AGAINST … YIELD …` retrieval as a
query source (CYPHER.md §4). The constraint client of the range index is
enforced at commit (I9, TXN.md §5): unique/exists/not_null fail the
transaction with `GLY_ERR_CONSTRAINT` naming the offending value, and a
constraint over already-violating data is refused at creation. M6.3 — the
vector family — is the rest of this document.

**M6.1 landed.** The registry, the range index, the planner's `IndexSeek`
and the five ABI calls are built and gated (I5 green). Everything below is
the design; the sections marked *landed* say what was actually built.

**Two rules the build added, both the hard way.** First: a range index
holds one key kind, decided by the first keyable value it sees and kept —
a merge whose delta is all deletions must not re-decide it, or a
delete-only merge on a string index rewrites every surviving key as `0.0`.
Second: a column with a value the index cannot order — a bool, a list, two
kinds at once — makes the index **disqualify itself** rather than silently
omit rows. Omission is the one wrong answer the predicate-above-the-seek
design cannot catch: the filter repairs extra rows and can do nothing
about missing ones. `index_rebuild` re-qualifies. Both were review
findings; each had a pair test that failed before the fix.

**One correction to §2.** It specifies "4 KB, up to 512 entries", and those
disagree: an entry is a key plus an id — 16 bytes — so 4 KB holds 256 of
them, and 512 entries is 8 KB and two pages. The page size is the half of
the argument that carries weight (a block scan is *one* miss; a lookup is
*one* page), so the block is sized to the page: `BlockEntries = 4096 / 16`.
§2's other choices — per-block sortedness, chained leaves, a delta in
front — are built as written.

## 0. What each index is for

| Family | Query it serves | Without it |
|---|---|---|
| label | `MATCH (p:Person)` | full node scan |
| range | `WHERE p.age > 30`, `WHERE p.email = $e` | full scan per pattern |
| text | `CALL db.idx.text('Doc.body')` — BM25 keyword search | no keyword retrieval at all |
| vector | `CALL db.idx.vector('Doc.embedding')` — similarity search | no semantic retrieval at all |

Range is table stakes. **Text and vector are the product**, and both
exist to be composed with traversal in one statement — which is
`CYPHER.md` §4 and `EXEC.md` §2.5, not this document's job. This document
specifies how they store and retrieve.

---

## 1. Index registry

```
IndexDef
  name        : string      "Doc.embedding" — target.property
  kind        : uint8       range | text | vector
  target      : string      label ("Doc"), reltype, or "" for global
  property    : string      "embedding"
  constraint   : uint8      none | unique | exists | not_null
  generation   : uint64     bumped on every rebuild
```

Named `Target.property`, which makes the name derivable and means a
recreate with the same definition is idempotent. Enforced unique in the
registry.

Four constraint kinds (`TXN.md` §5) **reuse the index structure**. A
uniqueness constraint is a range index plus a second client that rejects
duplicates at merge. There is no separate constraint mechanism, so there
is no second consistency story to get wrong.

Index state is **never** in the WAL (`WAL.md` §3). It rebuilds from live
records at open, which is bounded by store size rather than log length,
and is reproducible across versions.

---

## 2. Range index — *landed (M6.1)*

Sorted block array with a B-tree overlay.

```
Block (4 KB, up to 512 entries)
  keys   : []f64 or []string   sorted
  ids    : []i64               parallel; node or edge id
  next   : i64                block id of the next leaf, 0 = end
```

- **Inserts** append to an in-memory delta, then merge into blocks at
  checkpoint or when a block exceeds 512 entries (split).
- **Lookups** binary-search in memory blocks, then descend the overlay.
- **Sortedness per block, not global.** Chained leaves give ordered
  iteration without a global B-tree rebuild per insert — the same
  trade-off as the adjacency lists (`STORAGE.md` §5): writes stay O(1)
  amortized, reads pay one extra indirection.

Block arrays are 4 KB because that is one page: a block scan is one
sequential read, and a point lookup touches one page.

**Why not a skip list.** A skip list gives O(log n) without a rebuild and
is a fine choice. A skip list is pointer-chasing, so a lookup costs one
cache miss per level — at 4 KB blocks, a block scan is one miss total.
Block arrays win for `= ` lookups, lose slightly for range scans over
large spans (more blocks visited). Chosen for the point-lookup
frequency that dominates real queries.

---

## 3. Text index

Inverted index with BM25 scoring.

```
Posting list (per term)
  term_id   : i32          dictionary code
  postings   : []Posting    sorted by node id
Posting
  node_id    : i64
  field_freq : i32          term occurrences in the field
  positions  : []i32        only for phrase queries; omitted otherwise
```

Term dictionary is an open-addressing hash (§`STORAGE.md` §4), shared
across all text indexes in a database so `graph` is one code.

### 3.1 Analyzer

Default `standard`: unicode-aware, case-folded, diacritics preserved,
splits on non-alphanumerics, drops tokens < 2 and > 32 chars. No
stemming, no stopword list — both are opinionated and both are wrong for
some corpus. Exact.

Configurable per index: `analyzer` is `standard`, `keyword` (whole field
as one term), or `whitespace`. Pinned: no stemming, no stopwords, because
a user who wants them should not have to guess whether they are on.

### 3.2 Scoring

BM25, standard parameters:

```
score(D) = Σ_t IDF(t) · f(t,D)·(k1+1) / (f(t,D) + k1·(1 - b + b·|D|/avgdl))
IDF(t)   = ln(1 + (N - n(t) + 0.5) / (n(t) + 0.5))
k1 = 1.2, b = 0.75
```

`f(t,D)` is the field frequency, `|D|` the field length in terms,
`avgdl` the mean across the index. `n(t)` is the document frequency for
the term.

The returned `score` is the raw BM25 value, and `CYPHER.md` pin C9 makes
it similarity-shaped (higher is better), so `ORDER BY score DESC` is
correct.

### 3.3 Query parsing

Terms are ORed by default, which matches how keyword search is actually
used. `AND` between terms, `"exact phrase"` for a phrase query (requires
positions), and `-term` for negation. Everything else is a literal term.

AND-of-terms is evaluated as the intersection of posting lists, smallest
list first. That ordering is not a cost model — it is the one piece of
information available without statistics, and it is always right.

---

## 4. Vector index — HNSW — *landed (M6.3)*

The part that has to be right, because an HNSW that ignores graph
context is a worse vector store than a library you already have.

**What the build added to this design, both the hard way.** First: the
walk filters tombstones itself, not through an optional predicate — the
unfiltered search is exactly the path a deleted node slipped through
when tombstoning lived in the caller's filter, and I8's test caught it.
Second: the nearest-leftovers backfill (the paper's
keepPrunedConnections) is not optional here. Without it a node whose
neighbourhood the heuristic rejected keeps two or three links, and at
10⁵ vectors the graph starves — one node in 50k became unreachable and
the recall ceiling at ef=512 was 0.94, which is the graph's fault: a
walk with unlimited breadth finds everything a *connected* graph holds.
The fill costs diversity on uniform data at small N and buys the graph
back at scale; the scale is the product. Third, about benchmarks: a
dataset of disconnected islands (discrete clusters with gaps) has no
bridges and no way to recover from a wrong-region entry — the same index
scores 0.96 recall@10 on overlapping Gaussians and 0.83 on islands. The
gate measures the manifold, because that is what embeddings are.

```
Layer 0: every vector, sorted by insertion for stability
  links0  : [][]i32      m0 = 2M neighbours per node, fixed at build
Layer 1..L: M = 16 neighbours, exponentially fewer nodes
  entry    : i32         top-layer entry point
  graph    : [][16]i32   flat adjacency, so a neighbour fetch is one
                         contiguous read of 64 bytes
```

- `m = 16`, `ef_construction = 200` defaults. Both are overridable per
  index and both change the on-disk layout, so a change requires a
  rebuild (`glyphes_index_rebuild`).
- Metric: `cosine`, `l2`, or `dot`. Stored per index.
- Vectors are f32. A 768-dim embedding is 3 KB per node.
- `ef` (search breadth) defaults to 64, overridable per query:
  `query(vec, k, {ef: 256})`.

### 4.1 Construction

Greedy insertion with the standard heuristic: search the layer
top-down to `ef_construction`, insert, then select `M` neighbours
rejecting any that are closer to an already-selected neighbour than to
the query (the diversity heuristic). Without it the graph collapses into
clusters and recall degrades badly at high `M`.

**`ef_construction` ≥ 200 is pinned.** Lower values build faster and
recall drops measurably; the default is the quality setting, and the
benchmark in §6 exists to prove it is worth the build time.

### 4.2 Explicit build — `idx.build(name)`

Incremental HNSW insertion is 10–40x slower than building from an
existing set, because each insert pays a full `ef_construction`-breadth
search while the batch variant can build layer by layer.

So importers do:

```ruby
db.transaction { import_rows.each { db.exec(...) } }   # no HNSW live
db.index_build("Doc.embedding")                        # 10-40x faster
```

An index created while the store is empty stays empty until built. An
index created against a populated store backfills incrementally. This
split is deliberate: the fast path is opt-in and the slow path is always
correct.

### 4.3 Filtered traversal — the mechanism that matters

`WHERE node.year >= 2024` after a vector query must not degrade into a
full scan. Without care, HNSW's neighbour lists fill with filtered-out
nodes, and the traversal spends its whole `ef` budget walking dead ends.

Two mechanisms, both required:

**Pushed-down property filter.** A filter map passed as the third
argument to `query()` is evaluated during the graph walk:

```
CALL db.idx.vector('Doc.embedding').query($q, 10, {year: {gte: 2024}})
  YIELD node, score
```

The traversal skips a candidate that fails the filter *during* the walk,
so `ef` is spent only on live candidates.

**Over-fetch by selectivity.** The HNSW layer does not know the filter's
selectivity, so a query asks for `k / selectivity` candidates and
truncates after filtering. With `ef = 64` and 5 % selectivity that is
`k × 20` candidates — expensive but bounded, and far cheaper than a scan.

Selectivity is estimated from the property's range index if one exists,
otherwise from a default of 10 %. This is *not* a cost model (that is
`EXEC.md` §4); it is one number used to size `ef`, and a wrong
estimate costs time, not correctness.

```
db.query("CALL db.idx.vector('D.e').query($q, 10, {year: {gte: 2024}}) ...")
```

Both mechanisms are pinned because the filtered case is the common case
in a graph context — a temporal or tenant filter is nearly always
present, and an unfiltered-only vector index is not useful.

### 4.4 Deletions

HNSW has no delete. A deleted node's vector entry is **tombstoned** and
filtered at read time, and the search over-fetches to compensate.

Tombstone filtering is a **correctness** requirement, not an
optimization: a `CALL db.idx.vector(…).query()` must never return a
deleted node. The graph links to a tombstoned node remain (they would
require a full rebuild to remove), so the walk still visits it and pays
the cost — which is why `vacuum` rebuilds vector indexes whose
tombstone ratio exceeds a threshold.

### 4.5 Recall and the `ef` contract

HNSW is approximate. `ef` is a tunable, not a correctness knob, and the
contract is stated so callers can reason:

| `ef` | recall@10 @ 10⁶ | p50 latency |
|---:|---:|---:|
| 32 | ~0.91 | ~1 ms |
| 64 (default) | ~0.95 | ~3 ms |
| 128 | ~0.97 | ~6 ms |
| 256 | ~0.98 | ~14 ms |
| brute force | 1.00 | ~180 ms |

Recall is measured against exact brute-force cosine. Gate M6 requires
recall@10 ≥ 0.95 at the default `ef = 128`, and this table is the
published expectation — a caller who needs exactness uses `ef` high
enough or reads the index directly.

---

## 5. Index lifecycle

| Operation | Cost | Notes |
|---|---|---|
| `index_create`, store empty | O(1) | stays empty until built or written |
| `index_create`, store populated | O(n) | backfills incrementally |
| `index_build` | O(n log n) | the fast bulk path |
| `index_rebuild` | O(n log n) | after `m`/`ef_construction`/analyzer change |
| `index_drop` | O(1) | leaves a `DropIndex` WAL frame |
| `index_list` | O(#indices) | JSON |

Writes to an indexed property update the index in the same transaction
(`TXN.md` §3), so an index is never stale relative to committed data.
That is why `CreateIndex`/`DropIndex` are the only index-related WAL
opcodes (`WAL.md` §3).

Vacuum interaction: `db.vacuum` (§`WAL.md` §4.2) rebuilds any index whose
tombstone ratio exceeds 20 %. Checked at compaction, not per delete —
`checkpoint` asks `indexesNeedingRebuild()` and rebuilds only the indexes
that ask, and `vacuum` still rebuilds everything on demand.
because computing the ratio per delete would be O(n) per operation.

---

## 6. Gates

| # | Gate |
|---|---|
| I1 | recall@10 ≥ 0.95 vs brute-force cosine at `ef = 128`, 10⁶ vectors, 768 dims |
| I2 | `idx.build` ≥ 10x faster than equivalent incremental inserts |
| I3 | Filtered vector query at 5 % selectivity stays < 50 ms at 10⁶ docs |
| I4 | Pushdown beats post-filter by ≥ 5x on I3's workload |
| I5 | Range index: 10⁶-node scan becomes < 1 ms point lookup; range scan < 10 ms |
| I6 | Text: BM25 scores match a reference implementation within 0.1 % |
| I7 | Text phrase query returns only exact phrase matches |
| I8 | Deleted nodes are **never** returned by vector or text search (correctness) |
| I9 | Constraint enforcement reuses the index structure; unique/exists/not-null each fail correctly |
| I10 | Index survives snapshot + recovery: state hash identical before and after |
| I11 | Deterministic: same input → byte-identical index at fixed `m`/`ef_construction`/seed |

I8 and I11 are the ones that matter most. I8 is a correctness gate on an
approximate structure, which is exactly where approximations hide bugs.
I11 is what makes differential testing possible at all — a
non-deterministic index cannot be golden-tested, and `vec` vectors with
a fixed RNG seed are what makes it deterministic.

---

## 7. Pins

| # | Pin |
|---|---|
| I1 | Index name is `Target.property`; one index per (target, property) |
| I2 | Index state is never in the WAL; it rebuilds from live records at open |
| I3 | Constraints reuse index structures; no separate enforcement path |
| I4 | Range index is 4 KB blocks with chained leaves; point lookup touches one page |
| I5 | Text analyzer: `standard` (case-folded, no stemming, no stopwords) |
| I6 | Text scores are raw BM25 (k1=1.2, b=0.75); terms OR by default |
| I7 | Vector: HNSW, f32, `m=16`, `ef_construction=200`, `ef` default 64 |
| I8 | `ef_construction ≥ 200` is the default; lowering it requires an explicit rebuild |
| I9 | `index_build` is the bulk path and is 10–40x faster than incremental |
| I10 | Vector filters are pushed into the walk and over-fetch by estimated selectivity |
| I11 | Tombstoned nodes are never returned by any index — a correctness requirement |
| I12 | `score` is similarity-shaped for both text and vector (`CYPHER.md` C9) |
| I13 | `metric` is per-index; changing it requires a rebuild |
| I14 | Vacuum rebuilds an index whose tombstone ratio exceeds 20 % |

---

## 8. Open questions

- **`aux` widening in `PropSlot`.** `STORAGE.md` §10 notes that widening
  `aux` to `u32` is free in slot size and would allow 32-byte inline
  strings. Independent of this document but it changes `PropSlot`'s size,
  which the snapshot format serializes. Decide before M6 writes a real
  index.
- **Multi-property vectors.** A `Doc` with both `title_vec` and
  `body_vec` needs two indexes and no join between them. A combined index
  would need a weighted sum at write time, which pushes scoring policy
  into storage. Rejected for 0.1; it is a modelling question wearing an
  index question's clothes.
- **HNSW deletion.** Tombstoning plus rebuild-on-vacuum is the cheap
  correct answer. A real tombstone-aware HNSW (periodic graph
  reconnection) exists and would fix the over-fetch cost, at ~300 lines
  and a substantial correctness risk. Not in 0.1.
- **Text positions.** Stored only when a phrase query exists in the
  corpus. Deciding that per index at creation time is simpler than
  deciding per query, and 0.1 stores positions always — the memory cost
  is one `i32` per posting, which is significant at 10⁶ documents. Revisit
  if the text index is measured as the memory bottleneck.
