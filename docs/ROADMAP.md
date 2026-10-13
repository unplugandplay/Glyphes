# glyphes — Roadmap

> **Status:** M0–M4 landed; M5.1–M5.3 landed. Phase A (the whole thesis — one file,
> crash-safe) is green end to end, and M4 is the first milestone that
> answers a question rather than only storing an answer.
>
> **M0–M6.1 landed.** `nimble gate` runs 317 Nim tests, 106 Ruby tests and
> the TCK subset, all passing, both halves clean under AddressSanitizer,
> TSan clean over the soak, and every budget green:
>
> ```
> M1 store bench    create 1360 ms <= 8000   traversal 167 ms <= 400   heap 619 <= 680 MB
> C1 TCK subset     132/132 in-contract (gate 95%), 17/17 refusals name their construct
> C9 query bench    96 977 single-hop queries/s (gate 50 000), 2-hop 0.066 ms (gate 3 ms)
> ```
>
> Twelve Nim→FFI and process findings are in
> [`M0-NOTES.md`](M0-NOTES.md). M1's own findings — two more arithmetic
> errors in `STORAGE.md`, an unlength-prefixed arena blob, an O(n²)
> `seq.delete` in the test harness, and a 320 MB padding waste that the
> benchmark caught and the tests could not — are in
> [`../DEVLOG.md`](../DEVLOG.md).
>
> **Next:** M5.4 — aggregates, which turn `WITH` into a grouping boundary and
> so change the operator set rather than adding a clause to it. M5.1 landed
> `CREATE`, M5.2 the clauses that change an existing graph, M5.3 `MERGE`.
> M4 landed at its ABI: nine new
> `glyphes_*` symbols (`prepare`, `stmt_step`, `stmt_columns`,
> `stmt_close`, `stmt_reset`, `cell_text`, `cell_id`, `cell_len`,
> `stmt_columns_count`), a `Statement`/`Cell`/`Result` layer in Ruby, and
> `db.query`/`db.prepare`. Reads are Cypher; writes are refused by name
> with `GLY_ERR_UNSUPPORTED`. The gates are C1 (TCK subset) and C9 (query
> rate), both in `nimble gate`.
>
> M4's own findings are in [`../DEVLOG.md`](../DEVLOG.md): a `seq`
> accessor that copied the entire node array on every row (130x on the
> query path), `ORDER BY` needing the projection to carry its source
> bindings through, `XOR` taking the process down with a `FieldDefect`, and
> pin C5 (`int` and `float` are never `=`) not being enforced.

Phases are strictly ordered. Every milestone ships with tests and updated
docs. Gates are merge conditions and they fail the build
(`TESTING.md` §3.2).

---

## Phase A — the file (M0–M3)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M0 | ABI spine | `--app:lib --mm:orc --threads:on`, `glyphes.h`, `abi.nim`, status codes, `open`/`close`/`stat`/`version`, generation-tagged handles, load-time layout assertions | **LANDED** — 21 Ruby tests, 31 Nim tests *at M0* (91 after M1), ASan clean; notes in `M0-NOTES.md` |
| M1 | Store | dense ids + free lists, `NodeRec`/`EdgeRec`, threaded adjacency both directions, label dictionary + per-label lists, property slots + arena | **LANDED** — `nimble bench` green on all three budgets; 91 Nim tests incl. a 10⁶-op degree recount |
| M2 | Durability | WAL frames + CRC + fsync, snapshot writer, mmap reader, recovery, torn-tail truncation, auto-checkpoint | **W1**: `kill -9` at 100 random points during a 10⁶-node import — every run recovers to the last committed transaction, byte-identical to clean shutdown. **in — green** |
| M3 | Transactions | single writer, `generation`, merge, `GLY_ERR_BUSY`, rollback, constraints, budgets, `integrity_check` | T1 8-thread 10-min soak with no torn read; T3 rollback discards 100 % of a 10⁵-op transaction; T5 second `tx_begin` returns `BUSY`, never hangs | **LANDED** — 301 Nim tests (11 of them through the exported ABI) + 102 Ruby tests; T1/T2/T3/T5/T8 green, T4/T6 unimplemented, T7 deferred to M6. The exported surface is `glyphes_tx_begin/commit/rollback/tx_info` + `glyphes_integrity_check`; mutation stays Cypher-only (ABI.md B6). |

M2's gate is the project's real test. A graph database that loses data on
crash has failed at the only thing it was for.

---

## Phase B — the query (M4–M6)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M4 | Cypher read | lexer, parser, AST, semantic pass, greedy planner, `ScanAll`/`ScanByLabel`/`Filter`/`Project`, `WHERE`, `RETURN`, `ORDER BY`/`SKIP`/`LIMIT` | **LANDED** — C1 71/71 at the time, now 90/90 with M5's write rows; C9 92 000–97 000 queries/s (gate 50 000) and 2-hop 0.065 ms (gate 3 ms) at 10⁶ nodes |
| M5 | Cypher write | `CREATE`/`MERGE`/`SET`/`DELETE`/`REMOVE`, `UNWIND`, `WITH`, `Aggregate`, `Sort` with spill, `OPTIONAL MATCH`, variable length | **LANDED** — M5.1 `CREATE`, M5.2 `SET`/`REMOVE`/`DELETE`/`DETACH DELETE`, M5.3 `MERGE` (+`ON CREATE`/`ON MATCH`), M5.4 aggregates and M5.5 `OPTIONAL MATCH` + variable length have landed: 24 write, 23 aggregate and 11 join rows in the TCK subset, writes join an open transaction, rollback undoes them, a transaction reads its own writes, a projection with an aggregate groups by its non-aggregated items, and a variable-length walk holds to relationship uniqueness. M5.6 landed `Sort` with spill (200 runs over 10⁷ rows) and the E gates: **E2** `LIMIT 10` over a 10⁶-row traversal in 0.62 ms (gate 2 ms), **E3** a 10⁷-row sort that spills 200 runs and completes in 88 s. **M5 LANDED.** `FOREACH` is the last write clause refused, and is not scheduled |
| M5 | Cypher write | `CREATE`/`MERGE`/`SET`/`DELETE`/`REMOVE`, `UNWIND`, `WITH`, `Aggregate`, `Sort` with spill, `OPTIONAL MATCH`, variable length | E2 `LIMIT 10` over a 10⁶-row traversal < 2 ms; E3 sort of 10⁷ rows spills and completes |
| M6 | Indexes | range (block array), text (inverted + BM25), vector (HNSW + filtered traversal), constraints on index structures | I1 recall@10 ≥ 0.95 at `ef = 128`; I3 filtered query at 5 % selectivity < 50 ms; I8 a deleted node is **never** returned |
| M6 | Indexes | **LANDED** **M6.3 landed — M6 complete:** HNSW over f32 (M=16, ef_construction ≥ 200 pinned, cosine/l2/dot per index) with the diversity heuristic and the paper's keepPrunedConnections — measured: without the fill a 50k-vector graph starves (one node unreachable, recall ceiling 0.94 at ef=512), with it the ceiling is 1.0. Tombstones are filtered in the walk itself (the unfiltered path was the hole I8's test caught), rebuilds are byte-identical (I11), and `CALL db.idx.vector(…) AGAINST … YIELD …` pushes WHERE conjuncts over the yielded node into the walk — through the engine's own expression evaluator, not a second comparison implementation — with over-fetch by selectivity (I10). The recall gate is 0.960 @ ef=128 on 10⁵ 64-dim Gaussians vs brute force, p50 0.25 ms; disjoint-island datasets measured 0.83 and are documented as pathological, because real embedding spaces are manifolds, not islands |

---

## Phase C — the door (M7–M9)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M7 | Ruby complete | `Database`, `Statement`, batched `each_slice`, `Cell` hierarchy, all 11 statuses mapped, transactions, index API | R1 every status reachable with a specific exception; R2 zero segfaults under a 10-min GC-stress fuzz |
| M7 | Ruby complete | **LANDED** — the eleven ABI functions the header declared and nothing implemented are built (cell accessors, stats, schema, checkpoint, wal_size) plus six new ones (`backup`, `vacuum`, `node_labels`, `node_props`, `edge_info`, `edge_props`); the three that design forbids (`cell_at`, `cell_get`, `cell_blob`) are *documented refusals* with specific statuses, because a list/map payload is JSON and an engine-allocated blob would put a second allocator in the ABI. The `Cell` hierarchy and `Node`/`Edge` views are real value classes; `Node.new(db, id)` reads without Cypher and a node cell materializes as a view, not an id. Durability doors (`checkpoint`, `backup`, `vacuum`, `schema`, `stats`) and the cursor verbs (`first`, capped `to_a`, `count`, `reset`) landed. The index *definitions* are now durable (a `.indexes` sidecar, per pin W5's rebuild-at-open): an index and its constraint survive a reopen. **R1** green (all 11 statuses reach a class, six of them raised through real queries), **R2** green (GC-stress holding live Cells across batches, no segfault). The milestone's tests found two real bugs: `checkpoint(truncate: true)` silently did nothing (cut at the log's end rather than dropping covered frames) and two index families could share one name |
| M8 | Model layer | `Glyph::Base`, relations, scopes, validation door, callbacks, `find_or_create_by`, `pluck` | R6 Rails-shaped suite: 60 unit + 12 integration; R5 ≤ 1 extra FFI crossing per verb — **done** (58 model tests of R6's 60 unit + 12 integration shape; R5 measured, not asserted) |
| M9 | Import/export | CSV, JSONL, Parquet in Ruby; `import`/`export` DSL | R8 10⁶-row CSV < 60 s (**28 s**); Parquet within 0.1 % of a reference (**0.002 %**); R11 unknown column raises — **done** |

---

## Phase D — hardening (M10–M11)

| # | Milestone | Deliverable | Gate |
|---|---|---|---|
| M10 | Corruption & recovery | snapshot CRC verification, replay idempotence, `integrity_check` reporting, `vacuum`, index rebuild on tombstone ratio | W3 10⁶ bit-flips: every outcome a clean open or a named error, never a crash or silent corruption — **done** (999 883 named / 0 silent at the full 10⁶; W2 truncate sweep green at 55 boundaries). Four defects found, four fixed; `GLY_ERR_CORRUPT` added. Index rebuild on tombstone ratio: `vacuum` only (I14's automatic trigger is still manual) |
| M11 | Benchmarks & docs | benchmark suite vs SQLite-edge-tables, README, `ARCHITECTURE`, `TESTING`, published `limitations.md` | 20-node 5-day soak with zero leaks; every benchmark reproducible from `make bench`; `limitations.md` published **before** release |

---

## Open questions carried into the build

Collected from each spec's closing section, so they are decided
deliberately rather than by accident. None blocks M0.

| Question | Source | Decide by |
|---|---|---|
| Chunked copy-on-write for the merge path | `TXN.md` §12 | **M3** — it changes the array representation, and doing it after M3 means a rewrite |
| `PropSlot.aux` widening to `u32` (free in slot size, allows 32-byte inline strings) | `STORAGE.md` §10, `INDEX.md` §8 | **before M6** — it changes `PropSlot`'s size, which the snapshot serializes |
| ~~`json_out` fixed buffers vs growable~~ | `ABI.md` §7 | **settled at M0**: caller buffer, cap in/out |
| ~~`GLY_PATH` representation~~ | `ABI.md` §7 | **settled at M0**: `GlyPath` out-param + component accessors |
| ~~`PropSlot` inline-string width~~ | `STORAGE.md` §10 | **settled at M1 — rejected**: 16 → 24 B, +50% slot memory |
| Savepoints for import error recovery | `TXN.md` §12 | phase 2; most-requested item from real importers |
| Statement cache bound (unbounded today) | `RUBY.md` §9 | **M8** |
| `Relation` vs `Enumerator` | `RUBY.md` §9 | **M8** |
| Text index: always store positions, or per index | `INDEX.md` §8 | **M6** |
| Real gem name (`glyphes` is taken on rubygems.org) | `RUBY.md` §9 | before `gem push` |
| Crash-gate frequency (full W1 nightly vs reduced on merge) | `TESTING.md` §9 | **M2** |
| `tx.sync` per-transaction vs session-level | `WAL.md` §10, `TXN.md` §12 | **M2** |

M0 also resolved three things the specs had left open, all recorded in
`M0-NOTES.md`: the `GlyHandle` binding is a scalar (`:uint64`, not
`:pointer`), the handle registry must hold a `GC_ref` rather than a raw
pointer under ORC, and `--threads:on` is required for the registry's
mutex.

Settled at M0: both of the ABI's open questions (the JSON out-param
protocol and the path representation), plus three the specs had not
surfaced — the `GlyHandle` binding is a scalar rather than a pointer, the
handle registry must hold a `GC_ref` rather than a raw pointer under ORC,
and `--threads:on` is required for the registry's mutex. All three are in
`M0-NOTES.md`.

Three are still open, each with a deadline rather than a preference:

| Question | Deadline | Why then |
|---|---|---|
| ~~`PropSlot.aux` widening to `u32`~~ | **settled at M1 — rejected** | `payload` alignment pushes the slot 16 → 24 B; +50% slot memory for 32-byte inline strings |
| chunked vs per-record copy-on-write | **end of M3** | it changes the array representation M1 and M2 build against; afterwards it is a rewrite |
| ~~`PropSlot` slot-array growth~~ | **settled at M1** | amortized doubling via the `slot_capacity` word; the old array is vacuum garbage |

---

## Standing rules

1. **The spec leads.** Where code and a spec disagree, the spec wins and
   the spec is amended first, with a `PRD §x amendment` marker.
2. **Gates fail the build.** A budget gate is not a target; exceeding it
   by 10 % blocks a merge (`TESTING.md` Q8).
3. **A new operator that materializes needs a spec amendment.** The
   no-materialization rule (`EXEC.md` E2) is what keeps the executor
   small, and it is only enforceable if review catches violations.
4. **Amending the non-goals is a writing task.** `PRD-GLYPHES.md` §7 and
   §9 change by editing the document with a gate attached, never by
   drift. The original failure mode was scope growth without a record;
   this is the record.
5. **No new dependencies.** `nim >= 2.2`, the `ffi` gem. If a phase needs
   a package, that is a design failure to be solved in Nim.
