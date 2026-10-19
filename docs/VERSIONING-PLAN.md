# glyphes — VERSIONING: the coding plan

> *Build V0 first, prove diff is O(changed), then add surface.*

**Implements:** [`PRD-VERSIONING.md`](PRD-VERSIONING.md)
**Status:** plan, pre-implementation. No code below has been written.

This is the order of work, not the argument for it — the PRD carries the
design and the reasoning. Two rules govern the ordering:

- **The uncertain thing is built first.** §V1 (the on-disk format) is where
  a wrong guess costs a rewrite of everything above it, so V0 ends by
  freezing the format rather than by adding features.
- **No surface area until the claim holds.** Branches, `AT`, and the Ruby
  API are all downstream of "diff is O(changed)". Building them first would
  be building the easy half of a thing whose hard half is unproven.

---

## 0. The shape of the work

| step | lands | risk it retires |
|---|---|---|
| **V0** | revision store, `changed` recording, `diff` | is the claim true at all? |
| **V1** | on-disk format, crash boundary, durability | is the format right before anything depends on it |
| **V2** | branches, prune | multi-head correctness |
| **V3** | read surface (`node_at`, Ruby, `AT`) | is history *readable* |
| **V4** | compaction coexistence | does versioning and compaction coexist at all |

V0–V1 are the product. V2–V4 are surface and hygiene over them.

Roughly: V0 ~600 lines, V1 ~450, V2 ~500, V3 ~400, V4 ~250. These are
shape estimates for sequencing, not commitments.

---

## V0 — the core: revisions and diff

**Goal:** on a single linear history, `diff(a, b)` returns the changed node
ids, and does it in time proportional to what changed.

### V0.1 — the revision store (new: `src/store/revision.nim`)

The data structure, with no file behind it yet.

```nim
type
  Revision* = object
    nodeId*: int64
    seq*: uint64
    props*: seq[(int32, Value)]   # the delta, not the row (§4.2)
    live*: bool

  CommitRecord* = object
    id*: uint64
    parents*: seq[uint64]
    branch*: string
    changed*: seq[int64]           # the load-bearing field (§3.2)
    lsn*: uint64
```

`Revisions` holds `byNode: Table[int64, seq[Revision]]` (newest first) and
`commits: seq[CommitRecord]`. One file, no I/O — V0.1 is pure so it can be
tested against an oracle without a disk.

### V0.2 — recording a revision (hook: `src/txn/txn.nim`)

Where the delta already is. `setPropCommon` (§4.2's delta), `deleteNode`,
and `createNode` each note "this node changed in this transaction". At
`commit` (txn.nim:688, beside `applyDelta` at :849) those become a
`CommitRecord` with `changed` filled.

**The one design decision here:** record the *property delta the
transaction actually produced*, not a re-read of the node. Re-reading
would make a revision's contents depend on when it was written, and V0.4's
differential test exists to catch exactly that.

### V0.3 — `diff` (new: `src/store/revision.nim`)

```
diff(a, b):
  base = merge_base(a, b)            # V2 generalises this; V0 assumes a line
  ids  = changed(base..a) ∪ changed(base..b)
  for id in ids: yield (id, state_at(id, a), state_at(id, b))
```

Each is a chain walk. `merge_base` is trivial on a line (min) and stays
behind one function so V2 changes it in one place.

### V0.4 — the differential test (new: `tests/unit/test_version.nim`)

The PRD's G1, and the single most important test in the feature: for
randomized write workloads, `diff` must equal a from-scratch reconstruction
of both commits. The oracle is deliberately naive and slow.

**V0 is done when:** `nimble test` green, `diff` passes G1, and the
benchmark below shows G2.

### V0.5 — the benchmark (new: `tests/bench/bench_version.nim`, task `benchVersion`)

G2, and the measurement that decides whether the PRD's central claim is
true. Two commits touching 400 nodes each, on graphs of 10⁴ and 10⁶ nodes;
the times must be indistinguishable. If they are not, the design is wrong
and V1 does not start.

---

## V1 — durability: the format and the crash boundary

**Goal:** history survives a reopen, and a crash mid-append leaves a commit
boundary rather than a partial commit.

### V1.1 — the on-disk file (`<db>.vhist`, beside the `.indexes` sidecar)

The naming precedent is `src/index/index.nim`'s `IndexSidecarSuffix`
(`".indexes"`), written and read beside the snapshot in exactly this
shape.

Append-only, framed exactly like the WAL — same idea, different file
(PRD §4.1). The frame is
`[payloadLen u32][commitId u64][generation u64][kind u32][payload][crc32 u32]`,
and `kind` is `commit`. One frame per commit: a frame either validates as a
whole or it does not, so there is no partial commit for a reader to
reconstruct.

The payload opens `[magic][version][branchLen u32][branch]`, then the
changed ids, the parents, the LSN and one row per revision. The version
byte is a field of its own rather than a digit of the magic so a payload
written by an older binary still replays: V0 carries no branch and reads
back as the empty branch, which is exactly what the replay sites used to
pass by hand. A version from the future is refused by name — reading on
would turn a future file into wrong history rather than an error.

Reusing the WAL's framing rather than inventing one means the CRC argument,
the length-in-header argument, and the recovery argument are all already
argued in `WAL.md`.

**Still open in the frame:** no database-identity word, so a sidecar
copied from another database is adopted silently. It is listed first in
[`ENHANCEMENTS.md`](../ENHANCEMENTS.md) rather than done here, because the
identity it should carry belongs in the *snapshot* header, and that is a
storage-format change with its own evidence to gather.

### V1.2 — load and recovery (hook: `src/database.nim`)

On open, replay `.vhist` to the last complete frame. A partial trailing
frame is **truncated and the open continues** — the commit it belonged to
was never acknowledged, so discarding it is correct. Anything that is not a
clean boundary is a refusal, not a guess (PRD G4).

One commit advances the generation by one and appends exactly one frame, so
a sidecar's generations strictly increase. A frame that repeats or reverses
one is CRC-valid and still impossible: it was *written* in an order this
format does not produce — a duplicate, a concatenated sidecar, a splice —
and replaying it would put the same commit in the timeline twice. It is
refused like a bad CRC, and a resuming reader passes the generation it has
already applied so the check spans the seam a duplicate lands on.

The sidecar carries the snapshot's `generation`; a mismatch refuses by name
(PRD R2).

### V1.3 — fsync discipline

P8 is the parent PRD's hardest pin and this feature must not weaken it. The
question "does a revision append belong inside the commit's fsync, or
after it?" is answered in the PRD's favour: **inside**, or history can
disagree with the graph it describes, which is the one incoherence this
feature cannot have.

---

## V2 — branches and prune

**Goal:** two heads, one node-id space, no crossing writes.

### V2.1 — `Branch -> CommitId` and `commit_to`
### V2.2 — generalise `merge_base` to the commit DAG (V0.3's single site)
### V2.3 — the conflict refusal (`GLY_ERR_BRANCH_CONFLICT`, PRD V5)

All-or-nothing, per the engine's existing contract. A cross-branch write to
a node whose head differs between the branches is refused **by name** — the
same refusal discipline as `GLY_ERR_UNSUPPORTED` everywhere else.
### V2.4 — `prune` (refcounted per node, PRD §4.4)
### V2.5 — **prerequisite, and independent of this feature:** refuse a
second `Database` handle on one file. It opens today (PRD §12) and each
handle claims the writer independently, so "exactly one writer" is not
enforced across handles. Versioning turns that from a latent hole into two
write refs over one node-id space. It should be fixed on its own merits
first, and landed before V2.1.

---

## V3 — the read surface

**Goal:** history you can read, in the order callers ask for it.

### V3.1 — `node_at(id, commit)` (chain walk, §5.2)
### V3.2 — Ruby: `diff`, `node_at`, `branches`, `commit_to`, `prune`
### V3.3 — Cypher `AT` — last, because it is the only piece needing new
grammar, and `AT` must **refuse** on an unversioned pattern rather than
being silently ignored (P11).

Gate G3 for this step: every `node_at` answer equals a reconstruction from
the commit log alone.

---

## V4 — compaction coexistence

**Goal:** the two features do not undo each other.

### V4.1 — pin versioned ids (PRD V2)
### V4.2 — prove it under load: a soak with versioning enabled (gate G5)
### V4.3 — wire compaction **only if** V4.2 is green

Compaction's renumbering machinery exists (`src/store/ids.nim`) but has no
caller. Turning it on is a separate decision, out of this plan's scope;
V4's job is to ensure versioning does not quietly prevent it, and to say
so in `limitations.md`.

---

## The gates, and where they run

| gate | asserts | runs as |
|---|---|---|
| G1 | diff == from-scratch reconstruction, 10⁶ nodes | `nimble test`, every run |
| G2 | diff time independent of graph size | `nimble benchVersion` |
| G3 | `node_at` == reconstruction | `nimble test` |
| G4 | crash mid-append → commit boundary | `nimble crashVersion` |
| G5 | pinned ids never reused; unversioned memory unchanged | `make soak` with versioning |
| G6 | diff == naive comparison on randomized DAGs | `nimble test` |

**G1 is the one that matters.** Everything else is a cost; G1 is the
feature's correctness, and it is cheap to run, so it runs every time.

---

## What is deliberately absent

- **Edge history** — a separate document (PRD §7). The diff is over nodes;
  an edge revision model is a different design, and pretending otherwise
  is how this gets underestimated.
- **Historical indexed scans** — refused by name (PRD V4, §5.3).
- **Merge resolution, rebase, tags** — PRD §7.
- **Any index for history** — index the head only.

---

## Risks, in the order they would bite

| when | risk | response |
|---|---|---|
| V0 | the `changed` set and the real write diverge, and diff lies | G1 on every run; the naive oracle exists for this reason alone |
| V0 | diff is O(graph), not O(changed) | V0.5 measures it before V1 builds on it |
| V1 | a format decision that everything above must be reworked against | V1 is deliberately early and deliberately boring |
| V2 | two handles, two writers, one file | V2.5, before V2.1 |
| V4 | compaction silently stops reclaiming | V4's gate is a soak, not a unit test |

---

## Related

- [`PRD-VERSIONING.md`](PRD-VERSIONING.md) — the design this implements
- [`../DEVLOG.md`](../DEVLOG.md) — append a V-entry per milestone, in the
  existing style
- [`TXN.md`](TXN.md), [`WAL.md`](WAL.md), [`STORAGE.md`](STORAGE.md) —
  the contracts this must not weaken