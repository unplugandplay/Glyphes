# glyphes — FOLLOWER SURFACE: the coding plan

> *The follower is correct and has no door. This plan builds the door —
> carefully, because a door into a read-only observer is a door a writer must
> never find.*

**Implements:** the external surface over [`PRD-SHARED.md`](PRD-SHARED.md)
F1–F3, which built the follower and proved it correct.
**Status:** plan. Nothing here is written. The corrections that this plan
rests on (the review of F1–F3) are committed separately.

---

## 0. Why this plan exists

The follower works. It maps the watermark, replays `.vhist` to it, and answers
`followState` / `followDiff` / `commitsUpTo` — and it is **Nim-only**. Nothing
in the 45 exported C functions reaches it. As a *data-sharing space* it is a
mechanism with no door: correct, tested, and unreachable from C, Ruby, the
CLI, or any wire.

This plan is the door. It has one hard rule that governs every phase, learned
from the whole point of the feature:

**A follower is read-only, and the external surface must make writing
physically impossible — not just checked against.** The moment an external
caller can reach a write through the follower API, every guarantee the gates
proved (SG5: trust the watermark; SG6: the timeline means the same thing as
the writer's; SG7: never show a rolled-back commit) is conditional on a check
some future edit could remove. So the surface is shaped to have nothing to
remove.

The phases below are ordered so that the thing most likely to be done wrong —
the ABI boundary, where a struct-layout slip is memory corruption, not a type
error — is built and locked before anything sits on top of it.

---

## 1. The shape of the work

| phase | lands | risk it retires |
|---|---|---|
| **S1** | C ABI: `glyphes_follower_*` over the handle registry | a follower reachable from C, with no write path in the type |
| **S2** | Ruby: `Glyphes::Follower` over `ffi.rb` | the door a Ruby host actually walks through |
| **S3** | CLI: `glyphes follow <db>` for humans and scripts | observable without writing a program |
| **S4** | hardening: cap protocol, stress, ASan | the boundary under a hostile caller |

The naming: these are **S** phases (surface), not F phases (follower core).
F0–F3 built the follower; S1–S4 expose it. Keeping the letters distinct is how
a reader knows whether a change touches correctness (F) or only reachability
(S).

Rough sizes: S1 ~250 lines of Nim + ~40 lines of C header, S2 ~150 lines of
Ruby, S3 ~80 lines, S4 is tests. Estimates, not commitments.

---

## 2. S1 — the C ABI

The engine's boundary conventions already exist and are non-negotiable; the
follower surface follows all of them rather than inventing parallel ones.

**Handle model.** A follower is a new `HandleKind` (`hkFollower` in
`handles.nim`), registered and released through the existing registry. A
follower handle names exactly one `Follower` object; passing it to
`glyphes_close` — which expects `hkDatabase` — is a `GLY_ERR_STALE`-class type
error, the same way passing a statement handle to `glyphes_close` is today.
This is the first and cheapest write-defense: the registry is typed, and a
follower is not a database.

**Functions.** The minimal set, all under `glyphes_follower_`:

| function | does | why it exists |
|---|---|---|
| `glyphes_follower_open(path, outHandle)` | `openFollower`, registered | attach |
| `glyphes_follower_close(h)` | unmap, release | detach |
| `glyphes_follower_refresh(h)` | `refresh`, returns "advanced" bool | poll |
| `glyphes_follower_head(h, out)` | newest commit **id** | the timeline question |
| `glyphes_follower_generation(h, out)` | watermark generation | the writer-progress question |
| `glyphes_follower_lsn(h, out)` | committed LSN | the WAL-position question |
| `glyphes_follower_error(h)` | per-handle last error string | the registry's `Slot.err` |

Deliberately **absent**: any function that takes a follower handle and a write
intention. There is no `glyphes_follower_commit`, no
`glyphes_follower_apply`, no `glyphes_follower_truncate`. The surface cannot
write because it has no write to call. This is the "nothing to remove"
principle made concrete.

**The three timeline reads** (`followState`, `followDiff`, `commitsUpTo`) are
*not* in S1's function list on purpose. They return structured data
(`NodeState`, `DiffEntry`, `CommitRecord`) whose layouts must cross the
boundary, and getting a struct layout wrong is the single most expensive kind
of ABI bug — it compiles, then corrupts. S1 lands the scalar handle lifecycle
first, proves the boundary holds with the existing `check_layout!` assertion,
and defers the structured reads to a follow-up once the shape is settled. A
follower you can open, poll, and ask "how far have you seen" is already useful
for health-checking a writer; the timeline reads are the next increment, not
the first.

**Error model.** Every function is wrapped in the existing `guarded` macro,
which catches Nim exceptions and routes them to the global error slot. A
follower that could not map its watermark reports `unavailable` through
`glyphes_follower_error`, not by failing the open — attaching to a database
before its writer has published is a race, not an error, and the C caller gets
the same "says so rather than invents one" contract the Nim caller gets.

**Gates for S1:**

- **SS1** — a C caller (a small Nim or C harness in `tests/abi/`) opens a
  follower against a live writer, polls, and reads head/generation/lsn that
  match the Nim follower on the same database. This is SG7's shape pointed at
  the boundary: the ABI follower must agree with the in-process follower.
- **SS2** — the write-defense is structural: there is no exported symbol a
  caller can invoke to mutate the followed database through a follower handle.
  Checked by listing exported symbols and asserting none matches
  `glyphes_follower_*write*|*commit*|*apply*|*truncate*`. Not a behavioural
  test — a shape test, because the guarantee is "there is nothing to call."

---

## 3. S2 — the Ruby surface

`lib/glyphes/ffi.rb` is the only file that knows FFI exists; a new
`lib/glyphes/follower.rb` is the only file that knows a follower exists.
Everything else in the gem keeps calling `Database` and `Statement`.

```ruby
follower = Glyphes::Follower.open("graph.glyph")
follower.refresh                 # => true if new commits
follower.head                    # => newest commit id
follower.generation              # => watermark generation
follower.lsn                     # => committed LSN
follower.unavailable             # => "" or why the watermark is missing
follower.close
```

No `Follower#commit`, no `Follower#[]=`, no `Follower#delete`. The Ruby class
exposes the same read-only surface the C ABI does, for the same reason: the
guarantee is in what the class does not have. `method_defined?` checks in the
test assert the absence, so removing the guarantee requires adding a method
*and* editing a test that asserts it is not there.

The Ruby `Follower` is a thin wrapper over the handle: every call goes through
`ffi.rb`'s `attach_function` and the existing `Guard.check!` error mapping, so
an ABI change lands in `ffi.rb` first, exactly as the header comment says.

**Gate SS3:** a Ruby integration test (in `tests/e2e/`, alongside the existing
216) forks a writer, follows it from Ruby, and asserts `head` advances. This
is the first gate that proves the door is real: a Ruby process observing a
Nim writer's commits, with no Nim in the test except the writer child.

---

## 4. S3 — the CLI

`glyphes follow <db> [--watch]` prints the follower's view for a human or a
shell script:

```
$ glyphes follow graph.glyph
head: 128    generation: 129    lsn: 1290    (2 commits behind writer)
```

`--watch` polls on an interval and re-prints on change. The CLI is the lowest
surface and the easiest to get wrong in one specific way: it must not become
an accidental write path. It reads head/generation/lsn and prints; it does not
open the database writable, does not take the lock, and exits nonzero with the
follower's `unavailable` reason when the watermark is absent.

**Gate SS4:** the CLI, run against a database while a writer commits in the
background, prints a monotonically advancing head, and a second `glyphes
follow` against a database with no writer exits with the unavailable reason on
stderr and a nonzero status.

---

## 5. S4 — hardening the boundary

The boundary is where a correct follower meets a hostile or careless caller.
S4 is not new capability; it is the existing capability under stress.

- **Cap protocol for the deferred timeline reads.** When `followState` /
  `followDiff` / `commitsUpTo` cross the boundary (the follow-up to S1), they
  use the two-call cap protocol `json_call` already uses: ask with a zero cap,
  the engine reports the length, ask again with what it said. No
  engine-allocated memory crosses the boundary (B1), so the caller owns every
  buffer.
- **Stress.** The SG7 crash gate, run through the C ABI: a follower observing
  a writer that is SIGKILLed mid-commit, checking the ABI follower is off by
  exactly the unacknowledged commit. The boundary must not weaken the crash
  guarantee.
- **ASan.** The existing `libglyphes_asan.so` build, run against the follower
  ABI tests, because a boundary that leaks or overruns under FFI is a boundary
  that corrupts slowly.

**Gate SS5:** the follower ABI under ASan shows no leaks and no overruns across
open/poll/close cycles against a writer that is crashing and recovering.

---

## 6. What is deliberately not in this plan

Named now, so no one plans them into a phase they do not belong in:

- **Edge, label, and index history.** The follower audits nodes only. Adding
  edges to the log is a *format* change (a new frame kind in `vhist.nim`), not
  a surface change, and it belongs to a different plan entirely. It is the
  single biggest gap in the follower as a *graph* audit, and it is out of
  scope here.
- **Branches and merges.** The writer produces a straight line; the revision
  store supports a DAG but nothing builds one. Real branches would be an F-phase
  (correctness), not an S-phase (surface), and are out of scope.
- **Push notification.** The follower polls on `refresh`. A change-feed or
  futex-based wake-up is an optimization that adds a second cross-process
  mechanism for no correctness gain; polling is O(new commits) and cheap. If a
  use case needs sub-poll latency, that is its own plan.
- **A follower that writes.** Never. The whole feature exists so that one
  process writes and others witness. Any proposal to let a follower mutate the
  followed database is a proposal for a different feature with a different
  name.

---

## 7. Gates

| gate | asserts | runs as |
|---|---|---|
| SS1 | C follower == Nim follower on head/generation/lsn | `nimble test` |
| SS2 | no exported follower symbol can write | `nimble test` (symbol shape) |
| SS3 | Ruby follows a forked writer, head advances | `tests/e2e/` |
| SS4 | CLI prints advancing head; no-writer DB exits nonzero | CLI test |
| SS5 | follower ABI clean under ASan across crash/recovery | `nimble asanFollower` |

The ordering rule from the follower plan still governs: **the uncertain thing
first, prototyped before designed around.** Here the uncertain thing is the
ABI boundary, so S1 lands the handle lifecycle and its layout assertion before
any structured data or any host language sits on top. Reuse before new: the
handle registry, the `guarded` macro, the cap protocol, and `Guard.check!` all
exist; this plan uses them and adds none of its own.

A note on what "done" means for this plan, because the follower plan set the
standard: a gate that has never failed is not yet evidence. Before S1 is
called done, SS1 is run against a deliberately wrong follower (one that reads
to EOF, the same mutation that proved SG7 had teeth) to confirm the boundary
carries the safety property across, not just the happy path.
