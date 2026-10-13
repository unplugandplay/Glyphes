# glyphes — WAL: crash-safe commit, snapshots, recovery

> **Status:** specification for M2. Normative. Companion to
> `STORAGE.md` (what is serialized) and `TXN.md` (who writes it).
> Framing format here is pinned; changing it is a format version bump.

This specifies the write-ahead log, the snapshot file, the recovery
procedure, and the checkpoint policy. This is the milestone that decides
whether glyphes is a database or a demo.

---

## 0. The thesis

An embedded graph store that loses data on `kill -9` fails at the only
thing it exists for. Durability is therefore in Phase A, not Phase B, and
the M2 gate (§8) is a `kill -9` test rather than a unit test.

The design is SQLite's, not Memgraph's. Memgraph's durability path
carries replication, multi-tenancy, and per-tenant durability control —
none of which applies. glyphes needs three things and only three things:

1. **Atomic commit.** Either every mutation in a transaction is visible
   after recovery, or none is.
2. **Durability at commit.** `commit` does not return until the bytes
   are on the device.
3. **Bounded recovery time.** Open is O(snapshot) + O(WAL tail), never
   O(history).

---

## 1. Files on disk

```
graph.glyph            the database: snapshot + WAL, one file (P1)
graph.glyph-wal        append-only mutation log
graph.glyph-lock       advisory lock, holds the writer pid
graph.glyph-journal    reserved: rollback journal, phase 2, never created in 0.1
```

Pinned: **one file plus its sidecars.** `graph.glyph` is the mmap'd
snapshot; `-wal` is the log. A backup is `cp` of the two, or better,
`glyphes_backup` which does a checkpoint-then-copy so the result is a
single consistent file.

The `-lock` file is what makes a second process fail cleanly with
`GLY_ERR_BUSY` instead of corrupting the WAL. It holds the writer pid and
a boot id; a stale lock from a crashed process is detected via `flock`
(OS-released on process death) rather than pid liveness, because pid
recycling makes pid checks unsafe.

---

## 2. WAL frame format

Append-only, `O_APPEND`, never rewritten in place.

```
FrameHeader (32 bytes)
  0   8   lsn         u64    log sequence number, monotonic from 1
  8   4   txn_id      u32    0 = autocommit, else the tx handle
  12  4   opcode      u32    MutationOp (§3)
  16  4   payload_len u32    bytes of opcode-specific payload
  20  4   crc32       u32    CRC32 of (header[0..20] ‖ payload)
  24  4   txn_flags   u32    bit 0 COMMIT, bit 1 ROLLBACK, bit 2 CHECKPOINT
  28  4   reserved    u32    zero

Payload                 payload_len bytes, opcode-specific (§3)
```

Frames are **not** padded or aligned. A WAL is a byte stream read
sequentially; alignment would only help a random-access reader, which
does not exist.

`crc32` covers the header's first 20 bytes (everything before itself)
concatenated with the payload, so corruption in either the framing or the
body is caught. It does **not** cover the frame's own `crc32` field,
which is why the header split is at offset 20.

### 2.1 Reading the log

Recovery reads frames sequentially from the last known-good offset. A
frame is **valid** if `crc32` matches and `payload_len` is within the
remaining file and within the opcode's maximum. The first invalid frame
ends the log; recovery truncates the file there.

This handles the torn tail: a process killed mid-`write()` leaves a
partial frame, whose CRC almost certainly fails. Truncating at the first
bad frame is correct because WAL frames are only meaningful in
transaction order and an unterminated transaction is discarded anyway.

The dangerous case is a partial frame whose CRC happens to pass. Made
vanishingly unlikely by committing only whole frames: the writer builds
each frame in a stack buffer and issues **one** `write()` per frame, so
a frame is either fully written or the file is short. Frames from
different transactions are never batched into one `write()`.

---

## 3. Opcodes

Mutations are typed opcodes, **not Cypher text**. Replay therefore needs
no parser, is unaffected by a language change, and cannot be broken by a
query that parsed differently than it did at write time.

Payloads are **logical, not physical**. An earlier draft carried
`PropSlot` records verbatim so replay could `memcpy` them into place; the
implementation does not do that, because the arena is rebuilt during
recovery and a slot offset recorded by the writing process would point
into the recovering process's bytes at whatever happens to be there.
`SetProp` therefore carries the *value*, and replay calls the same
`setProp` the transaction did — which also means a value that is inline
on the writer can legitimately come back arena-resident, or the reverse,
without being a discrepancy.

| # | Opcode | Payload as implemented |
|---:|---|---|
| 0 | `Noop` | empty — the commit / rollback marker frame, see below |
| 1 | `CreateNode` | `node_id i64, label_code i32` — properties ride in their own `SetProp` frames, not in the create |
| 2 | `DeleteNode` | `node_id i64` — a cascading delete emits one `DeleteEdge` per incident edge, then this frame |
| 3 | `AddLabel` | reserved, not yet emitted |
| 4 | `RemoveLabel` | reserved, not yet emitted |
| 5 | `CreateEdge` | `edge_id i64, type_code i32, src i64, dst i64` |
| 6 | `DeleteEdge` | `edge_id i64` |
| 7 | `SetProp` | `target i8` (0=node, 1=edge) `, id i64, key i32, vtype u8, aux u16, inline u8,` then either an `u64` inline word or the encoded value blob |
| 8 | `RemoveProp` | reserved, not yet emitted |
| 9 | `CreateIndex` | reserved — index state is not replayed (pinned below) |
| 10 | `DropIndex` | reserved |
| 11 | `NewLabel` | `label_code i32, name` — dictionary append, emitted the first time a name is seen |
| 12 | `NewRelType` | `type_code i32, name` |
| 13 | `NewPropKey` | `key_code i32, name` |

Dictionary frames carry the code *and* the name, and are emitted in
first-seen order. The dictionary is append-only, so replaying them in
write order reproduces the same codes — which is what lets every other
frame reference a code instead of a string.

**Markers.** A transaction ends in a marker frame, not in a flag on the
last mutation: `opNoop` with an empty payload and `TxnCommit` or
`TxnRollback` in `txn_flags`. Flagging a real opcode's frame instead was
the original sketch, and it was wrong — replay would execute the flagged
frame as a mutation. Every frame of a transaction carries the same
`txn_id`; replay accumulates frames per `txn_id` and merges only on
seeing the marker. `TxnCheckpoint` is defined and not yet emitted.

**Deliberately not an opcode:** index mutations from property writes.
Indexes are rebuilt from the store at recovery, not replayed from the
log. Replaying an HNSW insert is not reproducible across versions anyway,
and rebuilding at open is bounded by store size rather than log length.
Pinned: index state is not in the WAL.

---

## 4. Snapshot format

Written at checkpoint, replacing `graph.glyph`. Read by `mmap` on open.

```
Header (160 bytes)
  0   8   magic          "GLYPHSN1"
  8   4   format_version u32     1
  12  4   header_crc     u32     CRC32 of header[0..12]
  16  8   lsn            u64     highest lsn included in this snapshot
  24  8   node_count     u64
  32  8   edge_count     u64
  40  8   slot_count     u64
  48  8   arena_bytes    u64
  56  8   label_count    u64
  64  8   reltype_count  u64
  72  8   propkey_count  u64
  80  8   index_count    u64
  88  8   generation     u64     store generation after this snapshot
  96  8   next_node_id   u64     id allocator high-water mark (§4.2a)
  104 8   next_edge_id   u64     id allocator high-water mark
  112 8   live_node_count u64    slots allocated in the arrays, >= live
  120 8   live_edge_count u64    slots allocated in the arrays, >= live
  128 32  reserved              zeroed

Dictionary section   label_count strings, then reltype_count, then
                      propkey_count — NUL-terminated, in code order.
                      Codes are implicit by position (STORAGE.md §4),
                      and the reader checks the order rather than
                      trusting it: a snapshot whose strings do not
                      reproduce code order would silently reassign
                      every code in the file.

Node section          node_count × NodeRec (48 B), in id order (index
                      is id - 1; STORAGE.md §1 principle 2). node_count
                      includes tombstones and doubling padding.
Edge section          edge_count × EdgeRec (56 B), in id order
Slot section          slot_count × PropSlot (16 B): every live record's
                      slots, nodes first then edges, in the order the
                      records' offsets index into. The count is the sum
                      over *both* record kinds.
Arena section         arena_bytes, verbatim from offset 0 so the first
                      8 bytes — the hole that makes 0 mean "none" — come
                      along and every offset still resolves. Capped at
                      the bytes that exist: a store that never allocated
                      arena space writes an empty section, and the
                      loader rebuilds the same hole-and-offset shape
                      from it.
Label section         per label slot: member_count u64, then member ids
                      u64. No bitmap; see §4.2a.
LabelPos section      (node_count + 1) × i32. **Written but not read
                      back** — the reader rebuilds it from the label
                      section, which is authoritative, because trusting
                      a second copy of the same fact is how a stale
                      position removes the wrong member on delete. The
                      bytes are still stepped over, so the layout is
                      stable for external readers.
Allocator section     node free list (count u64, ids u64), then the edge
                      free list. Without the high-water marks in the
                      header plus these lists, a reopen renumbers from 1
                      on top of live ids (§4.2a).
Index section         reserved: index_count is 0 in format version 1,
                      and the section is absent.
Trailer               body_crc32 u32, magic "GLYPHSN1" (8 B)

The trailer CRC covers the entire body from `header[16]` onward. A
snapshot that fails it is refused at open — the loader raises, and the
FFI layer will map that to `GLY_ERR_IO` when M2 is wired to the ABI. A
corrupt snapshot is never half-applied: either the whole body
reconstructs or nothing does.

### 4.2a Store state the format must carry, discovered at M1

M1 built the store and three pieces of state turned out to be load-
bearing that this section originally did not mention. Each was found by
asking the obvious question — *if this were the only bytes on disk,
would a reopen be correct?* — and each fails loudly if omitted.

**Id allocator high-water marks.** `IdAllocator.next` is the next id to
issue. A snapshot that omits it reopens with `next = 1` and hands out an
id that a live node already holds. `STORAGE.md` S2 forbids reusing ids
within a generation precisely so a host-held `Node` keeps pointing at the
right thing; violating that at *reopen* is not a subtle bug, it is the
whole identifier scheme gone. Hence `next_node_id` / `next_edge_id` in
the header.

**Slot capacity, not just live count.** The arrays are grown by doubling,
so a reopened store has trailing zeroed slots. `live_node_count` records
how many slots were allocated, so the reader knows where the tombstones
and padding end without scanning. `EdgeRec.live` and `NodeRec.live`
already treat `id == 0` as "no record" (M1), which is what makes the
padding harmless.

**LabelPos.** M1 gave the label index O(1) removal by recording each
node's position inside its label's member list, in a store-level
`labelPos: seq[int32]` — deliberately *not* in `NodeRec`, so the pinned
48-byte layout and this file's node section are untouched
(`STORAGE.md` §4.3). It is therefore separate state that has to be
written. A snapshot without it reopens with a label index whose
positions are all -1, and the next delete removes an arbitrary member.

The free-id lists are the fourth. They are empty after a compaction —
which is the normal case for a snapshot — but a snapshot written by
`GLY_CHECKPOINT_FSYNC` without renumbering would carry them, so the
section exists rather than being a special case nobody implements.

### 4.1 mmap read path

The snapshot is mapped `PROT_READ`, `MAP_SHARED`. Records are accessed
through the mapping at computed offsets. Consequences:

- **Zero copy.** A property that is inline is read straight out of the
  mapped page; no deserialization step exists.
- **The page cache does the caching.** Nothing to evict, nothing to
  manage.
- **Rebasing is the one pass.** Overflow arena offsets in `PropSlot`
  payloads are relative to the arena base; the reader adds the mapped
  base when dereferencing. No rewrite of the file, no fixup table.

`msync` on the writer side before rename; `fsync` on the containing
directory after rename, so the swap is atomic and durable. A crash during
checkpoint leaves the old snapshot and a longer WAL, which recovers
correctly — checkpoint is idempotent by construction.

### 4.2 Compaction

Checkpoint also renumbers, because `STORAGE.md` §1 principle 2 allows id
reuse only after compaction:

- Tombstoned records are dropped, arrays are compacted, ids are
  reassigned densely.
- Label member lists are rebuilt, and `labelPos` is rewritten for every
  surviving node in the same pass. The two must be rebuilt together or
  the positions point at the wrong members.
- The index section is rebuilt from live records.
- Every id held by a live statement is remapped via an old→new table
  retained for the duration of the checkpoint.

Renumbering at checkpoint is a choice: it keeps arrays dense and reclaims
tombstone space, at the cost of invalidating any id a host application
stored. Ruby therefore hands out `Node` objects that resolve ids lazily
and re-check against `generation`, rather than caching id-derived data.

---

## 5. Recovery

```
recover(graph_path, into):
  0. refuse if `into` already holds records — replay is exactly-once per
     store, and a silent double-apply looks like success
  1. if snapshot exists:
       verify header CRC and trailer CRC over the mapped bytes
       on failure: raise. (The sketch below had recovery fall back to an
       empty base plus a full-log replay; the implementation refuses.
       See §10 — it is a real decision, not an oversight.)
       load arrays, distribute the slot block into the arena, rebuild
       the label index and labelPos from the label section
  2. else: empty store, replay from lsn 0
  3. replay WAL from snapshot.lsn (frames at or below it are already in
     the snapshot; fromLsn == 0 means there is no snapshot and the whole
     log replays):
       for each frame:
         if !valid(frame): torn tail; stop
         accumulate frames by txn_id
         on COMMIT marker:  apply the accumulated frames, bump generation
         on ROLLBACK marker: drop the accumulated frames
       a txn_id still accumulated at the truncation point is discarded
  4. truncate WAL to last_good   (fmReadWriteExisting — see §4's warning
     about the truncating open modes)
  5. rebuild indexes from live records (§3)  — not yet implemented
  6. generation = snapshot generation + committed replays
```

Three properties make this safe:

**Idempotence by `lsn`, guarded by the entry check.** Replay skips
frames at or below `snapshot.lsn`, and `fromLsn == 0` means "no snapshot,
replay everything" — an unguarded `lsn <= fromLsn` once dropped the very
first transaction of a snapshotless log, because LSN 0 is not a real LSN
(`openWal` starts at 1). Re-opening a log continues its LSN sequence
rather than restarting at 1: a reset would hand two frames the same LSN,
and recovery would then skip the reopened frames as though their snapshot
already contained them. Running recovery twice *into the same store* is
refused rather than double-applied — applying an already-applied frame is
not reliably a no-op for value payloads, so the guarantee is made at the
entry point instead.

**Transactions are all-or-nothing.** A `txn_id` whose `COMMIT` frame is
absent at the truncation point is discarded entirely — its shadow
structure is dropped, not merged. This is the atomicity guarantee, and it
falls out of the log format rather than being bolted on.

**Index rebuild is not replay.** Rebuilding HNSW from live records costs
O(store size), which is bounded and predictable, versus O(log length),
which is not.

---

## 6. Durability settings

| Setting | Default | Effect |
|---|---|---|
| `fsync_on_commit` | on | `commit` returns after `fdatasync` |
| `wal_checkpoint_bytes` | 64 MB | auto-checkpoint threshold |
| `sync_mode` | `FULL` | `FULL` or `NORMAL` (fsync at checkpoint only) |

`sync_mode = NORMAL` is SQLite's `WAL` mode: an order of magnitude faster,
and it can lose the last few commits on **power loss** (not on process
crash — the page cache survives that). The default is `FULL` because the
default is what people ship, and a database that is fast-but-lossy gets
discovered as fast-but-lossy in production.

Per-transaction override: `tx.sync = false` lets an importer trade
durability for throughput inside a bulk load, then the final `commit` is
still full. Pinned: the *default* is full durability; NORMAL is opt-in
and named for what it costs.

---

## 7. Checkpoint policy

Auto-checkpoint fires when the WAL exceeds `wal_checkpoint_bytes`,
checked at `commit` boundaries only — never mid-transaction, because a
checkpoint mid-transaction would have to publish a partial commit.

Checkpoint is synchronous when triggered by a `commit` (correctness
first) and asynchronous when triggered by the threshold during a bulk
import (throughput first). The async path snapshots at the last
published generation and lets in-flight work continue against the
pre-checkpoint state.

`db.checkpoint(flags)` is manual, with `GLY_CHECKPOINT_TRUNCATE` to reset
the WAL and `GLY_CHECKPOINT_FSYNC` to force the device write.

---

## 8. Gates

M2 lands only when all of these pass:

| # | Gate | Method | Status |
|---|---|---|---|
| W1 | `kill -9` at 100 random points during a 10⁶-node import; every run recovers to the **last committed transaction**, byte-identical to a clean shutdown | `tests/fuzz/crash_harness.nim`: SIGKILL at random ms offsets, then re-run the child at the *same seed* stopped at the recovered transaction and compare the full fingerprint — label, endpoints, every property value | **green** at 25–30 kills × 100 txns; the 10⁶-node scale runs on `nimble crash`'s full numbers |
| W2 | Power-loss simulation: truncate the file at every 4 KB boundary; every outcome is a clean open or a named error | truncate-and-open fuzzer over a real WAL | **green** — `nimble bitflip` sweeps a 107 KB snapshot + 115 KB log at every 4 KB boundary (55 cuts: 28 clean opens, 27 named errors, none serving more data than the whole file). It found a crash-class defect: a snapshot truncated below its header raised `AssertionDefect`, which is not a `CatchableError` and took the host process down. |
| W3 | Bit-flip fuzzing: 10⁶ single-bit flips across the WAL; no crash, no silent corruption | `integrity_check` must report, never pass | **green** — `nimble bitflip` at the full 10⁶: **999 883 named errors, 0 silent corruptions**, 65 min. 117 flips land in the *final* frame's length field, which is byte-identical to a crash between writing that frame's header and its payload (W4 says drop it); the harness counts those separately as `ambiguous` and fails on anything else. It found three defects no unit test had — see DEVLOG. |
| W4 | Torn tail: append 1–31 garbage bytes; recovery truncates and opens clean | direct append of partial frame | **green** — unit-tested, and the harness produces them naturally |
| W5 | Replay idempotence: recover twice, compare state hash | exactly-once entry guard + LSN continuation across reopen | **green** — unit-tested |
| W6 | Checkpoint during open WAL: crash mid-checkpoint recovers to old snapshot + longer WAL | SIGKILL in the checkpoint window | **green** as unit tests (stale `.tmp`, truncated snapshot refused, rename-is-the-commit-point); the in-window SIGKILL is inside the harness's kill spread but not isolated |
| W7 | Throughput: fsynced commit ≥ 2 000 txn/s on the gate machine; `NORMAL` ≥ 15 000 txn/s | benchmark harness | not implemented |

W1 is the project's real test. W3 is the one that catches bugs in the
recovery code itself, because it feeds recovery inputs that never occur
in normal operation — and it did: the truncating-open bugs below were
found by the unit tests W2/W4 stand in for, not by the harness, because
the harness never re-opens a log it did not just create.

---

## 9. Pins

| # | Pin |
|---|---|
| W1 | One snapshot file plus a `-wal` sidecar and a `-lock`; one data file total |
| W2 | Frame header is exactly 32 bytes as tabulated; CRC32 over header[0..20] ‖ payload |
| W3 | One `write()` per frame; frames never batched across transactions |
| W4 | Mutations are typed opcodes, never Cypher text |
| W5 | Index state is never in the WAL; indexes rebuild from live records at open |
| W6 | Snapshot has a 128-byte header, a trailer CRC over the whole body, and a trailing magic |
| W7 | Snapshot is mmap'd read-only; overflow offsets are arena-relative and rebased on read |
| W8 | A transaction without a `COMMIT` frame at the truncation point is discarded whole |
| W9 | Replay is idempotent by `lsn`; recovery can be re-run safely |
| W10 | Default is fsynced commit (`sync_mode = FULL`); `NORMAL` is opt-in |
| W11 | Checkpoint only at commit boundaries, never mid-transaction |
| W12 | Checkpoint renumbers ids; live statements remap via a retained old→new table |
| W13 | Locking is `flock`, not pid liveness |
| W14 | No rollback journal in 0.1; the WAL plus snapshots are the whole durability story |

---

## 10. Open questions

- **Snapshot-corrupt fallback.** §5's original sketch had recovery fall
  back to an empty base plus a full-log replay when the snapshot fails
  its CRC; the implementation refuses instead. Refusing is the safer
  default while the WAL and snapshot are the only copies, but a corrupt
  snapshot with a complete WAL is fully recoverable in principle, and a
  database that will not open is a poor answer to "SQLite of graphs".
  Decide before the FFI layer maps the refusal to `GLY_ERR_IO`, because
  after that it becomes an API contract.
- **Header size.** 128 bytes is mostly reserved. If a future version wants
  3 snapshots in one file (point-in-time recovery, phase 2), the header
  grows. Writing it as 128 now avoids a format bump later, at the cost of
  96 bytes of zeros per snapshot — free, since it is one page.
- **CRC32 vs xxhash.** CRC32 is 1 GB/s and hardware-accelerated; the WAL
  is bounded to tens of MB between checkpoints, so a faster hash buys
  nothing. Revisit if `wal_checkpoint_bytes` ever rises by 100x.
- **Torn-write detection beyond the tail.** A partial frame in the
  *middle* of the WAL is impossible by construction (appends are
  sequential), which is why W2 only truncates at the end. This is an
  assumption worth stating explicitly in case a future phase adds
  in-place updates.
- **`sync_mode` as a per-transaction override.** Specified as
  `tx.sync = false` for bulk import. The alternative is a session-level
  setting, which is easier to reason about and easier to get wrong by
  accident. Leaning toward session-level with a loud warning; not pinned.
