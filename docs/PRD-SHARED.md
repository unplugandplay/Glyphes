# glyphes — PRD: shared mode

> *One graph, several processes. One writer at a time, and everyone else
> sees the same committed truth.*

**Status:** PRD, pre-implementation. Every *pin* is normative; every *gate*
is a merge condition. Where code and this document disagree, this document
leads.

This PRD **amends** `PRD-GLYPHES.md` pin **P1** ("One file, one process,
embedded. No server in 0.x") and `limitations.md` §6 ("Single-process,
single-writer"). P1's *intent* is preserved — still embedded, still no
server, still one file plus sidecars — but its *scope* was one process and
this document is about the second one. It does not weaken P8: a commit is
still atomic and fsynced, and §4.2 makes the shared-mode ordering stricter
about when that fsync lands relative to other processes' visibility.

It does not touch `PRD-VERSIONING.md`. The two interact in one place —
compaction — and that interaction is recorded in §4.5 rather than resolved
here.

The starting point was a design discussion, and `glyphes_shared_mode_design_notes.md`
holds it. That file is the input; this is the decision. Where they differ,
this document says so and says why (§12).

---

## 1. What this is

**Two or more processes on one graph file, with exactly one of them writing
at a time, and every other process seeing committed state rather than its
own stale copy.**

Today this is not merely unsupported, it is **unsafe**, and that is the part
that makes it worth doing rather than deferring.

The reader's inference is the problem. `limitations.md` §6 says
"single-process, single-writer" and then, carefully, hedges: the soak "says
nothing about two processes on two machines." The hedge is correct and the
document is honest. But *within* one process the invariant genuinely holds —
a second writer does get `GLY_ERR_BUSY` — and a user who has verified that
will reasonably believe it holds everywhere. It does not. `claimWriter`
(`store.nim:349`) is an `Atomic[uint32]` compare-exchange, a *process-local*
primitive. Two processes each open the same file, each exchange 0 → 1, each
succeeds, and each believes it alone.

So the invariant is true in the scope §6 names and silently absent outside
it, and the only thing standing between a user and two agents corrupting one
graph is the observation that nobody tried. `PRD-VERSIONING.md` §12 already
recorded this ("a second `Database` handle on one file opens successfully")
as a correctness item in its own right. It is that item, generalised.

So this PRD delivers two things, and the first is not optional groundwork
for the second:

1. **Cross-process writer exclusion.** Two processes can no longer corrupt
   one graph. This is a bug fix.
2. **Shared read.** A reader in another process catches up to the last
   committed generation, on demand, before serving a read.

### 1.1 The product framing decides the shape

The intended use is **one graph per agent**, where several agents observe
and one coordinates. That framing does most of the design work, because it
answers the question SQLite's WAL spends most of its complexity on — how
readers and a checkpointer coexist — by *not having a checkpointer*. See
§4.5.

## 2. What this is not

- **Not a server.** No daemon, no port, no protocol, no client library. The
  processes are on one machine and communicate through the filesystem and
  POSIX locks, which is what `PRD-GLYPHES.md` P1 means by embedded.
- **Not multi-writer concurrency.** §8's S1 ships *cross-process writer
  exclusion*; migrating the writer role between processes is S4 and is
  explicitly later. Two processes writing simultaneously is not a thing
  this document builds.
- **Not SQLite's WAL.** SQLite allows readers, a writer and a checkpointer
  to overlap, and pays for it with a shared-memory WAL-index, per-slot read
  locks and a read-mark protocol that has been the site of serious bugs for
  two decades. glyphes declines that trade in shared mode (§4.5) and says so
  in `limitations.md`.
- **Not a fix for `PRD-VERSIONING.md` §4.3.** Compaction's renumbering
  conflict is real and is made *worse* by shared mode, not better. §4.5
  refuses compaction in shared mode rather than solving it.
- **Not networked.** No NFS, no SMB, no Docker volumes over network
  filesystems. POSIX advisory locks are unreliable or absent on many of
  those, and a database whose correctness depends on them should refuse
  rather than pretend. This is a refusal by name in S10.

## 3. The model

### 3.1 "Alone or shared" is *freshness*, not attachment

The obvious reading of "am I alone?" is "how many processes have this file
open?" — a counting problem, and counting is where this codebase's
worst bugs live. `store.nim`'s `writerClaim` comment is a post-mortem of
exactly that: a check-then-act window that let both writers through.

The question that can actually be *wrong* is narrower and better:

> **Does my published generation still equal the last committed generation
> anywhere?**

If it does, my in-memory arrays *are* the current committed state, and a
read is a pointer dereference. If it does not, someone committed behind my
back and I must catch up before serving anything. That is the whole
condition, and it needs no process count anywhere.

### 3.2 Two modes, declared at open

The design notes are firm that mode must not be *detected*, and this PRD
binds that as a pin (S2): **a database is opened shared, or it is opened
exclusive. There is no dynamic detection.** The reasons are specific:

- A sole-mode probe at open is a lie the moment a second process attaches,
  and code that believes it keeps taking the fast path.
- Two modes with a runtime transition need the *slow* path to be correct
  from the first frame, which means the slow path is the only one that is
  ever really tested in shared deployments.
- Declaring mode makes exclusive mode **bit-for-bit today's code path**.
  That is a stronger guarantee than "the check is cheap": there is no new
  branch, and therefore no new way to be wrong, in the single-process case
  that most users run.

```
open(path, exclusive):
  keep one lock fd open for the life of the Database      (S3)
  flock(-lock, EX) for exclusive, or nothing for shared
  load snapshot if present
  replay(wal, from=snapshot.lsn, upTo=committedLsn)       never truncates
  rebuild derived state to the same generation            (§4.4)
  publish()

open_shared(path, readonly):
  keep one lock fd open for the life of the Database
  no writer lock; take none until a write is attempted      (S4)
  ...same as above, plus: observe
```

### 3.3 A catch-up is a replay, and replay already exists

A catch-up is: read the WAL from my last replayed LSN up to the advertised
committed LSN, apply it to my store, publish.

The design notes correctly refuse to reuse `recover()` for this.
`recover()` (`recover.nim:577`) *refuses a store that already holds
records*, and states why:

> replay is exactly-once per store: running it again over a populated
> store would apply the same frames twice, and a silent double-apply is far
> worse than a loud refusal

That refusal is correct and stays. But the primitive underneath it is
already shaped for incremental use:

```nim
proc replay*(s: GraphStore, walBytes: string, fromLsn: uint64): Recovery
```

`recover()` is `replay()` plus a snapshot load, a truncation and the
exactly-once guard. **The new entry point is `catchUp(store, walBytes,
fromLsn, upToLsn)`** — `replay()` with a bound, no snapshot, no truncate —
and it keeps `recover()` open-only.

#### 3.3.1 A correction to the design notes, and to me

The notes list "`lastLsn` is not tracked" as an atomicity hazard: get it
wrong and you double-apply. **That is wrong, and `WAL.md` pin W9 already
settles it.** `replay()` skips `if fromLsn > 0 and f.lsn <= fromLsn`. So a
`lastLsn` that is *too low* replays frames that were already applied, and
the skip rule makes them no-ops. It costs time, not correctness.

What is genuinely required is that `lastLsn` never runs **ahead** of what
was applied, and that holds structurally because it is only ever assigned
from a completed replay. `GraphStore` does not track an LSN today
(`rg lsn src/store/store.nim` is empty); S1 adds one, as a performance
field with a correctness argument behind it rather than as a critical one.

## 4. Mechanism

### 4.1 The lock: `flock`, on a file `WAL.md` already specifies

`WAL.md` §1 lists `graph.glyph-lock` as "advisory lock, holds the writer
pid", and pin W13 pins "Locking is `flock`, not pid liveness". **Neither
exists in `src/`** — `rg "fcntl|flock|lockf" src/` is empty. The design was
written down and never built, which is the cheapest possible time to notice.

`flock`, not `fcntl` byte-ranges, for three reasons:

1. **It is already pinned** (W13). Introducing `fcntl` to solve a problem
   the house decided differently twenty documents ago is a worse outcome
   than a small inconsistency.
2. **`flock` has the safer close semantics on this axis.** POSIX `fcntl`
   byte-range locks are *process*-associated and are released when **any**
   file descriptor for that inode is closed in the process — so a helper
   that opens and closes `-lock` would silently drop the writer lock. BSD
   and Linux `flock` locks are per *open-file-description*, and closing an
   unrelated descriptor does not release them. The design notes' advice to
   hold one dedicated fd is still taken as hygiene, but under `flock` it is
   about lock *lifetime intent* rather than about avoiding a trapdoor.
3. **In shared mode there is only one lock to take.** The byte-range layout
   in the notes (WRITE / SNAPSHOT / SOLE) collapses once S5 removes the
   checkpointer: the writer takes one exclusive lock, and **readers take
   none at all** (§4.5 explains why that is safe).

The lock is held for the life of the writer `Database` in exclusive mode.
In shared mode it is acquired when a write is first attempted (S4).

### 4.2 The control block: mmap, and real atomics

A small `<db>-shm` file, mmap'd, holding two words:

```
committedGeneration : uint64
committedLsn        : uint64
```

The notes are right that "write generation last" is necessary but not
sufficient, and the reason is sharper than the notes give:

> **This is an arm64 codebase.** `uname -m` is `arm64`. On x86's total
> store ordering, "write `committedLsn`, then `committedGeneration`" happens
> to be enough. On ARM, stores may be observed out of order by another
> core. A reader can observe the advanced generation with a stale LSN, and
> then bound its replay at a prefix that does not contain the frames the
> generation implies.

So the protocol is release/acquire, and it is pinned (S6):

```
reader:  g = load_acquire(shm.committedGeneration)
writer:  ... frames durable (fdatasync) ...
         store_release(shm.committedLsn, lsn)
         store_release(shm.committedGeneration, g + 1)
```

The store is single-writer by S1, so `committedGeneration` is monotonic
database-wide and the ordering above is sufficient without a seqlock.

### 4.3 The catch-up, and its two bounds

```
before_read_txn(db):
  g = load_acquire(shm.committedGeneration)
  if g == db.store.generation: done                  # §3.1: the whole check
  db.store.beginWrite()                               # the existing local gate
  catchUp(db.store, wal, from = db.lastLsn, upTo = committedLsn)
  rebuild derived state to g                          # §4.4
  db.store.publish()
  db.store.endWrite()
```

Two bounds, and the second is the one that will bite:

- **Bounded below** — frames at or below `fromLsn` are skipped (W9).
- **Bounded above by `committedLsn`, never by end-of-file.** The writer may
  already have appended frames belonging to a transaction still in flight.
  A catch-up that replays to EOF applies an **uncommitted** transaction.
  Staleness is a recoverable annoyance; reading uncommitted data across a
  process boundary is a correctness incident, and it is pinned (S7).

On corruption *below* `committedLsn` — i.e. in a region the writer claims is
durable — the handle is poisoned with `GLY_ERR_CORRUPT`. Never half-caught-up.

### 4.4 `committedGeneration` means *all* derived state

This is the point that makes the design honest rather than merely safe, and
the notes are right to insist on it.

A reader that caught the graph up but not the indexes is not caught up in
any sense a user can observe. Index state is deliberately **not** in the WAL
(W5), so after a catch-up:

- seeks answer against a stale index,
- constraints are enforced against stale state,
- text and vector retrieval silently recall the wrong rows.

History has the same shape: `.vhist` frames are stamped with the graph
generation, so a reader at generation *g* must have history through *g* or
`diff()` names commits it does not hold.

So **`committedGeneration` means graph + indexes + history** (S8), and
catch-up does all three. `Indexes.rebuild(reg, store)` exists
(`index.nim:426`), so the v1 path is:

> after graph catch-up, rebuild affected indexes from live records, and
> replay history frames to the same generation.

Honest and expensive. Incremental index replay is a separate design and is
deliberately not attempted here — the failure mode of "sometimes rebuild,
sometimes not" is an index that is subtly stale, which is the one thing an
index must never be.

### 4.5 What shared mode refuses

The notes recommend deferring read-marks; this PRD makes it a refusal rather
than a deferral (S9), because "we haven't solved it yet" is how a WAL
truncation gets shipped by accident:

> **In shared mode: never truncate the WAL, never checkpoint, never
> compact, never renumber, never reclaim ids.**

Not "while a reader might be mid-read" — *ever*, while the database is
opened shared.

That makes the reader side lock-free, which is the entire reason §4.1 could
collapse to one lock:

| | why a reader needs no lock |
|---|---|
| the WAL | append-only, never truncated in shared mode (S9); frames are CRC'd; replay is bounded by `committedLsn` (S7) |
| the snapshot | replaced by write-temp-then-rename, so a reader holding the old descriptor keeps a consistent inode |
| the arrays | the writer is in another process; nothing mutates this store except this process, under its own existing `beginWrite`/`publish` gate |

The limitation writes itself, and `limitations.md` gets it verbatim:

> *A shared graph database grows its WAL until a maintenance open checkpoints
> it.*

On compaction specifically: `PRD-VERSIONING.md` §4.3 already decides that
versioned node ids are never renumbered. Shared mode makes that refusal
broader — *no* ids are renumbered while shared — and this is the moment to
say so, because `reclaim`/`renumberTo` have **no caller in `src/` today**.
The guard is written before the first caller appears, for the same reason
the versioning PRD decided it early: cheap while nothing depends on it.

## 5. Operations, and what each costs

### 5.1 Catch-up is proportional to commits behind, not to the graph

A catch-up replays frames from `lastLsn`. It touches only what changed
between the two generations — the same property G2 asserts for `diff`, and
for the same reason. A reader that has been away for one commit pays for one
commit.

The pathological case is a reader that opens against a 10⁶-node graph with
no snapshot: `open_shared` replays the whole WAL. That is open-time cost,
not steady-state cost, and it is the same cost an exclusive open already
pays.

### 5.2 The stale-writer retry — and who absorbs it

A write transaction must be caught up *before* it starts, must take the
writer lock, and must then **re-check** that nothing moved:

```
write_txn(db):
  catch up if behind
  flock(-lock, EX)
  if load_acquire(shm.committedGeneration) != db.store.generation:
    release; retry                       # someone committed while we waited
  run the normal local transaction
  fdatasync(WAL); append+sync(.vhist)
  store_release(shm.committedLsn, lsn)
  store_release(shm.committedGeneration, g + 1)
  local merge + publish
  release
```

In **S1's single-writer-per-process model this retry is dead code**: the
writer holds the lock for its lifetime, so nothing can displace it. It is
written in S4 with migrating writers, and this PRD says so, because a retry
path that never runs is a retry path nobody has tested.

The remaining real problem is not storage, it is surface. When a writer
*does* lose a race, the existing contract raises `GLY_ERR_STALE`
(`TXN.md` §2). For an agent holding a query handle, that means the query
re-runs from the top. Whether glyphes retries internally or returns a
retryable error is a product decision, and §12 leaves it open rather than
being answered by accident in an implementation.

### 5.3 What is slower in shared mode, stated plainly

| | exclusive | shared |
|---|---|---|
| write txn | atomic CAS on `writerClaim` | `flock` per transaction (S1: once per process) |
| read txn | — | one `load_acquire` of an mmap'd word |
| catch-up | — | replay + **index rebuild** (§4.4) |
| WAL | truncated at checkpoint | grows until a maintenance open (S9) |
| compaction | available | refused (S9) |
| `limitations.md` §6 | "single-process" | shared is a named mode, with the costs above |

The honest cost is §4.4's index rebuild, and it is the reason a shared
reader that is chronically behind is expensive. It is bounded — one rebuild
per catch-up, not per query — but it is real, and it is the first thing to
optimise once the mode exists.

## 6. The surface

Nothing new in 0.1 except the mode. No statement, no Ruby method, no CLI
flag beyond what `open` needs:

- `glyphes_open(path, mode)` gains a shared flag alongside the existing
  `GLY_OPEN_*` bits. Exclusive is the default, so **existing callers do not
  change behaviour**.
- `GLY_ERR_BUSY` when a shared reader attempts a write while an exclusive
  handle holds the lock — named, not silent.
- New pin S10's network-filesystem refusal surfaces as a named open error.

The read surface for shared mode is the same read surface as exclusive mode.
That is the point: an observer runs the *same query* and gets a correct
answer, and nothing in `CYPHER.md` changes.

## 7. Non-goals

- Migrating the writer role between live processes (S4, later).
- Readers surviving a checkpoint (refused, §4.5).
- Incremental index catch-up (§4.4).
- Any notion of a reader *registering* interest, or of the writer knowing
  that readers exist. The writer does not track readers, cannot, and must
  not try.
- Distributed anything.

## 8. Phases

| phase | content | gates |
|---|---|---|
| **S1** | cross-process writer exclusion: `-lock` file, `flock`, held for the life of a writable `Database`. `GraphStore.lastLsn`. **No shm, no reader changes.** | two processes writing concurrently cannot both succeed; a 2-process interleaved write soak produces a graph byte-identical to the same writes from one process; an exclusive open after a shared one is refused by name |
| **S2** | the shm control block, release/acquire, monotonic `committedGeneration` | an arm64 reader never observes an advanced generation with a stale LSN (the release-store sweep, over many iterations) |
| **S3** | `catchUp()`: bounded replay, no snapshot load, no truncate, `publish()` under the existing gate; poison on corruption below `committedLsn` | a reader's answers equal a from-scratch reopen of the same file; a catch-up never applies an uncommitted transaction |
| **S4** | migrating writers: re-check-and-retry, lock lifetime, agent-facing stale policy (§12) | two processes taking turns as writer over 10⁴ alternations produce a valid single history |
| **S5** | derived state in the catch-up: index rebuild, history replay | seek, constraint, text, vector and `diff` answers all agree with an exclusive-mode reopen of the same file |

S1 is the bug fix and ships alone. S2–S3 are the minimum useful shared read.
S4 is what makes the writer role movable. S5 is what makes a shared reader
trustworthy rather than merely non-crashing.

## 9. Risks

| # | Risk | How it is met |
|---|---|---|
| R1 | Two processes both claim the writer and corrupt the graph (§1) | S1, alone, before anything else. It is a live bug in shipped code, not a prerequisite for a feature |
| R2 | `flock` is advisory: a process that ignores it corrupts nothing but gains nothing, and NFS/SMB may not honour it at all | S10 refuses network filesystems by name; the refusal is at open, where it is cheap |
| R3 | A reader applies an uncommitted transaction | S7: replay is bounded by `committedLsn`, never by EOF. This is the bug that would be invisible and is why it is a pin and a gate |
| R4 | On arm64, a reader sees a new generation with a stale LSN (§4.2) | S6 release/acquire, with a gate that runs the bad interleaving on the platform that has it |
| R5 | Indexes silently stale after catch-up | S8: generation means graph + indexes + history; §4.4 rebuilds rather than partially updating |
| R6 | WAL grows without bound in shared mode | S9 makes it a stated limitation rather than an accident; the cost is a maintenance open, which is a workflow, not a bug |
| R7 | Mode is detected rather than declared, and a stale probe takes the fast path | S2: declared at open, no dynamic detection |
| R8 | `lastLsn` drifts and replay double-applies | W9 already makes replay idempotent by LSN (§3.3.1). Correctness comes from the skip rule, not from atomicity |
| R9 | S1 lands and nobody notices for a year, because two-process writes are rare | the 2-process interleaved soak is S1's second gate, not a later one |

R1 and R3 are the two that matter. R1 is certain and present; R3 is the one
that would be discovered by a user.

## 10. Pins

| # | Pin |
|---|---|
| S1 | At most one process may write, enforced by `flock` on `-lock`. Advisory locks are the mechanism, as `WAL.md` W13 already pins |
| S2 | Mode is declared at open. No dynamic sole/shared detection, ever |
| S3 | Exactly one lock fd per `Database`, open for its life |
| S4 | A shared reader holds no lock. It reads an append-only WAL bounded by `committedLsn`, and a snapshot that is only ever replaced by atomic rename |
| S5 | The generation check (§3.1) is the only cross-process read condition. There is no process counting |
| S6 | `committedGeneration` is published with release ordering after `committedLsn` with release ordering. Arm64 is the platform this protects |
| S7 | Catch-up replays at most to `committedLsn`. End-of-file is not a bound |
| S8 | `committedGeneration` means graph **and** indexes **and** history. A reader that caught up only the graph is not caught up |
| S9 | Shared mode never truncates the WAL, never checkpoints, never compacts, never renumbers, never reclaims ids |
| S10 | Network filesystems are refused by name. A database whose correctness depends on POSIX advisory locks does not run on one |

S5 and S9 together are what keep the reader side lock-free. Without S9 the
writer would have to track readers to know it could truncate, and that is
the whole of SQLite's WAL-index — declined on purpose, in writing.

## 11. Gates

Merge conditions, not milestone reviews.

- **SG1** — two processes writing concurrently: exactly one gets the lock,
  the other gets `GLY_ERR_BUSY`, and the graph is byte-identical to the same
  writes issued from one process.
- **SG2** — a 2-process interleaved write soak (readers + a writer) produces
  a graph byte-identical to the single-process equivalent, and never a
  `GLY_ERR_CORRUPT`.
- **SG3** — a shared reader's answers equal an exclusive reopen of the same
  file at the same generation, for every query in `tests/conformance`.
- **SG4** — no catch-up ever applies an uncommitted transaction: kill a
  writer mid-transaction, let a reader catch up, and the reader must not see
  the transaction's writes.
- **SG5** — on arm64, the release-store sweep: many iterations of
  writer-publish / reader-observe, asserting no reader ever sees
  `generation == g+1` with `committedLsn` below *g*'s last frame.
- **SG6** — a catch-up leaves `lastLsn` such that re-running it is a no-op,
  proving W9's idempotence is what the design leans on (§3.3.1).
- **SG7** — a WAL corrupted below `committedLsn` poisons the handle by name;
  a torn tail above it is ignored and the reader continues.

SG4 is the gate that keeps this honest. It is the difference between a
shared reader that is *correct* and one that is *quietly a little ahead*.

## 12. Open questions

1. **The agent-facing stale policy (§5.2).** When a writer loses the race:
   does glyphes retry internally, or raise `GLY_ERR_STALE` and let the
   caller? The storage answer is "retry at S4"; the product answer is open,
   and it should be decided before agents are writing rather than after.
2. **Does `committedGeneration` need a third derived component?** Graph,
   indexes and history (§4.4) is what exists today. If `.vhist` ever gains
   its own derived state, S8 must be amended before it is added, not after.
3. **Is `flock` the right primitive for the reader-side optimisation?** If a
   future phase wants readers to *register* (so a writer could checkpoint
   safely), the answer changes and S9 is the pin that has to be revisited.
   Nothing in S1–S5 needs it.
4. **What does a read-only observer do about `lastLsn` across a reopen?** It
   rebuilds from the snapshot plus the WAL tail. Acceptable, but it is a
   cost that grows if the WAL is long and checkpoints are refused.
5. **Multi-writer within one process** is unchanged and still fine — the
   `Atomic[uint32]` claim is still the intra-process mechanism, and S1 adds
   the inter-process one beside it. Worth a note in `TXN.md` §1 so the two
   are not confused.

## 13. Related documents

- `glyphes_shared_mode_design_notes.md` — the input. This PRD differs from
  it in three places, each argued above: `flock` rather than `fcntl`
  (§4.1, already pinned by `WAL.md` W13); readers take *no* lock rather
  than a byte-range (§4.5, because S9 removes the checkpointer); and
  `lastLsn` atomicity is W9's job, not a critical invariant (§3.3.1).
- `WAL.md` §1, W9, W13 — the lock file, replay idempotence, and `flock`.
  All three predate this PRD and two of them are unimplemented.
- `TXN.md` §1, §2 — single writer and the stale-base contract.
- `PRD-GLYPHES.md` P1, P8 — amended (§status) and preserved respectively.
- `PRD-VERSIONING.md` §4.3 — compaction, decided, and extended by S9.
- `STORAGE.md` §4.7 — compaction that shared mode refuses.
- `limitations.md` §6 — to be rewritten when S1 ships.
