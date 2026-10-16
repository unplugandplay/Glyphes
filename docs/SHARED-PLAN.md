# glyphes — SHARED MODE: the coding plan

> *Close the cross-process hole first, because it is a bug. Then make a
> second process able to read.*

**Implements:** [`PRD-SHARED.md`](PRD-SHARED.md)
**Status:** plan, pre-implementation. No code below has been written. The
`nimble soakShared` and `nimble crashShared` tasks named in the gate tables
do not exist either — they are built with the phase that needs them, and
until then `nimble test` is the whole gate.

This is the order of work, not the argument for it — the PRD carries the
design and the reasoning. Three rules govern the ordering, and each one
exists because of something found while writing the PRD:

- **The bug ships before the feature.** S1 is not groundwork for shared
  mode. It is a correctness fix to a live invariant that is silently false
  across processes, and it retires that risk without a single reader
  changing.
- **The uncertain thing is built first.** Whether `flock` behaves as S1
  assumes — released on process death, held across threads, visible to a
  second process on the same inode — is an empirical question, not a
  design one. S1.1 settles it before anything is built on the answer.
- **No surface until the mechanism holds.** There is no new statement and
  no new Ruby method in this entire plan. The read surface for shared mode
  is the read surface that already exists; that is the test.

---

## 0. The shape of the work

| step | lands | risk it retires |
|---|---|---|
| **S1** | cross-process writer exclusion | two writers, one file |
| **S2** | the shm control block | does the reader ever see a torn generation |
| **S3** | `catchUp()` | is a second process's view correct |
| **S4** | migrating writers | can the writer role move |
| **S5** | derived state in the catch-up | is a caught-up reader *trustworthy* |

S1 is the fix and ships alone. S2–S3 are the minimum useful shared read.
S4 is a capability nobody has asked for yet. S5 is what turns "does not
crash" into "answers correctly".

Roughly: S1 ~250 lines, S2 ~200, S3 ~350, S4 ~250, S5 ~300. Shape
estimates for sequencing, not commitments.

---

## S1 — cross-process writer exclusion

**Goal:** two processes cannot both write one file. Nothing else changes.

### S1.1 — settle the `flock` assumptions empirically (new: `tests/unit/test_lock.nim`)

Before any of S1 is built, answer four questions that decide its shape.
Each is a test written against the real kernel, not a reading of a man
page, because two of them have behaviour that differs between platforms and
one of them is the entire basis of S1's correctness.

1. **Is the lock released when the process dies?** The PRD relies on this
   (WAL.md §1: "OS-released on process death"). If it is not, S1 needs a
   stale-lock protocol and everything gets harder.
2. **Is it released when *any* fd for the file is closed?** `flock` locks
   are per open-file-description on BSD and Linux, so closing a second
   descriptor must *not* drop the lock. If it does on this platform, pin
   S3's dedicated-fd rule becomes load-bearing rather than hygiene.
3. **Do two processes see the same lock?** One process holds `EX`, a child
   spawned separately tries `EX|NB` and must fail. This is the test that
   S1 is actually about.
4. **Does it compose with threads?** A lock held by one thread, contended
   by another, in the *same* process. `flock` semantics here are the ones
   most likely to surprise.

S1.1 is not scaffolding. If (1) fails, the lock is advisory-with-timeout
and S1's gates are different. Build it first and find out.

### S1.2 — the lock file (new: `src/store/dblock.nim`)

One file, one job: the `-lock` file described by `WAL.md` §1 and pinned by
W13.

```nim
type Lock* = ref object
  path*: string
  fd*: File              ## dedicated, never reopened (S3)

proc acquire*(path: string; exclusive: bool): Lock
proc release*(l: Lock)
proc tryAcquire*(path: string): bool    ## LOCK_EX | LOCK_NB, for S1.3
```

`WAL.md` §1 says the file "holds the writer pid". It does not need to: W13
pins `flock` *rather than* pid liveness, and a pid in a file that is
released by the kernel is a debugging aid at best and a stale-value trap at
worst. Write the pid as a comment-length aside for `lsof`-less debugging,
and make the lock itself carry no state.

### S1.3 — wire it to the writer claim (`src/store/store.nim`, `src/txn/txn.nim`)

`claimWriter` (store.nim:349) keeps its `Atomic[uint32]` — that is the
*intra-process* claim and it is correct for what it is. S1 adds the
*inter-process* one beside it:

```
begin(store, wal, id):
    if not tryAcquire(lockPath):  failTxCode(tcBusy, ...)   # someone else has it
    claimWriter(...)          # unchanged, still required
```

Both claims, in that order. The `Atomic` alone is not enough (S1.1.3) and
the `flock` alone is not enough (two threads in one process are invisible
to it). Pin S3 covers the fd; `TXN.md` §1 gets a note so the two are not
confused later (PRD §12.5).

**Do not touch the reader side.** No shm, no generation check, no catch-up.
An exclusive-mode reader's code path is bit-for-bit what it is today
(PRD §3.2).

### S1.4 — `GraphStore.lastLsn` (`src/store/store.nim`)

A new field, set when a commit's frames are durable. Not critical (PRD
§3.3.1: W9 makes a stale value a performance loss, not a correctness
bug) and **not used by anything in S1**. It lands in S1 so that S3 has a
home for it and so the 2-process soak can assert monotonicity from the
start, but it earns its keep at S3.

### S1.5 — `limitations.md` §6

The section's last line ("the soak says nothing about two processes") stops
being true the moment S1 lands, because now two processes *is* enforced.
Rewrite it to say what is enforced and what still is not: one writer
across processes, yes; a reader in another process seeing your writes, no,
that is S3. Getting this right matters more than usual — the honest version
of the old text is what made the gap discoverable (§1).

### S1 gates

| gate | asserts | runs as |
|---|---|---|
| SG1a | two processes, one lock: the second gets `GLY_ERR_BUSY` and the graph is byte-identical to the same writes from one process | `nimble test`, every run |
| SG1b | a 2-process interleaved write soak produces a graph byte-identical to the single-process equivalent, and never a `GLY_ERR_CORRUPT` | new `tests/soak/soak_shared.nim`, 240 s |

**SG1a is the gate that matters.** It is the feature, expressed as the bug
it fixes. SG1b is the version of the existing soak that has two processes
in it instead of threads.

---

## S2 — the shm control block

**Goal:** a second process can learn what the last committed generation is,
without tearing.

### S2.1 — the file and the mapping (new: `src/store/shm.nim`)

`<db>-shm`, mmap'd, two `uint64`s. Nothing else. No header, no version, no
checksum: this file is rebuilt from the WAL on every open, so there is
nothing in it worth validating and a header would only be a thing to get
wrong.

```nim
type ShmBlock* = object
  committedGeneration*: Atomic[uint64]
  committedLsn*: Atomic[uint64]

proc openShm*(path: string): ShmBlock
```

**Zero-filled on create** is a correctness requirement, not a default: a
file of zeroes says "generation 0, lsn 0", and a reader at lsn 0 replays
the whole WAL, which is the right answer for a database whose shm has never
been written. An uninitialised mmap would say something else.

### S2.2 — release/acquire, and the arm64 gate

`store_release(committedLsn, l)` then `store_release(committedGeneration,
g)`; the reader `load_acquire`s the generation. S6, and the reason is in
the PRD §4.2: on x86's TSO the un-synchronised version happens to work and
on ARM it does not.

**SG5 is the gate and it is the one people will be tempted to skip.** It is
a loop: writer publishes, reader observes, assert the reader never sees
`generation == g+1` with a `committedLsn` below *g*'s last frame. Run it
for enough iterations on this arm64 machine that the window is exercised —
the failure is rare by construction, which is exactly why a single-run test
would pass on a broken implementation.

### S2.3 — the writer publishes

In `commit`, after the WAL `fdatasync` and after the `.vhist` append and
sync, before the local merge:

```
store_release(shm.committedLsn, tx.nextLsn)
store_release(shm.committedGeneration, g + 1)
```

After, not before: the frames must be durable before anyone is told they
exist (P8, and PRD §4.3's "before the graph's COMMIT frame" ordering, which
is the same rule seen from the other side).

The generation here is the one `inc s.generation` is about to produce.

---

## S3 — catch-up

**Goal:** a shared reader serves queries from state that includes every
committed generation.

### S3.1 — `catchUp()` (new: `src/store/catchup.nim`)

A sibling to `recover()`, not a mode of it (`recover()` refuses a populated
store, correctly).

```nim
proc catchUp*(s: GraphStore, walBytes: string;
              fromLsn, upToLsn: uint64): CatchUpResult
```

Three differences from `replay()`, each load-bearing:

1. **Bounded above by `upToLsn`** (S7). Never end-of-file. The writer may
   have appended frames for a transaction still in flight, and applying
   them is reading another process's uncommitted data. **This is the bug
   S3 is most likely to ship and SG4 is the gate that catches it.**
2. **No snapshot load, no truncate.** Ever. The caller is a live store.
3. **Returns rather than raises** on a clean stop, and raises
   `glyErrCorrupt` when the damage is *below* `upToLsn` — the writer
   claimed that region was durable.

The lower bound is `fromLsn`, and W9's skip rule does the rest.

### S3.2 — the freshness check, and the shape of the fast path

`GraphStore.beginRead` or `Database`'s statement boundary — decided by
where a `Database` can see `shm.committedGeneration`, because an exclusive
open has no shm it should be reading.

```
before_read_txn:
  if not db.shared: done                      # exclusive is today's path (PRD §3.2)
  g = load_acquire(shm.committedGeneration)
  if g == db.store.generation: done          # the whole condition (S5)
  db.store.beginWrite()                      # the existing local gate
  catchUp(..., from = db.lastLsn, upTo = committedLsn)
  db.lastLsn = committedLsn
  db.store.publish()
  db.store.endWrite()
```

The `if not db.shared` line is the difference between a design that costs
the single-process user nothing and one that costs them a check. It is
there because mode is declared (S2), and S2 exists because a detected mode
is a lie.

**Derived state is not handled in S3.** A catch-up that updates only the
graph leaves indexes stale, and S5 is what fixes it. Until then a shared
reader is *graph-correct and index-stale*, and that must be said out loud
in the mode's documentation rather than discovered. `limitations.md` gets
the sentence, and the mode is named experimental for exactly this reason.

### S3.3 — poison rather than half-catch-up

A `glyErrCorrupt` from `catchUp()` poisons the handle: every subsequent
read raises rather than returning a graph that is half old and half new.
A half-caught-up store answers questions, and its answers are wrong in a
way nothing downstream can detect.

---

## S4 — migrating writers

**Goal:** the writer role can move between live processes. Nothing has
asked for this yet; it is here because the lock's lifetime design in S1
should survive its first real test rather than being retrofitted.

### S4.1 — the lock is per transaction, not per process

Until this lands, S1's lock is held for the life of a writable `Database`.
S4 takes it per write transaction and adds the re-check:

```
write_txn:
  catch up if behind
  acquire(lock, EX)                    # blocks now
  if load_acquire(shm.generation) != db.generation:
      release; retry                   # someone committed while we waited
  ...normal transaction...
```

**The retry is dead code until S4** (PRD §5.2) and this plan says so
rather than writing it early: a retry path that never runs is a retry path
nobody has tested, and the one test it needs is S4.3's.

### S4.2 — `GLY_ERR_STALE` for the caller

A lost race inside glyphes retries. A lost race *at the caller* — an agent
holding a query handle across a statement — raises `GLY_ERR_STALE`, which
already exists (`TXN.md` §2). Whether glyphes should absorb that instead is
PRD §12.1, and it is **decided here, not during implementation**.

### S4.3 — the alternating-writers soak (new: `tests/soak/soak_shared.nim`)

Two processes taking turns as writer, over enough turns that the re-check
window is exercised. This is the only test that runs the S4.1 retry, which
is why the retry is not written until this exists: a retry that ships
without this is a retry that has never been observed to fire.

```
process A: loop { acquire(EX); write; release }
process B: loop { acquire(EX); write; release }
after 10^4 turns: one valid history, byte-identical to the same writes
issued from a single process
```

---

## S5 — derived state in the catch-up

**Goal:** a caught-up shared reader is trustworthy, not merely
non-crashing. Until this lands, S3's reader answers graph queries correctly
and index queries incorrectly.

### S5.1 — indexes rebuild after graph catch-up

`Indexes.rebuild(reg, store)` exists (index.nim:426). The honest v1: after
a catch-up, rebuild the affected indexes from live records.

Deliberately **not** incremental. "Sometimes rebuild, sometimes not" is an
index that is subtly stale, which is the one thing an index must never be,
and an incremental index replay is its own design with its own gates.

Cost: one rebuild per catch-up. Bounded, but it is the real price of shared
mode and it belongs in `limitations.md` rather than in a comment.

### S5.2 — history rides the same pass

`.vhist` frames are stamped with the graph generation, so a reader at
generation *g* needs history through *g* or `diff()` names commits it does
not hold (S8). History replay is currently open-time only
(`replayHistory`, database.nim); it becomes callable from a catch-up.

---

## Gates

| gate | asserts | runs as |
|---|---|---|
| SG1a | second writer gets `GLY_ERR_BUSY`; graph byte-identical to one process | `nimble test`, every run |
| SG1b | 2-process interleaved write soak matches the single-process graph | `nimble soakShared`, 240 s |
| SG5 | on arm64, no reader observes `generation == g+1` with a stale `committedLsn` | `nimble test`, every run, many iterations |
| SG3 | a shared reader's answers equal an exclusive reopen at the same generation, every conformance query | `nimble test` |
| SG4 | a catch-up never applies an uncommitted transaction: kill a writer mid-transaction, let a reader catch up, the reader must not see its writes | `nimble crashShared` |
| SG6 | re-running a catch-up is a no-op (W9's idempotence, which the design leans on) | `nimble test` |
| SG7 | corruption below `committedLsn` poisons by name; a torn tail above it is ignored | `nimble test` |
| SG2 | two processes alternate as writer over 10⁴ turns and produce one valid history | `nimble soakShared`, long |

**SG4 is the gate that keeps this honest.** It is the difference between a
shared reader that is *correct* and one that is *quietly a little ahead* —
and S7's upper bound is exactly the kind of thing that passes every other
test in this plan.

SG5 is second, because it is a race that is rare by construction and a
single-run test would pass on a broken implementation.

---

## What is deliberately absent

- **A new statement, Ruby method, or CLI.** None. The read surface for
  shared mode is `CYPHER.md` as it stands; if a shared reader needs new
  surface to be useful, that is a finding, not a plan.
- **Incremental index catch-up** (S5.1), read marks, WAL truncation while
  shared, compaction while shared (S9), network filesystems (S10).
- **The agent-facing stale policy** (PRD §12.1) beyond S4.2's decision
  point.
- **Anything about branching.** `PRD-VERSIONING.md` V2 is orthogonal and
  neither plan should wait for the other.

---

## Risks, in the order they would bite

| when | risk | response |
|---|---|---|
| S1 | `flock` is not released on process death, so a crashed writer wedges the database permanently | S1.1 settles it before anything is built; if it fails, the stale-lock protocol is S1's first task, not a surprise in S4 |
| S1 | the `flock` is advisory and some caller ignores it | S10 refuses network filesystems by name, where advisory locks are unreliable; a local process that ignores it is a bug in that process |
| S3 | catch-up reads to EOF and applies an uncommitted transaction | S7 bounds it by `committedLsn`; SG4 kills a writer mid-transaction to prove it |
| S3 | a reader is index-stale after catching up, and nobody knows | named in `limitations.md` at S3; the mode is experimental until S5 |
| S2 | arm64 store reordering publishes a generation with a stale LSN | S6 release/acquire; SG5 runs the interleaving many times |
| S4 | the retry loop is untested because it never runs | S4.3's 10⁴-turn soak exists for exactly this |
| S5 | WAL grows without bound in shared mode | S9's stated limitation, not a surprise: a maintenance open checkpoints it |

---

## Related

- [`PRD-SHARED.md`](PRD-SHARED.md) — the design this implements
- [`glyphes_shared_mode_design_notes.md`](glyphes_shared_mode_design_notes.md) —
  the input this PRD departs from in three places, each argued there
- [`../limitations.md`](../limitations.md) — §6 is rewritten at S1.5
- [`WAL.md`](WAL.md) — §1, W9, W13: the lock file, replay idempotence and
  `flock`, all specified before this plan and two of them unimplemented
- [`TXN.md`](TXN.md) — §1 single writer, §2 the stale-base contract
- [`../DEVLOG.md`](../DEVLOG.md) — an S-entry per milestone
