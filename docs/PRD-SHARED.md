# glyphes — PRD: followers

> *One writer, many followers. The writer publishes an append-only commit
> log; a follower reads it to learn what an agent did, and why.*

**Status:** PRD, pre-implementation for the follower half. Every *pin* is
normative; every *gate* is a merge condition. Where code and this document
disagree, this document leads.

**Preamble:** [`DISCOVERY-SHARED-MODE.md`](DISCOVERY-SHARED-MODE.md) carries
the record of how this positioning was arrived at — the claim-vs-code table,
the three things I got wrong, and the discovery (the log is node history, not
graph history) that inverted the design. Read it before implementing; this
document is the decision, that one is the reasoning, and the reasoning is
where the surprising constraints come from.

This **supersedes** the positioning in the first draft of this document, which
was *"two or more processes on one graph file, with exactly one of them
writing at a time, and every other process seeing committed state rather than
its own stale copy."* That was wrong about what the second process is for,
and wrong in a way that would have cost a phase to discover: it assumed a
follower wants to **query the graph**, which is not true, because the commit
log does not contain the graph (§5).

**Positioning, restated:**

> **Glyphes shared mode is not multi-process embedded graph access. It is one
> writer process plus read-only followers of an append-only commit log.
> Branches are audit trails, not concurrent writers.**

The product framing is *one graph per one agent*. A second process is not a
peer database. It is an observer, an auditor, an evaluator, and a debugger —
following the agent's commit history.

`PRD-VERSIONING.md` built the log this observes. `PRD-GLYPHES.md` pin P1 ("One
file, one process") is **amended**: still embedded, still no server, still one
file plus sidecars — but the *second process* is now supported, as a reader.
P8 (atomic, fsynced commit) is untouched and is the foundation of §4.

---

## 1. What this is

**A durable, queryable, append-only record of what a writer process did, and
a way for another process to follow it without ever touching the graph.**

Three things are already true and are the entire asset:

1. **Every commit is recorded.** `txn.nim`'s write paths note each node it
   changes; `commit` folds those notes into one `CommitRecord` with a
   `changed` set, a per-node property delta, and a liveness bit.
2. **The record is durable.** `.vhist` is append-only, framed like the WAL,
   CRC'd, and survives the process.
3. **Comparing two commits is cheap.** `diff(a, b)` costs what *changed*, not
   what exists — measured flat at ~1× between a 10⁴-node and a 10⁶-node
   graph (G2).

What is missing is the smallest possible thing that lets another process know
*how far it is safe to read* — and the decision, taken here, that the follower
reconstructs **history** rather than the graph.

### 1.1 The three constraints this design answers

**C1 — A follower needs a committed watermark.** `.vhist` is written inside
the commit's fsync, *before* the log's COMMIT frame (PRD-VERSIONING §4.1). That
ordering is a pin: history is never behind the graph, because a history that
silently omits a commit is the one incoherence this feature cannot have. The
price is the mirror case — a crash between the two leaves a commit in the log
that the graph never accepted. Replay already stops at the first frame the
graph has not reached, so *this process* repairs itself. **A follower
cannot**, because it never sees the graph's generation. It needs a published
marker: "safe through generation G, lsn L". That marker is this document's
entire mechanism, and it is 16 bytes.

**C2 — Two write refs over one node-id space is a correctness bug, and it is
closed.** `PRD-VERSIONING.md` §12 recorded that a second `Database` handle on
one file opened successfully, each handle claiming the writer independently.
This was the live bug S1 fixed (`309dc8d`): an exclusive `flock` on a `-lock`
file, taken at open. S1.1's probes confirmed on this platform that `flock`
excludes a second process *and* is released on process death, so no stale-lock
protocol is needed; and because `flock` locks are per open-file-description,
it also excludes a **second handle in the same process**, which is exactly the
second-handle bug. It is now covered by a test. *This PRD does not treat C2 as
work; it treats it as done and says so, because a plan that re-derives a
closed bug wastes the reader's trust in the rest of it.*

**C3 — What the log contains is node history, not graph history.** `Revision`
carries a commit id, a property delta, a removed-key list, and a liveness bit.
`histNote*` is called from the node write paths only; **edges, labels and
index state are not recorded**, deliberately (PRD-VERSIONING §7). So a
follower can reconstruct *what each node was, and when it changed*. It cannot
reconstruct a graph. §5 is the honest boundary, and it is not a to-do list —
it is the product.

## 2. What this is not

- **Not multi-process graph access.** A follower does not `MATCH` the live
  graph. It reads a log.
- **Not concurrent writers.** One writer process, held by a lock. Branches are
  names for audit trails (§7), not heads that two agents write against.
- **Not a server, a protocol, or a wire format.** POSIX files and `flock`.
- **Not a replacement for the single-process engine.** A single-process
  database is unchanged and pays nothing (§6).

## 3. The model

### 3.1 The follower has its own revision store and nothing else

A follower opens the database **read-only** and builds a private
`Revisions` — the same structure the writer keeps in memory, the one V0 built
and the oracle tests — by replaying `.vhist` frames up to the watermark. It
never mutates the writer's arrays, never takes the write lock, never replays
into a live store.

```
open_follower(path):
    s = openShm(path)                       # the watermark (S1.5)
    hist = initRevisions()
    frames = read .vhist frames
    for each frame with generation <= s.watermarkGeneration:
        apply to hist                       # the writer's open/seal sequence
    # the follower's graph stays empty, on purpose (§5)

before_follower_query():
    g = shm.loadGeneration()                # acquire
    if g == follower.generation: done
    replay new .vhist frames up to g
```

This is small because it reuses the whole of `PRD-VERSIONING` V0 — the
revision store, `stateAt`, `diff` — none of which knows or cares that the
frames came off a disk rather than out of a transaction. `stateAt` and `diff`
on a follower are the *same functions* as in the writer.

### 3.2 The follower's graph is empty, and that is the point

A follower has no `nodes`, no `edges`, no indexes. It is a **timeline**, not a
mirror. This is the decision that makes the whole thing small, and it is
correct rather than a compromise because the log does not contain the graph
(C3): a follower that tried to answer `MATCH (a)-[:KNOWS]->(b)` would be
answering from node properties alone and would be **wrong**, silently. An
empty graph refuses; a partial graph lies.

## 4. Mechanism: the watermark

The entire mechanism is two `uint64`s in an mmap'd sidecar.

```
<db>-shm, 16 bytes, MAP_SHARED:
    0   committedLsn         uint64
    8   committedGeneration  uint64
```

Written by the writer, after its WAL frames are fsynced and after `.vhist` is
synced, and before it releases the cross-process write lock. Read by every
follower.

### 4.1 Why release/acquire, and why this platform makes it load-bearing

Publishing is: store the LSN, then store the generation, both `moRelease`.
Observing is: `load_acquire` the generation.

On x86 the naive "write the generation last" would work by accident, because
Total Store Ordering makes stores expensive to reorder. **This is an arm64
codebase**, where stores to different addresses may be observed out of order,
and the same code lets a follower see `generation == G+1` with a
`committedLsn` that still names *G*'s last frame — so it bounds its replay
one commit short and never knows it missed one. The release/acquire pair is
not decoration; it is the difference between "caught up" and "silently
behind".

### 4.2 The gate was red, and it was the test that was dirty

**SG5 — "a follower never observes a generation paired with a stale LSN" —
failed with two violations in 200 000 iterations.** It does not now, and the
reason is worth recording precisely, because it is the third time in this
feature that a broken test looked like a broken kernel.

F1.0 prototyped the two plausible barriers — the shipping
`cast[ptr Atomic[uint64]]` and a shared struct whose address is the mapping —
and both hold: **0 torn observations over 3 000 000 publishes, repeated.** The
`__atomic_*` intrinsic variant was built and then removed from the bench
because its stores were not landing, which made it a probe bug rather than a
candidate result.

The actual cause was the test's own setup. `freshShm` removed `<db>` but not
`<db>-shm`, so the watermark sidecar from the *previous run* survived; the
reader saw yesterday's generation while the writer republished from 1, and
the first couple of observations read as a torn pair — **deterministically 2,
every run**. Removing the sidecar made the gate green, and it is green across
repeated full-suite runs.

The barrier was correct throughout. What this establishes is narrower than
"the barrier is safe": cast-`Atomic` over borrowed `mmap` memory *works* on
this compiler and target, which is a fact about the toolchain rather than a
guarantee from Nim's `Atomic[T]` contract. `tests/lock/barrierprobe.nim` is
kept so the claim is checkable rather than remembered.

The ordering itself is unchanged and still load-bearing: LSN then generation,
both release, observed with acquire (S6). Nothing in this section relaxes it.

**F1.3's read-only open found a second one, and it was in the library.** Mapping
the watermark for a follower meant calling `openShm`, and `openShm` *creates*
the block when absent — which is right for the writer and wrong for the
reader. A follower attaching to a database with no watermark got one
manufactured, zero-filled, reading generation 0: a follower that reported
"caught up to generation 0" and then watched nothing, with total confidence.
The function that made this invisible was one that appeared to succeed.

So the mapper is split: `openShm` (writer, creates) and `openShmReadOnly`
(follower, `O_RDONLY`, never creates, raises if the block is absent). A
read-only open that finds no watermark sets `shmUnavailable` and is otherwise
a normal open — the watermark is additive, its absence costs the *history*,
not the data — but the follower is *told*, because the alternative is a
follower that cannot tell the difference between "generation 0" and "no
watermark at all".

## 5. What a follower can and cannot do — the honest boundary

This is the section that decides the product. It is a boundary, not a
roadmap: the "not yet" column is what makes the "good" column truthful.

**Good today, from node history alone:**

| capability | why it works | caveat |
|---|---|---|
| **audit** — who changed what, when | every commit names its branch and lsn; every changed node is in `changed` | — |
| **diff two commits** — `O(changed)`, measured flat on 10⁶ nodes | the `changed` delta sets | node properties only |
| **forensics on a value** — when did `status` last change, from what | property deltas per node | — |
| **agent decision replay** — what did the agent know at commit C | `stateAt(node, C)` | the agent's *knowledge*, not its full input set |
| **observability / timeline** | the log itself | — |

**Not supported, and why:**

| not supported | because | required for it |
|---|---|---|
| `MATCH (a)-[:KNOWS]->(b)` over current state | edges are not in the log (§1.1 C3) | edge revisions: a second revision stream for `edgeDelta` |
| label membership at commit C | labels are not in the log | record label attach/detach as a node revision kind |
| a follower's index/seek results | indexes are derived from live records and rebuilt, never in the WAL (pin W5) | a defined rule for which index state, if any, a follower is entitled to |
| two agents writing concurrently | one writer, by `flock` (C2) | per-branch node-id spaces and a diff-based merge (§7) — a separate document |

The single most important line: **the follower's empty graph (§3.2) is what
makes every "good" row above trustworthy.** A follower cannot half-answer a
Cypher query from node properties; it can only answer questions about history,
and it answers them completely.

## 6. Cost to the single-process case

Near zero, and deliberately so:

- The writer takes the `-lock` `flock` **once per database** at open (S1). A
  single-process database pays one `flock` syscall at open and nothing else.
- The writer publishes 16 bytes per commit (two `moRelease` stores). No
  allocation, no syscall, no fsync of its own — the frames are already durable
  when it publishes, so this is a memory write to an already-mapped page.
- A memory database and a read-only open take no lock and map no shm.

The one cost a single-process user *could* see is a `-lock` and a `-shm`
sidecar beside their file. Two empty files, and `.vhist` was already a third.

## 7. Branches are audit trails (and what concurrent branches would cost)

The commit log already carries `branch: string` on every `CommitRecord`, and
a merge commit can have two parents (the multi-parent walk was fixed and
tested in V0). That is almost all of git's machinery, and it is tempting to
read that as "concurrent writers are nearly here". They are not, and the gap
is specific:

- **One node-id allocator.** `store.nodeIds` is a single shared counter. Two
  branches writing concurrently both allocate from it; a git-style design
  forces **per-branch id spaces**, which means a node created on `agent-bob`
  does not exist on `main` until merge — a real semantic change to identity.
- **One open commit at a time.** `Revisions` refuses a second open commit
  (`revision.nim`), by design (it is what makes abort sound). Concurrent
  branches need more than one.
- **Edges are not in the log**, so a diff-based merge cannot even *see* an
  edge conflict — which is where a graph's conflicts actually live.

So: branches are **names for lines of history**, for forensics ("what was on
`main` when the agent branched to `experiment`?"), and nothing more in this
document. True concurrent branches — per-branch id spaces, multi-open
commits, edge revisions, `diff`-as-three-way-merge — is a coherent and
attractive future, but it is its own PRD and it is not a phase of this one.

## 8. Phases

| phase | content | gates |
|---|---|---|
| **F0** (done) | cross-process writer lock (S1): `flock`, the second-handle fix (C2) | SG1a/SG1b, shipped in `309dc8d` |
| **F1** | the watermark sidecar: mmap, publish in `commit`, release/acquire | SG5 — **green**, §4.2 |
| **F2** | a follower: read-only open, replay `.vhist` up to the watermark into a private `Revisions` | a follower's `stateAt`/`diff` equal a from-scratch replay of the same frames |
| **F3** | the follower's surface: `follow_at(commit, node)`, `follow_diff(a, b)` — read APIs over the history, no Cypher surface | every answer equals a from-scratch reconstruction |

F1 is the whole mechanism and is the smallest part of the whole feature. F2
and F3 are small because they reuse V0 wholesale. There is no phase here that
is "surface over an unproven thing": the thing was proven in V0/V1 and
re-proved by the oracle on every run.

## 9. Risks

| # | Risk | How it is met |
|---|---|---|
| **R1** | The watermark publishes a generation a follower cannot safely trust | SG5 is green over 3×10⁶ publishes (`tests/lock/barrierprobe.nim`). A watermark that lies is worse than none, because the follower stops checking, so the gate stays and the probe is kept |
| R2 | A follower reads a commit the graph rejected (the history-ahead crash) | F2 replays strictly up to the watermark, never to EOF. The watermark *is* the answer to this |
| R3 | A follower is mistaken for a second writer and corrupts something | F2 opens read-only and takes no write lock; C2's lock makes the wrong thing loud |
| R4 | Someone asks the follower a Cypher question and gets a partial-graph answer | §3.2: the follower's graph is empty and answers history questions only. The refusal is structural, not a policy |
| R5 | Edge history is demanded and the log cannot supply it | §5 names it as the prerequisite for graph sharing and §7 keeps it out of this document's phases. It is a real cost, stated, not deferred quietly |
| R6 | The feature grows back into "multi-process embedded access" | §2 pins the non-goals; §5 is the boundary; the positioning block is the sentence every future change is measured against |

R1 is the one that matters and it is the one that is open. Everything else is
a cost.

## 10. Pins

| # | Pin |
|---|---|
| **F1** | One writer process, enforced by `flock`, for the life of the `Database`. A follower never writes |
| **F2** | A follower reconstructs **history**, not the graph. Its Cypher surface is empty by construction, so it cannot half-answer a query |
| **F3** | The watermark is two `uint64`s and nothing else. No header, no checksum — the file is rebuilt from the WAL, so a zero file is a valid "nothing committed" state |
| **F4** | The watermark is published with release ordering, after the frames are durable, and observed with acquire. Arm64 is the platform this exists for |
| **F5** | A follower replays up to the watermark, never to end-of-file. End-of-file is not a bound (§1.1 C1) |
| **F6** | Branches are audit trails. Per-branch node-id spaces and diff-based merge are out of scope; they are a separate document, not a deferred phase |
| **F7** | The log is node history. Edges, labels and index state are not in it, and no follower feature pretends otherwise until they are |

## 11. Gates

- **SG5** — a follower never observes a generation paired with a stale LSN.
  **Green** over 3×10⁶ publishes; §4.2 records the two failures it took to
  get there, both of which were the test's.
- **SG6** — a follower's `stateAt` and `diff` equal a from-scratch replay of
  the same `.vhist` frames, on a randomized write workload.
- **SG7** — a follower replaying to the watermark after a crash mid-commit
  (history ahead of graph) reconstructs exactly the acknowledged commits, and
  is off by the unacknowledged one — the case C1 exists for.
- **SG8** — a follower opened read-only cannot write, and a follower never
  holds the write lock. (Cheap, and it is the C2 regression guard from the
  other side.)

SG5 is the gate that keeps this honest. F2 does not start until it is green.

## 12. Open questions

1. **What does a follower's `generation` mean relative to the writer's?**
   Today the shm's generation is the *graph's* generation, bumped once per
   commit. The follower counts *history* commits. If a commit writes only
   edges, it is a history commit that is not a graph-generation step, and the
   two counters need not agree. Whether the watermark should carry the
   graph generation, a history sequence, or both is not decided.
2. **Should a follower ever materialise a partial graph?** §3.2 says no. If
   edge history lands (R5), the question reopens — and the answer should be
   "yes, for the subset of the graph the log fully covers, and refuse the
   rest", which is a different and harder contract than either.
3. **The SG5 fix's shape** (§4.2) — a real `__atomic_*` intrinsic on a
   `volatile` word, versus a shared-word struct. The second is more portable
   and the first is more obviously correct; neither has been prototyped.

## 13. What changed from the first draft, and why

The first draft of this document proposed *"two or more processes on one graph
file, one writing, every other seeing committed state"* and phased it as
watermark → array catch-up → migrating writers → derived state. Every one of
those phases after the watermark assumed a follower wants the live graph.

Checking the log against what the engine actually records (C3) showed it does
not contain edges, labels or indexes, so "catch-up into the writer's arrays"
would produce a follower that answers graph queries from node properties and
is **wrong without knowing it**. The draft's §3.2 made the follower's arrays
the goal; this one makes them empty. That single inversion collapses four
phases into three small ones and converts the honesty problem (a partial
mirror) into a structural one (a timeline that cannot be mistaken for a
mirror).

The lock half (S1, shipped) survives unchanged; the second-handle bug it
fixed is recorded here as done, not as work.
