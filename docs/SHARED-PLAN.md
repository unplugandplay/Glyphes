# glyphes — FOLLOWERS: the coding plan

> *One writer, many followers. Make the watermark trustworthy, then give a
> second process the timeline — and nothing else.*

**Implements:** [`PRD-SHARED.md`](PRD-SHARED.md)
**Reasoning:** [`DISCOVERY-SHARED-MODE.md`](DISCOVERY-SHARED-MODE.md)
**Supersedes:** this document's earlier form, which planned S3–S5 as
catch-up into the writer's arrays. Those phases assumed a follower wants the
live graph; the log does not contain one, so they are gone. See PRD §13.

**Status:** plan. F0 and F1 are done; **F1.0 settled the barrier question**
(the gate was red for a while and the barrier turned out to have been correct
— see below). F2 is next. The `nimble crashFollower` task named in the gate
table does not exist yet; it is built with F2, and until then `nimble test` is
the whole gate.

Two rules govern the ordering, both learned the hard way in the discovery:

- **The uncertain thing first, and prototype it before designing around it.**
  F1's entire mechanism is one memory-ordering question that is currently
  answered *wrong* on this platform. Everything a follower does rests on
  being able to trust the watermark, so F1.0 settles the barrier with two
  competing implementations before either is wired in.
- **Reuse before new.** A follower is not a new subsystem; it is
  `replayHistory` with a different bound and no store. F2 is mostly a
  refactor of shipped V1 code, which is why the phase list is as short as it
  is.

---

## 0. The shape of the work

| step | lands | risk it retires |
|---|---|---|
| **F0** | cross-process writer lock (S1, shipped) | two writers, one file |
| **F1** | the watermark: mmap, publish, observe | can a follower trust the marker (done; barrier settled) |
| **F2** | a follower: read-only open, replay to the watermark | is the timeline correct |
| **F3** | the follower's read APIs | is it *usable*, not just correct — **done** |

F0 shipped in `309dc8d`; F1 is done. F2–F3 are small because they reuse V0's
revision store and V1's frame decoder wholesale.

Roughly: F1 ~200 lines, F2 ~250, F3 ~200. Shape estimates, not commitments.

---

## F1 — the watermark

**Goal:** one 16-byte sidecar that a follower can trust, published by the
writer after its frames are durable.

### F1.0 — settle the barrier by prototype, before designing around it

SG5 fails today. The suspicion is the *storage*, not the protocol: the block
is reached by `cast[ptr Atomic[uint64]]` over an `mmap` pointer, and Nim's
`Atomic[T]` presumes it owns the memory it sits in. Two candidates, both
written as small standalone programs before either is adopted:

- **(a) an explicit intrinsic** — `__atomic_store_n(p, v, __ATOMIC_RELEASE)`
  / `__atomic_load_n(p, __ATOMIC_ACQUIRE)` via `importc`, on a `volatile`
  word. Obviously correct, portable across clang/gcc, and says exactly what
  it does at the cost of hand-written FFI in a codebase that has none.
- **(b) a shared struct** — declare `ShmWords = object; lsn, gen: Atomic[uint64]`
  and map so the struct *is* the mapping, then access
  `cast[ptr ShmWords](base).gen`. Nim's assumptions about an `Atomic` that
  is a field of a real object hold; whether they survive being at the base of
  a mapping is the question.

Pick on **evidence**: whichever makes SG5 green over ≥10⁶ iterations on this
machine, with the loser documented in the commit that adopts the winner. If
both are green, take (b) for readability and note that (a) is the fallback
if a future compiler ever elides it.

This step is first because a follower built on a watermark that lies is
worse than no follower: it stops checking, silently.

### F1.1 — the sidecar (`src/store/shm.nim`)

Two `uint64`s in a `MAP_SHARED` mapping at fixed offsets (already laid out;
`ShmSize = 16`, `committedLsn` at 0, `committedGeneration` at 8). Writer
publishes LSN then generation, both release; follower loads the generation
with acquire. Reworked on whichever primitive F1.0 picks.

- **Zero-filled on create** is a correctness requirement, not a default: a
  block of zeroes means "nothing committed", so a follower replays the whole
  log, which is the right answer for a database whose watermark has never
  been written.
- **No header, no version, no checksum**: the file is rebuilt from the WAL,
  so there is nothing in it to validate and a header is only another thing to
  get wrong.
- **Never unlink the shm** while a follower may have it mapped. An unlinked
  mapped file is a `SIGBUS` on the next access, not an error return. The
  writer does not unlink it; only test teardown does.

### F1.2 — publish in `commit`

Already wired (`txn.commit`, after `wal.sync()` and after the `.vhist` sync,
before the merge is published to the writer's own readers). Keep the
ordering comments that explain *why* it is there — after the frames are
durable, before the write lock is released — because both halves are
load-bearing and neither is obvious.

### F1.3 — the read-only open maps the shm

Today `openDatabase` gates replay, the lock, and the shm behind
`not memory and not readOnly`, so a read-only `Database` has **no history and
no watermark** — it is exactly the follower we need and currently gets
nothing. Split the gate: a read-only open maps the shm (and in F2 replays to
it) but never takes the lock and never opens `.vhist` for append.

Gates: **SG5** (green, ≥10⁶ iterations, per F1.0), plus a read-only open
sees the writer's committed generation.

---

## F2 — a follower

**Goal:** a second process can hold the timeline and query it.

### F2.0 — the design question: replay or index?

F2 is small only if the right choice is made here, so it is made explicitly
rather than discovered mid-phase.

The shipped `replayHistory` already does almost everything a follower
needs: it opens `.vhist`, walks the frames, and replays them into a
`Revisions` in the writer's own open/seal sequence. A follower differs in
exactly three ways — the bound is `shm.loadGeneration()` instead of
`store.generation`, the target is a standalone `Revisions` rather than
`store.history`, and it never writes (no append handle, no truncation).

- **Replay-on-open** is the version that already exists. Cost is O(history)
  per follower open. For a follower that opens once and stays up (an audit
  session, an eval harness) that is fine, and it is a few dozen lines.
- **Index-and-read-lazily** — mmap `.vhist`, keep a small index
  (commit id → frame offset, generation, parent, changed set), and decode
  frames only for the ids a query touches. `diff(a, b)` needs only the
  changed sets; `stateAt` needs one node's chain. This is O(history) to
  *index* and O(changed) to *answer*, so it wins for a follower that opens
  and closes per query.

Recommendation: **replay-on-open for F2** (it is a refactor of shipped code
and every gate in F3 is about correctness, which is easier to trust when the
follower and the writer build their histories by the same code path); then
an index as an optimisation with its own gate, only if a follower is ever
measured opening more than once per history.

### F2.1 — `openFollower(path): Follower`

(`replayVhist` is already exported; `decodeCommitPayload` is not, and a
follower needs it — that is a one-line export change, listed here so it is
not rediscovered as a mystery.)

A new type in a new module (`src/store/follower.nim`), not a `Database`
flag: a follower cannot write, must not be able to acquire the writer lock,
and its whole surface is history. Open:

1. map the shm, read the watermark (acquire);
2. read `.vhist` frames up to the watermark, **never to EOF** (PRD F5) —
   a frame beyond the watermark is a commit the graph has not accepted;
3. replay into a fresh `Revisions` in the writer's open/seal sequence, so a
   follower's history is byte-identical in shape to the writer's;
4. refuse on corruption *below* the watermark; tolerate a torn tail above it
   and truncate nothing (a follower never writes).

### F2.2 — refuse what a follower cannot answer

A `Follower` has no `Database`, no store, no query surface, and its
`stateAt` is the *revision store's* `stateAt` — the history one, not the
graph's. This is the structural half of PRD F2: the follower cannot be
mistaken for a reader because it has nothing to read the graph with. A
`MATCH` on a follower is a compile error, not a runtime refusal, and that is
the point.

Gates: **SG6** — a follower's `stateAt`/`diff` equal a from-scratch replay
of the same frames on a randomized workload; **SG7** — after a crash
mid-commit, a follower reconstructs exactly the acknowledged commits and is
off by the unacknowledged one.

---

## F3 — the follower's read surface — DONE

**Goal:** the timeline is usable.

- `followAt(commit, nodeId) -> NodeState` — what did this node look like at
  commit C.
- `followDiff(a, b) -> seq[DiffEntry]` — O(changed), the same `diff` the
  writer has, over a history that was rebuilt rather than accumulated.
- `commitsUpTo(generation) -> seq[CommitRef]` — the timeline's spine, for
  an audit view or an eval harness that wants to walk it.

No Cypher, no `MATCH`, no projection: a follower answers questions about
history and nothing else (PRD F2). The gate is that every answer equals a
from-scratch reconstruction of the same commit — the same bar V0's oracle
set, on the same structure.

Gate: **SG8** — read-only cannot write; the follower never holds the write
lock (the cheap regression guard for F0 from the other side).

---

## Gates

| gate | asserts | runs as |
|---|---|---|
| SG1a/SG1b | writer lock (F0, shipped) | `nimble test`, `nimble soakShared` |
| **SG5** | a follower never sees a generation paired with a stale LSN, ≥10⁶ iterations | `nimble test` — **green**, F1.0 |
| SG6 | follower's `stateAt`/`diff` == the writer's own history | `nimble test` — **green**, and proved to catch a 1-bit corruption |
| SG7 | crash mid-commit → follower off by exactly the unacknowledged commit | `nimble crashFollower` |
| SG8 | follower cannot write; never holds the lock | `nimble test` — **green** |

**SG5 is the gate that keeps this honest**, and it is the only one whose
failure is invisible to every other test: a watermark that lies produces a
follower that is confidently, silently behind, which is the exact failure
this whole feature exists to avoid. It was red for two failures — both of them
the test's setup — and it stays in the suite for that reason.

## What is deliberately absent

- **Edge, label and index revisions.** PRD §5 — the log is node history, and
  a follower is a timeline, not a mirror. This is what makes a follower's
  empty graph a structural guarantee rather than a policy.
- **Concurrent writers, per-branch node-id spaces, diff-as-three-way-merge.**
  PRD §7 — a separate document.
- **A follower that materialises a partial graph.** PRD F2, and §12.2 of the
  PRD keeps the door open for when edge history lands, with the rule that
  "for the subset the log covers, refuse the rest" is a harder contract than
  either alternative.
- **A Cypher surface on a follower.** Structural (F2.2), not a refusal.

## Risks, in the order they would bite

| when | risk | response |
|---|---|---|
| F1 | the barrier is elided or the store reorders, and a follower bounds its replay short and does not know it | F1.0 prototypes both fixes and picks on evidence; SG5 is the gate and it is red until it is green |
| F2 | a follower replays past the watermark and applies a commit the graph rejected | bound strictly by `shm.loadGeneration()`, never EOF (F5); SG7 is the crash that proves it |
| F2 | the follower's history diverges in shape from the writer's, so `diff` means different things before and after a restart | replay through the writer's own open/seal sequence; SG6 is the equality |
| F2 | the follower is mistaken for a peer and someone writes to it | no store, no lock, no `Database`; the wrong thing is a compile error (F2.2) |
| F3 | a follower query is asked something the log cannot answer and returns a partial graph answer | empty graph by construction; the answer is "not a graph database", from the type |

## Related

- [`PRD-SHARED.md`](PRD-SHARED.md) — the design this implements
- [`DISCOVERY-SHARED-MODE.md`](DISCOVERY-SHARED-MODE.md) — how the design was
  arrived at; read before implementing, it is where the surprising constraints
  come from
- [`PRD-VERSIONING.md`](PRD-VERSIONING.md) — the log, the revision store and
  the oracle this follower reuses
- [`WAL.md`](WAL.md) §1, W9, W13 — the lock, replay idempotence, `flock`
- [`../limitations.md`](../limitations.md) §6 — updated at F2
