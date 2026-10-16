# Discovery — how shared mode turned out to be a follower feature, not a
> graph-sharing feature

> *The record of what was proposed, what was checked, and what the checking
> found. Written before the implementation, revised after it, and kept
> because the sequence of wrong turns is more useful than the final shape.*

**Status:** discovery, companion to [`PRD-SHARED.md`](PRD-SHARED.md).
This document carries the *reasoning that produced* the PRD; the PRD carries
the *decision*. Where they disagree the PRD leads.

This is written in the first person deliberately. The house style elsewhere in
`docs/` is impersonal, and it should be. This one document's job is to be
honest about a specific failure mode — a design that was right-sounding, was
checked against the code, and was wrong several times over — and that is hard
to do in a voice that never admits anything.

---

## 1. The arc, in the order it happened

**First proposal (mine).** "Alone vs shared" is *freshness of my published
generation*, not "how many processes are attached". Add a `-shm` sidecar with
`committedGeneration`/`committedLsn`, give readers one flag array to
read and writers an `fcntl` lock, and let a reader catch up by replaying the
WAL from its last LSN. I was confident this was the elegant framing and
said the generation check would be *free*, so no fast path would be needed.

**Design notes (the user's).** Five corrections, most of them better than my
proposal. Read them before writing anything.

**Verification.** Every design claim checked against the tree, and against the
kernel where the claim was about the kernel.

**S1 (shipped, `309dc8d`).** The cross-process writer lock, which turned out
to be the one part of this that was never in doubt — it was a live bug and
now it is fixed.

**The three constraints (the user's).** A watermark is still required; the
second-handle bug is a prerequisite (which I believed was still open — it was
not, S1 had just closed it); and the log is node history, not graph history.

**The inversion.** Because the log is node-only, the follower's arrays must be
*empty*. That is the whole rewrite.

---

## 2. Where reality disagreed with the design

Every row is a claim that was checked in the tree or against the kernel
before being believed. Several claims did not survive.

| claim | reality | where |
|---|---|---|
| "the writer claim needs `fcntl` byte-range locks" | `WAL.md` W13 **already pinned `flock`**, and §1 already listed a `-lock` file | `WAL.md` §1, W13 |
| "there is a locking mechanism to extend" | `rg "flock\|fcntl\|lockf" src/` returned **nothing**. The design was written down years ago and never built | `src/` |
| "`flock` is bindable from Nim" | Nim binds `LOCK_EX`/`LOCK_NB` but **not `flock(2)`**. Had to `importc` it with `<sys/file.h>` | `std/posix` |
| "`fcntl` is safer for stale locks" | `fcntl` locks are *process*-associated and drop when any fd for the inode closes. `flock` locks are per *open-file-description* and survive it. `flock` is the safer primitive here | S1.1 probe 2 |
| "a crashed writer needs a stale-lock protocol" | `flock` **is** released on process death (probe 1), so no stale-lock protocol is needed at all | S1.1 probe 1 |
| "the `Atomic` claim and the lock are redundant" | probe 4: `flock` **also** excludes a second *thread* in the same process. They cover different axes; both are needed | S1.1 probe 4 |
| "`lastLsn` must be atomic with `generation` or you double-apply" | `WAL.md` W9 **already** makes replay idempotent by LSN (`replay()` skips `f.lsn <= fromLsn`). A stale `lastLsn` replays already-applied frames as no-ops. I was wrong; so was the design note that said the same thing | `recover.nim` |
| "`recover()` has to be rewritten for followers" | `recover()` correctly refuses a populated store, but `replay(s, bytes, fromLsn)` **already** has the incremental signature. The primitive was there; only the policy was missing | `recover.nim` |
| "the store tracks an LSN" | it did not. `rg lsn src/store/store.nim` was empty. Added by S1.4 as a *performance* field, not a critical one | S1.4 |
| "the follower's catch-up can run against the store" | a second `Database` handle on one file opened fine and each handle claimed the writer independently. Two write refs over one node-id space | `PRD-VERSIONING` §12, fixed by S1 |
| "the shm's `committedGeneration` can be read with a plain store/load" | this is an **arm64** codebase. Stores to different addresses may be observed out of order; only the release/acquire pair makes the pairing a property of the machine | `uname -m`, PRD §4.1 |

The last one is the one that would have shipped silently. The rest were found
by reading; that one was found by running.

---

## 3. Where I was wrong, specifically

- **"The generation check is free, so no fast path is needed."** Clever and
  wrong in the same breath. Declaring mode at open makes the exclusive path
  *bit-for-bit today's code path* — no new branch, and therefore no new way
  to be wrong, in the single-process case most users run. That is a stronger
  guarantee than "the check is cheap", and the design notes got there first.

- **"`lastLsn` is an atomicity hazard."** It is not; W9 already settles it. I
  asserted a hard invariant that the code had never required, and the PRD
  now records the correction rather than the claim.

- **The S1.1 cross-process probe reported that `flock` did not exclude a
  second process.** That would have meant S1 was built on sand. It was the
  probe's own plumbing: no pipe between parent and child, the answer read
  from the wrong file descriptor, and a bare `fork` (which shares open file
  descriptions, so it would have "passed" for the wrong reason anyway). The
  gate exists to catch a broken harness masquerading as a broken kernel, and
  on the day it did exactly that.

- **SG5's first failure was my test, not the code.** `loadGeneration` was
  reading `lsnWord` — a copy-paste slip two lines apart — so every test that
  published a generation got the LSN back. The copy-paste was found by the
  invariant (`lsn >= gen * 10`) failing, which is the shape assertion doing
  its job one layer below where the mistake was.

---

## 4. The discovery that changed the design

The commitment to build history for followers — `CommitRecord`s, branches,
`diff`, a durable `.vhist` sidecar — was made without asking what was
actually *in* the sidecar. When I finally did:

- `Revision` carries a commit id, a property delta, a removed-key list, and
  a liveness bit. It does not carry an edge, a label, or an index.
- `histNoteSet`/`histNoteRemoved`/`histNoteLive` are called only from the node
  write paths (`createNode`, `deleteNode`, `setNodeProp`, `removeNodeProp`).
  The edge paths (`setEdgeProp`, `deleteEdge`) do not touch the revision
  store, deliberately (PRD-VERSIONING §7).
- Indexes are never in the log at all (W5); they rebuild from live records at
  open.

So the log is **node history, not graph history**. The design in the first
PRD draft — "a follower catches up into the writer's arrays" — would have
produced a follower that answers `MATCH (a)-[:KNOWS]->(b)` from node
properties alone, and is wrong without any way to know it. That is the
failure mode this exercise was meant to avoid, and the draft had walked
straight into it.

The fix was to invert one thing. The draft's §3.2 made the follower's arrays
the goal; the rewrite makes them **empty**. A follower is a timeline, not a
mirror. Everything follows from that:

- a follower cannot half-answer a Cypher query, because it has no graph to
  answer from — the refusal is structural, not a policy;
- the phases collapse from watermark → catch-up → migrating writers →
  derived state, to watermark → replay-to-watermark → history read APIs,
  none of which touch the writer's arrays;
- the honesty problem ("this is not a full graph") becomes a product
  statement ("this is a timeline, and here is what a timeline can answer").

The "audit, diff, forensics, decision replay, observability" column in
PRD §5 is only trustworthy *because* of the empty-arrays decision. Without
it, those five capabilities are true only on a graph the log happens to
cover.

---

## 5. What is still open, and why it is the open thing

The watermark's own gate, SG5 — "a follower never observes a generation
paired with a stale LSN" — is **red**: two violations in 200 000
publish/observe iterations. The suspicion is not the protocol but the storage:
the block is reached by casting an `mmap` pointer to `ptr Atomic[uint64]`, and
Nim's `Atomic[T]` presumes it owns the memory it sits in. Two fixes are on
the table — a real `__atomic_*` intrinsic on a `volatile` word, or a shared
struct whose address *is* the word — and neither has been prototyped.

This is recorded as a finding rather than a schedule slip, for a reason: the
watermark is the entire mechanism (PRD §4), and a watermark that publishes a
generation a follower cannot trust is *worse than no watermark*, because the
follower stops checking. Followers (F2) do not start until this gate is green.

The red gate is also the most direct evidence for constraint C1 in the user's
notes — the watermark is not a formality that can be waved through; it is the
one part of the feature where getting the memory ordering wrong produces a
follower that is confidently, silently behind.

---

## 6. Method, as a finding in its own way

Every design claim in this document was checked against the tree or the
kernel before being believed, and roughly a third did not survive. The
sequence that produced the useful errors was always the same:

1. write the claim down;
2. check it (`rg`, a probe, a five-line program, a two-process test);
3. where it failed, find out *which* thing was wrong — the claim, or the
   thing that was supposed to be right;
4. record both, so the next reader does not have to.

The step that matters most is (3). "The probe says the lock does not work"
and "the probe is broken" are both "the test failed", and only one of them
is about the code under test. Both times in this exercise that mattered — the
S1.1 probe and the first SG5 failure — the answer turned out to be the
harness. A gate that reports the wrong thing is not a slow gate, it is a gate
that trains you to ignore it.

---

## 7. Where this leaves the product

One graph, one writer process, and any number of read-only followers of its
commit history. The follower is not a peer database and not a mirror; it is
the record of what the agent did, in a form that can be diffed, audited and
replayed, and that a second process can read without ever touching the live
arrays.

What that does not include — second-process graph queries, concurrent
writers, edge history — is named explicitly in PRD §5, with the specific
reason each is out of scope, so that the next person to want it starts from a
cost rather than from a discovery.
