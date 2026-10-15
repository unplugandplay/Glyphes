# glyphes — PRD: versions, branches and diff

> *The same nodes. A history you can name, branch, and compare in
> microseconds.*

**Status:** PRD, pre-implementation. Every *pin* is normative; every *gate*
is a merge condition. Where code and this document disagree, this document
leads. This PRD refines and supersedes the single line
`ENHANCEMENTS.md` §*Not doing* — "Write-ahead time-travel / MVCC | Phase 2.
Needs a second process writing the same file" — which mis-describes the
problem twice over: it does not need a second process, and what is wanted
is not time-travel, which the engine already has for isolation.

It also found something on the way that is not versioning's to fix and is
recorded in §12: **a second `Database` handle on one file opens
successfully**, so the "exactly one writer" invariant is not enforced
across handles. That is a correctness item in its own right.

---

## 1. What this is

**Durable, user-addressable version history for a subset of a graph, with
named branches and cheap comparison.**

Today a commit in glyphes is real but anonymous. `store.generation` is a
monotonic counter used for isolation (`TXN.md` §2); a read snapshot is a
generation captured at `prepare` and forgotten when the statement closes. A
caller cannot ask *what the graph was*, because the answer is gone: the
published arrays hold the current state, tombstones are compacted at
checkpoint (`STORAGE.md` §4.7), and the log is truncated to zero at
checkpoint (`WAL.md` §6).

This PRD adds three things that are currently impossible:

1. **Addressing the past.** Read a node as it was at any commit.
2. **Branching.** A commit goes onto a named line of history. Two lines
   can exist at once. They are not a merge conflict problem, because this
   is an embedded, single-writer store with all-or-nothing writes — they
   are two independent histories over one node-id space.
3. **Diff.** Given two commits, list exactly which nodes changed between
   them, in time proportional to the number of nodes that changed and not
   to the size of the graph.

The "ultra fast" in the ask is not an adjective, it is the design
constraint. Everything below is arranged so that the common operations —
*what changed between these two commits*, *what did this node look like at
that commit* — do not scan the graph.

## 2. What this is not

It is **not** the MVCC the engine already has. That is an isolation
mechanism with a lifetime of one statement, sharing no storage with this
proposal and deliberately kept separate: reusing `generation` as a
user-visible commit id would make isolation depend on history being
retained, which is the opposite of what isolation needs.

It is also not git, and the differences are the point rather than
omissions:

| | git | glyphes versioning |
|---|---|---|
| merge conflict | resolved (or not) by the user | **refused by name** — all-or-nothing, per the engine's existing contract |
| content | bytes in a blob | nodes and their properties, addressed by stable id |
| branches | cheap, many, long-lived | cheap, many, long-lived — but see §7 |
| the common graph query | none | *historical indexed scans* — **not offered**, see §5.3 |

---

## 3. The model

### 3.1 Node identity is stable; node *state* is not

A node's `id` is its identity and never changes. What changes is its state:
its property values and its liveness. A **revision** is one state of one
node:

```
Revision
  nodeId    int64
  seq       uint64        # monotonic, per node
  commit    CommitId
  props     PropertyDelta # only what changed, see §4.2
  live      bool          # a delete is a revision, not an erasure
```

A node's history is a chain, newest first. Reading it at commit `C` is
walking back from the node's head until a revision at or before `C` is
found. That is the whole read-side algorithm and it costs the chain length,
not the graph size.

**A deleted node stays.** `live = false` is a revision like any other, so
`undelete` is a new revision and history survives deletion. A versioned
graph never shrinks below what its branches pin.

### 3.2 A commit is a batch, and it names its branch

```
Commit
  id          CommitId      # monotonic u64, engine-assigned
  parents     []CommitId    # 1 normally, 2 for a merge, 0 for the root
  branch      string
  changed     []int64       # node ids this commit created a revision for
  lsn         uint64        # the WAL position it sits at, §4.3
```

`changed` is the single most important field in this document. It is what
makes §5.1 cheap, and it is why the commit record stays small: it is one
int64 per touched node, not one property value.

A commit is created by the commit path of an ordinary transaction
(`TXN.md` §3.1). Nothing new is atomic — the existing publish point *is*
the commit point. Versioning adds what is being committed *to*, not a new
transaction model.

### 3.3 A branch is a ref, not a copy

```
Branch -> CommitId
```

`main` is created with the first versioned commit. Switching the current
branch is a pointer write. Two branches share node ids and the revision
chain: a node may be at revision 7 on `main` and revision 4 on `feature`,
because the chain is per branch, not global (§4.1).

## 4. Storage

### 4.1 A sidecar file, and why not the WAL

History lives in `<db>.vhist`, append-only, written alongside the
snapshot. The WAL is not extended, and that is a pin.

The reason is `WAL.md` §6: a checkpoint truncates the log to zero. That is
correct for a log whose job is crash recovery of the *current* state, and
it is load-bearing for pin P8. Making the log also carry history would mean
a history-preserving database can never truncate, which would turn the
cheapest possible backup (copy the file) into a streaming problem. The
sidecar keeps one rule intact: **the store's durability story is unchanged,
and a database can be backed up by copying two files.**

### 4.2 Revisions store deltas, not rows

A revision holds only the properties that changed, plus a liveness bit. A
node with ten properties whose `status` changes stores one property. This
matters because the alternative — a full copy per revision — makes the
history grow at `O(revisions × node size)` and turns §5.1's cost from
"changed nodes" into "changed nodes × properties".

### 4.3 The compaction conflict — decided before it can bite

`STORAGE.md` §4.7 compaction renumbers live records densely and reclaims
ids (`src/store/ids.nim`, `reclaim`/`renumberTo`). **Renumbering rewrites
history.** A revision recorded against id 41 would suddenly describe
whichever node became 41.

Checked against the code before writing this section, because the answer
changes what kind of problem it is: the renumbering machinery is
**implemented but never called**. Nothing in `src/` invokes `reclaim`. So
compaction is specified and available, not running — and there is no live
bug here today.

That is precisely why this decision belongs in a PRD rather than in a
commit. It is cheap to make now, when nothing depends on it, and expensive
to make later, when a compaction has already renumbered under a history
file. Two options:

- **(A) Pin versioned node ids.** A node on any branch never participates
  in renumbering. Compaction still runs for unversioned nodes.
- **(B) Rewrite history on compaction.** Correct, and O(history) per
  compaction, which on a five-day soak is a compaction that never ends.

**(A) is specified.** The cost is real and must be stated: a graph with any
versioning has a dense id space that stops being dense, and compaction
becomes partial. A graph that versions everything gets no compaction of the
node array at all. That is the price of keeping history, and it is the
reason this is not a default-on feature.

Wiring compaction is *not* this PRD's job, but it is this PRD's
precondition: V3's gate exists to prove the two features coexist, because
the day compaction is switched on is the day this section stops being
theoretical.

### 4.4 Garbage collection

A commit is retained while any branch ref can reach it. `prune` drops
unreachable commits and the revisions only they owned, refcounted per node.
Dropping a branch is what makes its history collectable. The default is
that nothing is ever pruned automatically — history that disappears on a
timer is history nobody trusts.

## 5. The operations, and what each costs

### 5.1 Diff — the operation the ask is really about

`diff(A, B)`:

1. Find the merge base of `A` and `B` (commit-graph walk, depth = branch
   divergence, not graph size).
2. Collect `changed(A..base) ∪ changed(base..B)` — the two commit delta
   sets, walked along the two paths.
3. Union of ids; for each id, compare the two revisions' state.

Cost is **O(commits between them + nodes that differ)**. No label scan, no
traversal, no index. On a 10⁶-node graph with a commit touching 400 nodes,
this is a few hundred microseconds and it does not depend on the 10⁶.

That is the "ultra fast git diff", and it is a direct consequence of §3.2:
we recorded *what changed*, so we never have to look at *everything*.

### 5.2 Read as-of

`node_at(nodeId, commit)` walks the node's revision chain (§3.1). Cost is
the chain length. Reading a whole *set* of nodes as-of is a scan (§5.3).

### 5.3 Historical scans — deliberately not offered

> **A commit-indexed scan is out of scope for 0.2.**

"Which `Person` nodes had `age > 30` at commit C" is not supported by an
index, because the index indexes the **head**, not every revision. Answering
it means scanning the historical node set and evaluating the predicate per
node — O(graph), the same as a query with no index at all.

This is the line that decides whether this feature is a week or a project.
Serving it properly means per-commit or MVCC-structured indexes: either one
index per commit (unbounded growth), or an index whose entries carry every
revision (every range scan pays for the whole history, forever, on every
query including current-state ones). Both are worse than the thing they
enable, and both would be felt on the *hot path* — the normal query — to
serve a rare one.

So: **as-of reads and diff are O(changed); as-of scans are O(graph), and
that is a named limit rather than a quiet cliff.** A caller who needs
historical range scans exports the historical set and filters elsewhere,
which is the same answer §1 of `PRD-GLYPHES.md` gives for analytics.

### 5.4 What is *not* cheap

Honesty about the other direction, because a versioned graph is not free:

- The history file grows monotonically until pruned. Size is a function of
  *revisions*, not of graph size.
- Every commit touching a versioned node pays a revision append. This is on
  the write path, and pin P8 (atomic, fsynced commit) means the append is
  fsynced too.
- Versioned nodes are excluded from compaction (§4.3).

## 6. The surface

```
db.versioned_start(branch = "main")   # opt in, per node, or per database
db.commit_to(branch)                  # the current transaction's commit lands here
db.branch("feature")                  # switch the write ref
db.branches                           # refs, with their heads
db.diff(a, b)                         # node ids, with before/after
db.node_at(id, commit)
db.prune                               # drop unreachable commits
```

Cypher, for the read side:

```
MATCH (n:Person {id: $id}) AT $commit RETURN n
```

`AT` is a new clause and it is refused without a versioned node in the
pattern — not silently ignored.

**Ruby only, for the write side**, in the first cut: the branch is a
property of *how the transaction is committed*, which has no expression to
live in. Asking for it in Cypher would mean inventing syntax for something
Cypher has no concept of.

## 7. Non-goals

- **Merge conflict resolution.** A write that collides across branches is
  **refused by name** (`GLY_ERR_BRANCH_CONFLICT`), the same contract as
  every other refusal in the engine. Git's three-way merge is a project
  with its own opinions; guessing at one is how a store loses data quietly.
- **Rebase, cherry-pick, tags.** They are conveniences over the same
  primitives and can come later.
- **Remote branches, push, pull.** One file, one process (pin P1).
- **Versioning the index.** Indexes track the head only.
- **History of edges.** §3.1's chain is per node. Edges are the hard part
  of a graph and their history is a separate document; pretending otherwise
  is how this idea gets underestimated.

## 8. Phases

| phase | content | gates |
|---|---|---|
| **V0** | the revision store and its sidecar; `changed` recorded per commit; `diff` over it. No query surface, no branches — one linear history. | diff is O(changed) on a 10⁶-node graph and is byte-identical to a full comparison; a crash mid-append leaves the sidecar at a commit boundary (V1) |
| **V1** | commit durability and the WAL link (`lsn`); branches; `commit_to`; prune. | a commit survived by a reopen is byte-identical; two branches interleave without a write crossing |
| **V2** | read surface: `node_at`, the Ruby surface, then Cypher `AT` | every answer equals a from-scratch reconstruction of the same commit |
| **V3** | compaction interaction (§4.3) proven under load | a soak with versioned nodes: ids pinned, no growth in the unversioned path |

V0 is the whole idea and it is where the risk is. V1–V3 are surface area
over a thing that either works or does not.

## 9. Risks

| # | Risk | How it is met |
|---|---|---|
| R1 | **Compaction rewrites history** (§4.3) | pin V2: versioned nodes never renumbered. Compaction is not wired today, so this is decided before it can bite; V3's gate proves coexistence when it is |
| R2 | The sidecar and the snapshot disagree after a crash | a sidecar carries the snapshot's `generation`; a mismatch refuses the open by name rather than serving history from a different base |
| R3 | History growth is unbounded and the write path pays | §4.4 and §5.4. No automatic pruning, ever |
| R4 | Historical scans tempt someone to build per-commit indexes | pin V2: the index indexes the head. The refusal is documented where a caller will meet it |
| R5 | `changed` and the actual write diverge — the one bug that would make diff lie | diff is differential-tested against a from-scratch reconstruction of both commits, on every gate. A diff that is confidently wrong is the worst outcome this feature has |
| R6 | Versioning becomes the default and compaction quietly stops working | §4.3's cost is opt-in and stated at the point of opting in |

R5 is the one that matters. Everything else is a cost.

## 10. Pins

| # | Pin |
|---|---|
| V1 | History is a sidecar. The WAL is never extended for it and is still truncated to zero at checkpoint (P8, `WAL.md` §6) |
| V2 | A versioned node id is never renumbered by compaction. Binding now, while compaction has no caller |
| V3 | `diff` is O(nodes changed). It never scans the graph, and a gate asserts it does not |
| V4 | Indexes index the head. Historical range, text and vector scans are refused by name, not approximated |
| V5 | A cross-branch write collision is refused by name. No automatic merge |
| V6 | Node identity is stable forever; a delete is a revision, and history survives it |
| V7 | Versioning is opt-in per node or per database, and opting in states §5.4's cost |
| V8 | Nothing is pruned automatically, ever |

## 11. Gates

Every one of these is a merge condition, not a milestone review.

- **G1** — diff equals a from-scratch two-commit comparison on 10⁶ nodes,
  byte for byte, over a randomized write workload.
- **G2** — diff time on that fixture scales with nodes-changed, not node
  count: two commits touching 400 nodes each must cost the same whether
  the graph holds 10⁴ nodes or 10⁶.
- **G3** — every `node_at` answer equals a reconstruction from the commit
  log alone.
- **G4** — a reopen after a crash mid-append exposes a commit boundary, not
  a partial one, and refuses rather than guessing.
- **G5** — a soak with versioning enabled: pinned ids are never reused, and
  the unversioned path's memory is unchanged from the M11 baseline.
- **G6** — a merge-base walk and a diff produce the same id set as a naive
  whole-graph comparison, on randomized DAGs with merges.

G2 is the gate that keeps this honest. It is the difference between a
feature that is fast and one that is fast *on the example*.

## 12. Open questions

- **Does `changed` need to be a bitset rather than a list?** At commit sizes
  in the thousands the list is smaller and simpler; a bitset over the node
  space wins only past a threshold that depends on commit shape. Undecided,
  and cheap to measure before choosing.
- **How long should a revision's property delta live before it is
  compacted into a full row?** Never, in V0. Revisit if a long-lived branch
  makes the chain walk the hot path.
- **Should a branch's write ref be process-global or per `Database`?**
  Per database, because one file is one history. Note the assumption this
  rests on is currently false: **a second `Database` handle on one file
  opens successfully**, and each handle claims the writer independently, so
  the "exactly one writer" invariant (`TXN.md` §3) is not actually
  enforced across handles. Versioning makes this much worse — two handles
  would be two write refs over one node-id space. Refusing the second
  handle is a prerequisite for V1, not a nice-to-have, and it is a
  correctness fix that stands on its own whether or not versioning ships.
- **Does `AT` need a `BEFORE`/`AFTER` form?** Asked for early, deferred
  until V2 has a surface to put it on.

---

## 13. Related documents

- [`PRD-GLYPHES.md`](PRD-GLYPHES.md) — the parent product; pins P1, P8, P11
- [`TXN.md`](TXN.md) — §2 generations, §3 the commit point this reuses
- [`STORAGE.md`](STORAGE.md) — §4.7 compaction, the conflict in §4.3
- [`WAL.md`](WAL.md) — §6 truncation, the reason for the sidecar
- [`INDEX.md`](INDEX.md) — I11 index freshness; V4's refusal lives here
- [`limitations.md`](../limitations.md) — amended when V0 lands
- [`../ENHANCEMENTS.md`](../ENHANCEMENTS.md) — the line this PRD supersedes