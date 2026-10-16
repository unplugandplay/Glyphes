# Glyphes shared-mode design notes

This is the right abstraction. “Alone vs shared” should indeed be **freshness of my published generation**, not “how many processes are attached.” That matches the existing in-process model: writers are exactly one per database, process-wide, and readers pin a published bundle by generation.

But the proposal should be amended in five places before treating it as a design.

## 1. `recover()` is not reusable as-is; runtime catch-up needs a different replay mode

Current `recover()` is open-time, exactly-once, and truncating. It explicitly refuses a store that already holds records. Runtime catch-up needs a sibling primitive:

- replay from “my last replayed LSN”
- never load a snapshot into a live store
- never truncate the WAL
- tolerate concurrent append by the writer
- run under the local reader/writer gate, then `publish()`
- on corruption below the advertised committed LSN, poison the handle with `GLY_ERR_CORRUPT`; do not half-catch-up

So the reusable part is `replay()`, not `recover()`. Name the new entry point something like `catchUp(store, walBytes, fromLsn, upToLsn)` and keep `recover()` open-only.

## 2. The writer claim is under-specified

`fcntl` is necessary, but “fcntl once at open” only works if the opening process is the permanent sole writer. In shared mode the writer role can migrate: a process may open read-only, observe for a while, then later attempt a write.

So the rule should be:

> Before any local write transaction, the process must be caught up to `committedGeneration`, then take the cross-process write lock, then re-check that the shm generation still equals the local generation.

Otherwise a formerly read-only process can begin a transaction from a stale base and allocate ids/LSNs that another process already advanced.

Also: keep one dedicated lock fd open for the life of the `Database`. POSIX byte-range locks are released when *any* fd for that inode is closed in the process; this codebase is exactly the kind of place that bug would live.

## 3. `committedGeneration` cannot be just graph arrays

Index state is deliberately not in the WAL; indexes rebuild from live records. That means a reader that catches up the graph but not the indexes is not caught up in any user-visible sense: seeks, constraints, vector recall, and text search can all be stale.

Same for `.vhist`: graph generation and history generation are related but not identical today.

So either:

- `committedGeneration` means **graph + indexes + history**, and catch-up rebuilds/updates all derived state; or
- shared mode v1 disables indexes and history replay, which is probably too limiting.

Practical v1: after graph catch-up, rebuild affected indexes from live records. Expensive, but honest. Optimizing incremental index replay is its own design.

## 4. The shm block needs real atomics, not “write generation last”

“Write it last” is necessary but not sufficient. Use acquire/release atomics:

- reader: `g = load_acquire(shm.committedGeneration)`
- writer: `store_release(shm.committedLsn, lsn)` then `store_release(shm.committedGeneration, g)`

And make the protocol single-writer monotonic. That property holds globally, which helps.

## 5. Strengthen the checkpoint rule

The recommendation is right; make it harder:

> In shared mode: never truncate the WAL, never compact/renumber, never reclaim ids.

Not “don’t solve read-marks yet”; just refuse those operations while any shared-mode open exists. An open-time `SOLE` probe is too weak because mode can change after open. Either the database is opened shared or it is opened exclusive/maintenance. No dynamic sole detection.

The one-line limitation writes itself: *a shared graph database grows its WAL until a maintenance open checkpoints it.*

## Revised sequencing

```text
open_shared(path, writable):
  keep one lock fd open forever
  if writable: take WRITE byte exclusive, else take OPEN byte shared
  load snapshot if present
  replay_no_truncate(wal, from snapshot.lsn, up to valid committed prefix)
  rebuild indexes/history to same generation
  publish

before_read_txn(db):
  g = load_acquire(shm.generation)
  if g == db.generation: done
  db.store.beginWrite()
  replay_no_truncate(db.store, wal, from db.lastLsn, up to shm.committedLsn)
  db.lastLsn = shm.committedLsn
  db.store.generation = g
  rebuild/update derived state
  db.store.publish()
  db.store.endWrite()

write_txn(db):
  catch up if behind
  take WRITE byte exclusive
  if shm.generation != db.generation:
    release; retry
  run normal local transaction
  fsync WAL
  append/sync vhist
  store_release(shm.committedLsn, lsn)
  store_release(shm.committedGeneration, g + 1)
  local merge/publish
  release WRITE byte
```

Given the product framing — **one graph per agent** — do not start with migrating cross-process writers at all. Ship: one writer process, N read-only observer processes, observers catch up by replay/reopen, and no shared-mode checkpoint/truncate. That is enough for audit, dashboards, eval harnesses, and forensics-by-observation. Runtime catch-up is the next milestone, not the first shared-mode milestone.
