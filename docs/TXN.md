# glyphes — TXN: transactions, isolation, concurrency

> **Status:** specification for M3. Normative. Companions: `STORAGE.md`
> (the records being written) and `WAL.md` (the log that makes commits
> atomic).

This specifies the transaction model, the copy-on-write merge, the reader
snapshot mechanism, and the concurrency contract. It is deliberately
SQLite's model rather than Memgraph's epochs, per PRD §4.4.

---

## 0. Why not epochs

Memgraph's epoch MVCC exists because a server has many concurrent readers
and a background advance thread, and readers must not block while a long
write is in flight. glyphes is embedded: one process, typically one
writer, and readers that want isolation from an uncommitted write.

That need is met by a `generation` counter and copy-on-write, which is
what this document specifies. Epochs would add ~1.5k lines, a background
thread, and a class of bug (epoch reclamation races) that buys nothing at
this scale. PRD pin P7; the seam where epochs would attach is the
`generation` counter itself.

---

## 1. Model

| Property | Value |
|---|---|
| Writers | exactly one, process-wide per database |
| Readers | unbounded, lock-free against each other |
| Isolation | **serializable** |
| Durability | fsynced at commit (`WAL.md` §6) |
| Deadlocks | impossible — one writer, no lock ordering |
| Nested transactions | not supported; savepoints are phase 2 |

**Serializable, and provably so.** There is one writer and commits form a
total order. A reader either observes a whole commit or none of it,
because the merge (§3) is a single pointer swap. There is no
non-repeatable-read window, no dirty read, and no write skew: any
serialization of the writer's commits is a valid history.

`GLY_ERR_BUSY` on a second `tx_begin`. Not blocking, not queueing — the
embedded case is a Ruby thread that would rather raise than silently
stall a web request.

---

## 2. Generations

```
store.generation : u64    monotonic, starts at 1
```

- Bumped once per successful commit.
- A **read snapshot** is the `generation` value captured at
  `prepare` and held until the statement closes.
- A write transaction captures the generation at `tx_begin` and can only
  commit if `store.generation` still equals it. If it moved, the
  transaction's base is stale.

Since there is exactly one writer, a stale base can only happen through a
bug or an explicit re-entrant commit. The check is cheap and it converts
a whole class of silent corruption into `GLY_ERR_BUSY`.

`generation` is reported by `glyphes_tx_info` and is what the M3
concurrency test asserts on: a reader must never observe two generations
within one statement.

---

## 3. Copy-on-write and the commit point

Writes never touch the published arrays. They go to a shadow structure
owned by the write transaction.

```
WriteTransaction
  base_generation : u64
  node_delta      : Table[int64, NodeRec]     id → new record
  edge_delta      : Table[int64, EdgeRec]
  slot_delta      : Table[int64, seq[PropSlot]]
  label_adds      : seq[(int64, int32)]
  new_labels      : seq[(int32, string)]
  new_indices     : seq[IndexDef]
  wal_frames      : seq[Frame]                 buffered, not yet written
```

Every mutation is: apply to the delta, buffer a WAL frame. Reads see
`delta overlay base`. This is what makes rollback free — drop the delta,
and the base was never touched.

### 3.1 Merge — the atomic commit point

```
commit(tx):
  1. validate: every id in node_delta/edge_delta exists in base
  2. validate: every edge's src/dst are live in base ∪ node_delta
  3. validate: uniqueness constraints (§5)
  4. budget check (§6)
  5. serialize every buffered frame; append to WAL in one write batch
  6. fdatasync                       (unless tx.sync = false)
  7. merge deltas into the published arrays:
       - new records appended to nodes[]/edges[]
       - existing records copied through (write barrier per record)
       - slot deltas written to the arena
       - label lists updated
       - generation += 1
  8. publish: swap the array references atomically
```

Step 8 is the commit. It is a handful of pointer writes, and it is the
only moment a reader can observe the transaction at all. A crash between
5 and 7 loses the merge but the WAL has the frames, so recovery
reconstructs it (WAL.md §5).

Step 5's "one write batch" is the counterpart to WAL.md pin W3: frames
buffered in a transaction are written in a single `write()` when the
buffer is large, but **never** batched across transactions. A single
`write()` per flush keeps the torn-tail property.

### 3.2 Why the deltas are `Table`, not `seq`

Delta lookup is `table[id]`, and `Table` gives O(1). A `seq` indexed by id
would be O(n) to check for presence, making `MERGE` on a large graph
quadratic. The delta is small relative to the store — bounded by the
transaction's touched set, not the graph — so hashing is the right
structure.

---

## 4. Isolation

| Anomaly | Possible? | Mechanism |
|---|---|---|
| Dirty read | no | deltas are private to the writer until publish |
| Non-repeatable read | no | a statement holds its generation; arrays are never mutated in place, only swapped |
| Phantom read | no | same; a new node is a new array reference, invisible to the old generation |
| Lost update | no | one writer |
| Write skew | no | one writer; commits totally ordered |
| Read skew | no | publish is a pointer swap, atomic to the reader |

**The mechanism worth stating:** no reader and a merge ever run at the
same time. A read snapshot takes the store's lock and holds it until the
statement closes; a commit's merge takes the same lock for its duration.
There is therefore no window in which an array is half-written *and
visible*, and no copy is needed — which matters, because the copy-on-write
version cost 48 MB per commit at 10⁶ nodes.

**The gate is a reader-writer lock built from a counter and a condition**
(`store.nim`), and it replaced the one-mutex-for-both-jobs design that M3
shipped. That mutex guaranteed what it was built to guarantee — a reader
and a merge can never overlap — but it made a *second* `beginRead` on the
same thread deadlock rather than wait, which is not a limitation an API
can hide: `db.query` returns a lazy result set, and a caller who consumes
half of it and asks another query blocks the engine forever. The gate:

- `beginRead` increments the reader count and returns, so readers are
  **concurrent** — §1's "unbounded, lock-free against each other", which
  the mutex had suspended, is the design again.
- `beginWrite` sets `writerWaiting`, then waits for the count to reach
  zero; `writerWaiting` is what stops a reader that arrives *during* the
  wait from slipping in front of it. Without it six readers in a loop keep
  the count above zero forever and the writer starves — measured, in the
  first soak run after the gate landed, as both writers parked in
  `beginWrite` for the whole run.
- A reader waits while `writerInside`, so the invariant is unchanged: **a
  merge never overlaps a reader**, which is why no copy is needed and why a
  `PropView`'s arena offsets cannot go stale under a snapshot (§2).

Two supporting facts, both found by ThreadSanitizer rather than by reading:

- **`--mm:atomicArc`, not `--mm:orc`.** ORC refcounts are not atomic, and
  the store is shared by every thread: `endRead` binding `snap.store` to a
  local, `txn.begin` assigning `result.store`, a thread-args tuple holding
  the store — each is a non-atomic refcount write from N threads at once.
  The one-mutex version masked this by serialising the early part of every
  thread's life. `atomicArc` is orc with atomic refcounts, which is what a
  library whose *host* is multi-threaded needed all along: the GIL
  serialises Ruby bytecode, not the collector's bookkeeping.
- **A `ref` field must not be bound to a local in a threaded path.**
  `let s = snap.store` is a refcount write. Field chains (`snap.store.x`)
  borrow instead of copy and touch nothing. The distinction is invisible in
  ordinary single-threaded code and is the whole difference between a clean
  TSan run and a corrupted header two minutes later.

So two of the three deviations below are gone, and the third was never a
property of the design — it was a property of the harness, and the soak's
`sleep(1)` between reader rounds is still there because a reader that
re-acquires with no gap is a spin-loop, not a reader.

This costs one array copy per commit for existing records (§3.1 step 7).
At 10⁶ nodes that is a 48 MB copy per commit — too expensive for a
high-commit-rate workload, correct and fast for the embedded case. The
mitigation for commit-heavy workloads is the delta-chaining approach
Memgraph uses, which is phase 2 and only justified once someone measures
this as a bottleneck.

Copy-on-write per *record* rather than per *array* is the middle path and
is the one to consider first if it becomes necessary: chunked arrays with
a copy-on-write flag per chunk, so a commit copies only the 4 KB chunks
containing modified records. Worth noting here because the layout in
`STORAGE.md` §2 was chosen to be chunk-friendly (fixed-size records).

---

## 5. Constraints

Enforced at merge (§3.1 step 3), not at write time, so that a
transaction which is later rolled back never pays for validation.

| Constraint | Cypher | Failure |
|---|---|---|
| Node property unique | `CREATE CONSTRAINT … IS UNIQUE` | `GLY_ERR_CONSTRAINT` |
| Node existence | `CREATE CONSTRAINT … EXISTS` | `GLY_ERR_CONSTRAINT` |
| Relationship property unique | `… FOR ()-[r:TYPE]-() IS UNIQUE` | `GLY_ERR_CONSTRAINT` |
| Key required | `… IS NOT NULL` | `GLY_ERR_CONSTRAINT` |

Uniqueness uses the index structures (`INDEX.md`) as the enforcement
mechanism, so a constraint and a query index are the same structure with
two clients. No second mechanism, no second consistency story.

Constraint violations report the offending value and the conflicting
key, because a bare "constraint failed" in a 10⁶-row import tells you
nothing about which row to fix.

---

## 6. Budgets

Every transaction has a budget; exceeding it returns `GLY_ERR_LIMIT`
rather than exhausting memory.

| Budget | Default | Rationale |
|---|---|---|
| `max_txn_ops` | 10⁷ | a runaway `UNWIND` should fail, not thrash |
| `max_txn_wal_bytes` | 1 GB | bounds disk during one transaction |
| `max_result_rows` | 10⁷ | bounds a `RETURN *` over a 10⁸-row join |
| `max_sort_bytes` | 256 MB | above this `Sort` spills to disk (`EXEC.md` §5) |
| `max_query_ms` | 0 (off) | opt-in; off by default because a silent timeout in a web request is worse than a slow query |

Budgets are checked at operation boundaries, not per row — checking per
row costs more than the operation. A transaction that exceeds its budget
is **not** rolled back automatically; it returns the error and the caller
decides, matching `sqlite3` and every embedded store.

---

## 7. Threading contract

Pinned: distinct handles are fully independent; one handle is not.

| Rule | Detail |
|---|---|
| Independent | Each `db`/`stmt` handle may be used from a different thread with no external synchronization |
| Same handle | A single `stmt` is **not** thread-safe. Concurrent `step` on one statement is a programming error |
| `db` handle | Concurrent `tx_begin`/`exec` on one `db` is safe: the writer lock makes exactly one win, the rest get `GLY_ERR_BUSY` |
| Global error slot | Thread-local, via `--threads:on` and a `threadvar`; never shared |
| Ruby GIL | Ruby threads do not run engine code in parallel. Parallelism needs processes, which §1 of the PRD excludes |
| Nim threads | The engine is single-threaded for queries. Thread use is for background checkpoint only |

That last row matters: the concurrency test runs at the **Nim** level
with real threads (`--threads:on`), not through Ruby, because the GIL
would make a Ruby-level test prove nothing. Ruby sees single-threaded
behavior and `GLY_ERR_BUSY`, which is honest. (The *engine* is compiled
with `--mm:atomicArc`, so a Ruby thread crossing into it is safe even
though the GIL cannot serialise the collector's refcounts.)

The GIL row is a genuine limitation, stated plainly: glyphes gives a Ruby
program no query parallelism in 0.1. A Rails app with 8 Puma workers gets
8 independent processes each with their own database — which is a valid
deployment, and the only one the PRD supports.

---

## 8. Deadlock and starvation

Neither occurs, by construction:

- **Deadlock** requires two lock acquisitions in conflicting order. There
  is one lock (the writer) and it is never held while acquiring another.
- **Starvation** requires queueing. `GLY_ERR_BUSY` does not queue.

A reader takes the gate briefly — increment, capture the bundle, release —
so a long-running reader no longer blocks a writer for its whole life; it
blocks the *next* writer only until the merge can start, and the writer
waits for readers that are already inside to finish.

---

## 9. Autocommit

A statement outside an explicit transaction runs in an implicit
transaction: begin, execute, commit, all within `glyphes_exec`. Reads
outside a transaction take a generation at `prepare` and release it at
close.

`glyphes_exec` is ~40 % faster than the same statement inside an explicit
transaction because it skips savepoint bookkeeping and merges once at the
end. That difference is why import loops use `exec` inside one
transaction rather than a transaction per statement.

---

## 10. Gates

| # | Gate | Method | Status |
|---|---|---|---|
| T1 | 8 threads (6 readers + 2 writers), 10 min, mixed load: no torn read, no deadlock, zero `SIGBUS`, zero crashes | Nim-level harness, `--threads:on`, ASan build | **green at the full 10 minutes**, first run at that duration: 38 138 commits, 470 526 `BUSY` rejections, 221 332 nodes and 176 901 edges at the end, zero torn reads, zero invariant violations, 600.005 s. ASan clean at 120 s |
| T2 | Reader isolation: a statement sees exactly one generation for its whole life | assert `generation` is stable per statement across a concurrent-writer run | **green** |
| T3 | Rollback discards 100 % of a 10⁵-op transaction; state hash matches the pre-transaction hash exactly | hash of all records in id order | **green** |
| T4 | Serializability: a concurrent-writer trace matches some serial order | record the commit order, assert no anomaly |
| T5 | `GLY_ERR_BUSY` on second `tx_begin`, never a hang | 1000 threads racing; every loser gets `BUSY` within 1 ms | **green** for the claim, now at both levels: the Nim test, and a Ruby test that opens a transaction from a second Ruby thread (`tests/e2e/test_m3.rb`) — which is where the missing `setupForeignThreadGc()` was found. The 1000-thread race is still not implemented |
| T6 | Merge cost budget: commit of 1000-record delta at 10⁶ nodes under 50 ms | benchmark |
| T7 | Constraint enforcement: unique/exists/not-null each fail a targeted test and report the offending value | unit + integration | **deferred to M6** — pin X8 makes constraints reuse the index structures, and those arrive at M6 |
| T8 | Budget enforcement: each of the 5 budgets trips and returns `GLY_ERR_LIMIT` | unit | **green** for `max_txn_ops` and `max_txn_wal_bytes`; the other three bound results and sorts, which do not exist until M4 |

T3 and T5 are the ones that catch real bugs. T3 catches delta leaks;
T5 catches lock-state corruption, which otherwise appears much later as
an unexplained hang.

---

## 11. Pins

| # | Pin |
|---|---|
| X1 | One writer, many concurrent readers. `GLY_ERR_BUSY`, never blocking |
| X2 | Serializable isolation. No read skew, no phantoms |
| X3 | Published arrays are immutable once published; merge is a pointer swap |
| X4 | `generation` monotonic from 1, bumped per commit, captured per statement |
| X5 | Writes go to per-transaction deltas; the base is never touched before publish |
| X6 | Deltas are `Table[int64, _]`, never `seq` indexed by id |
| X7 | Validation at merge time, not at write time; rollback pays nothing |
| X8 | Constraints reuse index structures; no separate enforcement mechanism |
| X9 | Budgets checked at operation boundaries; exceeding returns `GLY_ERR_LIMIT` without rollback |
| X10 | A single statement is not thread-safe; distinct handles are |
| X11 | Engine queries are single-threaded; background checkpoint may use threads |
| X12 | No deadlocks, no starvation, no lock ordering — one lock, never nested |
| X13 | `glyphes_exec` is the autocommit fast path; imports use `exec` inside one transaction |
| X14 | No savepoints, no nested transactions in 0.1 |

---

## 12. Open questions

- **~~Chunked copy-on-write~~ — settled at M3, by not needing it.** §4 names
  it as the first move if commit cost matters, because the merge used to
  copy both record arrays per commit (48 MB at 10⁶ nodes). At M3 the merge
  became an in-place mutation under the store mutex with no reader able to
  be inside the arrays, so there is no per-commit copy left to make
  incremental: `prepareForWrite` is a no-op and a commit costs what its
  delta costs, not what the store costs. It comes back only if the reader
  lock is ever replaced by per-generation arena copies — which would
  reintroduce the read skew §4's design already solves.
- **Savepoints.** Genuinely useful for bulk import error recovery ("commit
  the first 900 000 rows, roll back the bad one"). Costs ~400 lines and
  a nested-delta structure. Deferred to phase 2, but it is the most
  requested thing a real importer asks for.
- **Reader pinning vs. OOM.** A long reader pins a generation and the
  writer copies past it. On a memory-tight embedded host, a writer can be
  blocked by readers. The escape is a `max_reader_pins` that returns
  `GLY_ERR_BUSY` on the *writer* side when too many generations are live.
  Unspecified; the honest default is to let memory grow.
- **`tx.sync = false`.** Specified in `WAL.md` §6 as a per-transaction
  override, with an open question about whether it should be
  session-level instead. Unresolved — it affects this document's step 6.
