## glyphes — M2: WAL, snapshot and recovery (docs/WAL.md).
##
## The distinction that shapes this file is the one between a bug the unit
## tests can see and one only the crash harness can see. A torn tail is
## deterministic, so it is here; a kill in the middle of a commit is not,
## so it belongs to `tests/fuzz/crash_harness.nim`. What is here is every
## gate from WAL.md §7 that a seeded, single-process test can decide:
## W2 truncation, W3 bit flips, W4 torn tails, W5 replay idempotence.
##
## The oracle throughout is the invariant check (STORAGE.md S1-S10) plus
## the marker property, the same last-committed-transaction probe the
## harness uses.

import std/unittest
import std/os
import std/strutils
import std/sequtils
import ../../src/store/store
import ../../src/store/prop
import ../../src/wal/crc32
import ../../src/wal/wal
import ../../src/errors
from ../../src/abi import glyErrCorrupt, GLY_OPEN_CREATE
import ../../src/wal/snapshot
import ../../src/wal/recover
import ../../src/txn/txn
import ../../src/database

proc walDir(): string =
  ## Scratch under the repo's own tmp/, per the build layout, wiped per
  ## test so a stale log from an earlier run cannot be mistaken for the
  ## one this test wrote.
  let d = "tmp" / "test-wal"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = walDir() / name
  removeFile(p); removeFile(p & "-wal"); removeFile(p & ".tmp")
  result = p

proc lastMarker(s: GraphStore): int64 =
  ## The highest `txn` property among Marker nodes: the last transaction
  ## whose effects are visible. This is exactly what a clean shutdown
  ## leaves behind, so recovery must reproduce it.
  let marker = s.labels.lookup("Marker")
  if marker == 0: return -1
  for i in 1'i64 ..< int64(s.nodes.len):
    let n = s.nodes[i.int]
    if n.id != 0 and n.label == marker:
      var v: Value
      if s.getNodeProp(i, "txn", v):
        result = max(result, v.i)

proc badInvariants(s: GraphStore): string =
  for inv in s.check():
    if not inv.ok:
      result.add inv.code & ": " & inv.detail & "; "

proc checkClean(s: GraphStore) =
  let bad = badInvariants(s)
  check bad == ""

suite "crc32 (WAL.md §2)":
  test "published IEEE vectors":
    check crc32("", 0) == 0x00000000'u32
    check crc32("a") == 0xE8B7BE43'u32
    check crc32("abc") == 0x352441C2'u32
    check crc32("123456789") == 0xCBF43926'u32
    check crc32("The quick brown fox jumps over the lazy dog") == 0x414FA339'u32

  test "two-call seeding equals one call over the concatenation":
    ## encodeFrame checksums header and payload in two calls so a large
    ## payload is not copied to be checksummed. That is only correct if
    ## the seeds compose exactly; the property is checked here rather
    ## than believed, because it is true until someone changes a
    ## constant.
    let head = "0123456789ABCDEFGHIJ"
    let payload = "payload bytes that are not ASCII on purpose \x00\x01\x02"
    let one = crc32(head & payload)
    let two = crc32(payload, crc32(head))
    check one == two

  test "crc32 of a string and its openArray form agree":
    let s = "abcdefgh"
    check crc32(s) == crc32(s.toOpenArrayByte(0, s.high))

suite "frame codec (WAL.md §2)":
  test "encode then decode preserves every header field":
    ## The payload is padded past opSetProp's 17-byte minimum: decode
    ## enforces the opcode table now, and this test's subject is the codec
    ## round-trip, not the length rule (which has its own test below).
    let f = Frame(lsn: 42'u64, txnId: 7'u32, op: opSetProp,
                  txnFlags: TxnCommit,
                  payload: "\x01\x02\x03tail-padded-past-the-op-minimum")
    let d = decodeFrame(encodeFrame(f), 0, FrameHeaderSize + f.payload.len)
    check d.consumed == FrameHeaderSize + f.payload.len
    check d.frame.lsn == 42'u64
    check d.frame.txnId == 7'u32
    check d.frame.op == opSetProp
    check d.frame.txnFlags == TxnCommit
    check d.frame.payload == f.payload

  test "a commit marker is a zero-payload opNoop frame with TxnCommit":
    ## WAL.md §3: the marker carries no mutation, so it is opNoop with the
    ## flag. A previous design flagged a real opcode's frame, which replay
    ## would then have executed.
    let f = Frame(lsn: 1'u64, txnId: 1'u32, op: opNoop,
                  txnFlags: TxnCommit, payload: "")
    let d = decodeFrame(encodeFrame(f), 0, FrameHeaderSize)
    check d.consumed == FrameHeaderSize
    check d.frame.op == opNoop
    check (d.frame.txnFlags and TxnCommit) != 0'u32

  test "an empty payload decodes with no allocation surprises":
    let f = Frame(lsn: 9'u64, txnId: 2'u32, op: opNoop, txnFlags: 0'u32,
                  payload: "")
    let d = decodeFrame(encodeFrame(f), 0, FrameHeaderSize)
    check d.consumed == FrameHeaderSize
    check d.frame.payload == ""

suite "torn tails and corruption (WAL.md §7 W2-W4)":
  test "a header short of 32 bytes is a torn tail":
    let f = Frame(lsn: 1'u64, txnId: 1'u32, op: opNoop,
                  txnFlags: TxnCommit, payload: "")
    let bytes = encodeFrame(f)[0 ..< FrameHeaderSize - 1]
    let d = decodeFrame(bytes, 0, bytes.len)
    check d.consumed == 0
    check d.reason == "incomplete header"

  test "a payload length running past the end is refused, not allocated":
    ## A corrupt length field must not become a huge allocation on the
    ## recovery path; the check runs before the payload is sliced.
    let f = Frame(lsn: 1'u64, txnId: 1'u32, op: opNoop,
                  txnFlags: TxnCommit, payload: "real payload")
    var bytes = encodeFrame(f)
    ## Claim a payload far longer than the frame holds.
    bytes[16] = char(0xF0)
    bytes[17] = char(0xFF)
    bytes[18] = char(0xFF)
    bytes[19] = char(0x0F)
    let d = decodeFrame(bytes, 0, bytes.len)
    check d.consumed == 0
    check d.reason.contains("runs past end")

  test "a flipped bit in the header is caught by the CRC (W3)":
    let f = Frame(lsn: 5'u64, txnId: 3'u32, op: opCreateNode,
                  txnFlags: 0'u32, payload: "0123456789abcdef")
    var bytes = encodeFrame(f)
    let before = bytes[6]
    bytes[6] = char(uint8(before) xor 0x40'u8)
    let d = decodeFrame(bytes, 0, bytes.len)
    check d.consumed == 0
    check d.reason.contains("crc mismatch")

  test "a flipped bit in the payload is caught by the CRC (W3)":
    let f = Frame(lsn: 5'u64, txnId: 3'u32, op: opSetProp,
                  txnFlags: 0'u32, payload: "0123456789abcdef")
    var bytes = encodeFrame(f)
    let at = FrameHeaderSize + 3
    let before = bytes[at]
    bytes[at] = char(uint8(before) xor 0x01'u8)
    check before != bytes[at]
    let d = decodeFrame(bytes, 0, bytes.len)
    check d.consumed == 0

  test "a torn tail keeps every earlier frame decodable (W4)":
    let a = encodeFrame(Frame(lsn: 1'u64, txnId: 1'u32, op: opNoop,
                              txnFlags: TxnCommit, payload: ""))
    let b = encodeFrame(Frame(lsn: 2'u64, txnId: 2'u32, op: opNoop,
                              txnFlags: TxnCommit, payload: ""))
    var bytes = a & b
    bytes.setLen(a.len + b.len - 7)
    let d1 = decodeFrame(bytes, 0, bytes.len)
    check d1.consumed == a.len
    let d2 = decodeFrame(bytes, d1.consumed, bytes.len)
    check d2.consumed == 0
    check d2.reason == "incomplete header"

suite "transactions (TXN.md via WAL.md §3)":
  test "a committed transaction is merged and durable":
    let path = freshPath("commit.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    let id = tx.createNode("Person")
    check id != 0
    check tx.setNodeProp(id, "name", Value(kind: vkString, s: "ada"))
    check tx.commit()
    closeWal(w)
    check store.nodeCount() == 1
    var v: Value
    check store.getNodeProp(id, "name", v)
    check v.s == "ada"
    checkClean(store)

  test "a rolled-back transaction leaves nothing behind":
    let path = freshPath("rollback.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx1 = begin(store, w, 1'u32, doSync = false)
    let kept = tx1.createNode("Person")
    check tx1.commit()
    let tx2 = begin(store, w, 2'u32, doSync = false)
    discard tx2.createNode("Ghost")
    check tx2.rollback()
    closeWal(w)
    check store.nodeCount() == 1
    ## S2 permits burning ids on rollback: the ghost's id is never reused,
    ## which is what keeps a replayed log from colliding with live records.
    check store.nodeIds.next > kept

  test "a transaction whose commit marker is lost is discarded whole (W1 unit)":
    ## The frames are appended, the marker is not: the ordinary kill
    ## between the last mutation and the commit. Recovery must apply
    ## nothing from it, not the first half.
    let path = freshPath("lostmarker.glyph")
    let store = newStore()
    block:
      let w = openWal(path & "-wal")
      let tx1 = begin(store, w, 1'u32, doSync = false)
      discard tx1.createNode("Person")
      check tx1.commit()
      let tx2 = begin(store, w, 2'u32, doSync = false)
      discard tx2.createNode("Ghost")
      # Mutation frames without the commit marker, as a killed process
      # would leave them.
      discard tx2.wal.appendFrames(tx2.frames)
      closeWal(w)
    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.tornTail == false
    check rec.transactionsCommitted == 1
    check rec.transactionsDiscarded == 1
    check s2.nodeCount() == 1
    checkClean(s2)

  test "a cascade delete leaves no tombstone linked and no degree drift":
    let path = freshPath("cascade.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    let a = tx.createNode("Person")
    let b = tx.createNode("Person")
    let e1 = tx.createEdge(a, b, "KNOWS")
    let e2 = tx.createEdge(a, b, "KNOWS")
    let e3 = tx.createEdge(b, a, "KNOWS")
    check e1 != 0 and e2 != 0 and e3 != 0
    ## Two edges out of `a`, one in: removing several edges of one chain
    ## in a single transaction is the case that was order-dependent, and
    ## the outcome used to depend on hash-table iteration order.
    check tx.deleteEdge(e1)
    check tx.deleteEdge(e2)
    check tx.deleteEdge(e3)
    check tx.deleteNode(a, cascade = false)
    check tx.commit()
    closeWal(w)
    check store.edgeCount() == 0
    check store.nodeCount() == 1
    checkClean(store)

  test "deleting a node cascades to edges created in the same transaction":
    ## Edges made inside this transaction are not in the committed chains,
    ## so a cascade that walked only the base store would leave them live
    ## and pointing at a tombstone (S9b).
    let path = freshPath("cascade-tx.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    let a = tx.createNode("Person")
    let b = tx.createNode("Person")
    check tx.commit()
    let tx2 = begin(store, w, 2'u32, doSync = false)
    let e1 = tx2.createEdge(a, b, "KNOWS")
    let e2 = tx2.createEdge(a, b, "KNOWS")
    check tx2.deleteNode(a, cascade = true)
    check tx2.commit()
    closeWal(w)
    check store.edgeCount() == 0
    check store.nodeCount() == 1
    checkClean(store)

suite "snapshot round-trip (WAL.md §4)":
  test "a loaded store is indistinguishable from the writer":
    let path = freshPath("snap.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    var made: seq[int64] = @[]
    block:
      let tx = begin(store, w, 1'u32, doSync = false)
      for i in 0 ..< 12:
        let id = tx.createNode(if i mod 2 == 0: "Person" else: "Doc")
        made.add id
        discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: int64(id)))
        ## Overflowing and short strings both: one goes to the arena, one
        ## stays inline, and the slot block has to round-trip both.
        if i mod 3 == 0:
          discard tx.setNodeProp(id, "bio",
            Value(kind: vkString, s: "bio-" & $i & "-" & "y".repeat(70)))
        else:
          discard tx.setNodeProp(id, "tag",
            Value(kind: vkString, s: "t" & $i))
      let e1 = tx.createEdge(made[0], made[1], "KNOWS")
      let e2 = tx.createEdge(made[1], made[2], "KNOWS")
      discard tx.setEdgeProp(e1, "w", Value(kind: vkFloat, f: 0.25))
      discard tx.setEdgeProp(e2, "w", Value(kind: vkFloat, f: 1.5))
      check tx.commit()
    let wantNodes = store.nodeCount()
    let wantEdges = store.edgeCount()
    let wantNextNode = store.nodeIds.next
    let wantNextEdge = store.edgeIds.next
    let wantLabelPos = store.labelPos
    writeSnapshot(store, path, uint64(w.nextLsn - 1))
    closeWal(w)

    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.snapshotFound
    check rec.framesReplayed == 0
    check s2.nodeCount() == wantNodes
    check s2.edgeCount() == wantEdges
    check s2.nodeIds.next == wantNextNode
    check s2.edgeIds.next == wantNextEdge
    check s2.labelPos == wantLabelPos
    ## The property the log claims to reproduce: the same bytes back.
    var v: Value
    check s2.getNodeProp(made[0], "n", v)
    check v.i == int64(made[0])
    check s2.getNodeProp(made[0], "bio", v)
    check v.s.startsWith("bio-")
    var w2: Value
    check s2.getEdgeProp(1'i64, "w", w2)
    check w2.f == 0.25
    checkClean(s2)

  test "a snapshot-only reopen publishes what readers scan":
    ## `recover` loaded the snapshot into the store's own arrays and
    ## returned without publishing them. Every full scan reads the
    ## `published` bundle (store.nim), so a graph reopened after a
    ## checkpoint and a close answered every query with zero rows while
    ## `nodeCount` — and therefore `integrity_check` — still counted the
    ## nodes. One post-checkpoint write hid it by publishing at commit,
    ## which is why the snapshot round-trip above never saw it: it reads
    ## through `getNodeProp`, not through a reader.
    let path = freshPath("snap-publish.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    block:
      let tx = begin(store, w, 1'u32, doSync = false)
      for i in 0 ..< 4:
        discard tx.createNode("Book")
      discard tx.createEdge(1, 2, "NEXT")
      check tx.commit()
    writeSnapshot(store, path, uint64(w.nextLsn - 1))
    closeWal(w)
    let s2 = newStore()
    check recover(path, s2).snapshotFound
    ## The owning arrays are there — that is the half a broken fix would
    ## leave green.
    check s2.nodeCount() == 4
    let snap = beginRead(s2)
    var nodesSeen = 0
    for i in 1 ..< snap.nodes.len:
      if snap.nodes[i].live:
        inc nodesSeen
    var edgesSeen = 0
    for i in 1 ..< snap.edges.len:
      if snap.edges[i].live:
        inc edgesSeen
    endRead(snap)
    check nodesSeen == 4
    check edgesSeen == 1
    checkClean(s2)

  test "a snapshot records the lsn it was written at":
    ## A snapshot that recorded lsn 0 would make every pre-checkpoint
    ## frame replay again on top of state that already contains it.
    let path = freshPath("snap-lsn.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    discard tx.createNode("Person")
    check tx.commit()
    writeSnapshot(store, path, uint64(w.nextLsn - 1))
    let lsnAtSnapshot = w.nextLsn - 1
    closeWal(w)
    check lsnAtSnapshot > 0
    let bytes = readFile(path)
    ## Header layout: magic(8), version(4), header_crc(4), lsn(8).
    check getU64(bytes, 16) == lsnAtSnapshot

suite "recovery (WAL.md §5)":
  test "replay reaches the last committed transaction with no snapshot":
    ## fromLsn == 0 means "no snapshot": the whole log replays. An
    ## unguarded `lsn <= fromLsn` dropped the very first transaction.
    let path = freshPath("replay-all.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    for t in 1'u32 .. 6'u32:
      let tx = begin(store, w, t, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
      check tx.commit()
    closeWal(w)
    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.snapshotFound == false
    check rec.transactionsCommitted == 6
    check rec.transactionsDiscarded == 0
    check lastMarker(s2) == 6
    check s2.nodeCount() == 6
    checkClean(s2)

  test "checkpoint plus tail replays exactly the post-checkpoint frames":
    let path = freshPath("ckpt.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    for t in 1'u32 .. 8'u32:
      let tx = begin(store, w, t, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
      check tx.commit()
      if t == 5:
        writeSnapshot(store, path, uint64(w.nextLsn - 1))
    closeWal(w)
    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.snapshotFound
    check rec.transactionsCommitted == 3
    check lastMarker(s2) == 8
    check s2.nodeCount() == 8
    checkClean(s2)

  test "recovering twice into the same store is refused, not double-applied":
    ## Replay is exactly-once per store. A second recover into a store
    ## that already holds the frames would apply them again; that is a
    ## caller error and is raised rather than silently duplicating state.
    let path = freshPath("twice.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    discard tx.createNode("Person")
    check tx.commit()
    closeWal(w)
    let s2 = newStore()
    discard recover(path, s2)
    let nodes = s2.nodeCount()
    expect(ValueError):
      discard recover(path, s2)
    check s2.nodeCount() == nodes

  test "a bit flip in the log is damage: recovery refuses and leaves the file (W3)":
    ## The first version of this test asserted the opposite — that a bit
    ## flip "stops replay there, earlier commits survive". That is the
    ## behaviour WAL.md W3 forbids: the log is damaged, the tail after the
    ## damage is not a crash but lost transactions, and opening anyway
    ## serves a database that is quietly missing them. The bit-flip sweep
    ## found it precisely because the unit test had encoded it as correct.
    let path = freshPath("flip.glyph")
    block:
      let store = newStore()
      let w = openWal(path & "-wal")
      for t in 1'u32 .. 4'u32:
        let tx = begin(store, w, t, doSync = false)
        let m = tx.createNode("Marker")
        discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
        check tx.commit()
      closeWal(w)
    ## Corrupt a byte inside the third transaction's frames. The offset
    ## is found by decoding rather than assumed: frame sizes depend on the
    ## payload, and a test that hard-codes one is a test that passes for
    ## the wrong reason.
    var bytes = readFile(path & "-wal")
    var at = 0
    var txn3At = -1
    while at < bytes.len:
      let d = decodeFrame(bytes, at, bytes.len)
      if d.consumed == 0: break
      if d.frame.txnId == 3 and txn3At < 0: txn3At = at
      at += d.consumed
    check txn3At > 0
    bytes[txn3At + 5] = char(uint8(bytes[txn3At + 5]) xor 0x08'u8)
    writeFile(path & "-wal", bytes)
    let onDisk = readFile(path & "-wal")

    let s2 = newStore()
    ## A named error, not a truncated success.
    var refused = false
    try:
      discard recover(path, s2)
    except GlyError as e:
      refused = (e.status == glyErrCorrupt)
    check refused
    ## The damaged log is left exactly as found: truncating it would destroy
    ## the only evidence of what went wrong.
    check readFile(path & "-wal") == onDisk

  test "the commit flag is inside the frame CRC (W3)":
    ## `txnFlags` sits after the crc32 field in the header, so covering
    ## only the bytes before it left the COMMIT bit unchecked. Flipping it
    ## turned a committed transaction into an uncommitted one: the log
    ## replayed into a graph holding that transaction's nodes as if they
    ## had committed, CRC valid, no error anywhere. The sweep found this
    ## one; every unit test flipped a byte the CRC was already watching.
    let path = freshPath("commitflag.glyph")
    block:
      let store = newStore()
      let w = openWal(path & "-wal")
      let tx = begin(store, w, 1'u32, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: 1'i64))
      check tx.commit()
      closeWal(w)
    var bytes = readFile(path & "-wal")
    var at = 0
    var commitAt = -1
    while at < bytes.len:
      let d = decodeFrame(bytes, at, bytes.len)
      if d.consumed == 0: break
      if (d.frame.txnFlags and TxnCommit) != 0'u32: commitAt = at
      at += d.consumed
    check commitAt >= 0
    bytes[commitAt + 24] = char(uint8(bytes[commitAt + 24]) xor 0x01'u8)
    writeFile(path & "-wal", bytes)

    let s2 = newStore()
    var refused = false
    try:
      discard recover(path, s2)
    except GlyError as e:
      refused = (e.status == glyErrCorrupt)
    check refused

  test "a torn tail is still dropped, not refused (W4)":
    ## The distinction W3 forced: a frame that was *never finished* (a
    ## crash between the header and the payload) is dropped, because that
    ## transaction never committed. This is the ordinary kill -9 case and
    ## refusing it would make every crash unrecoverable.
    let path = freshPath("torn.glyph")
    block:
      let store = newStore()
      let w = openWal(path & "-wal")
      for t in 1'u32 .. 3'u32:
        let tx = begin(store, w, t, doSync = false)
        let m = tx.createNode("Marker")
        discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
        check tx.commit()
      closeWal(w)
    ## Append a partial fourth frame: a complete header, no payload.
    var bytes = readFile(path & "-wal")
    var head = encodeFrame(Frame(lsn: 99'u64, txnId: 4'u32, op: opCreateNode,
                                 txnFlags: TxnCommit,
                                 payload: "a long payload that never lands"))
    head = head[0 ..< FrameHeaderSize]
    writeFile(path & "-wal", bytes & head)

    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.tornTail
    check rec.transactionsCommitted == 3
    check lastMarker(s2) == 3
    checkClean(s2)

  test "truncation of the log to its valid prefix is stable across opens (W2)":
    let path = freshPath("trunc.glyph")
    block:
      let store = newStore()
      let w = openWal(path & "-wal")
      for t in 1'u32 .. 3'u32:
        let tx = begin(store, w, t, doSync = false)
        let m = tx.createNode("Marker")
        discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
        check tx.commit()
      closeWal(w)
    var bytes = readFile(path & "-wal")
    bytes.setLen(bytes.len - 11)
    writeFile(path & "-wal", bytes)

    let s2 = newStore()
    discard recover(path, s2)
    check lastMarker(s2) == 2
    let afterFirst = getFileSize(path & "-wal")
    let s3 = newStore()
    let rec2 = recover(path, s3)
    check rec2.tornTail == false
    check lastMarker(s3) == 2
    check getFileSize(path & "-wal") == afterFirst

  test "a reopened log continues its lsn sequence (W5)":
    ## An LSN that reset to 1 on every open would hand the same lsn to two
    ## frames; with a snapshot in between, recovery would then skip the
    ## reopened log's frames as if the snapshot already contained them.
    let path = freshPath("reopen.glyph")
    block:
      let store = newStore()
      let w = openWal(path & "-wal")
      let tx = begin(store, w, 1'u32, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: 1))
      check tx.commit()
      writeSnapshot(store, path, uint64(w.nextLsn - 1))
      closeWal(w)
    block:
      ## Reopen the same log and append. The snapshot's lsn is whatever
      ## the first open reached; the new frames must land above it.
      let store = newStore()
      let w = openWal(path & "-wal")
      check w.nextLsn > 1
      let tx = begin(store, w, 2'u32, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: 2))
      check tx.commit()
      closeWal(w)
    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.transactionsCommitted == 1
    check lastMarker(s2) == 2
    checkClean(s2)

  test "recovery into a store that already has records is refused":
    let path = freshPath("dirty.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    discard tx.createNode("Person")
    check tx.commit()
    closeWal(w)
    expect(ValueError):
      discard recover(path, store)

suite "checkpoint safety (WAL.md §7 W6)":
  test "a stale .tmp from an interrupted checkpoint is ignored by recovery":
    ## writeSnapshot writes to `path.tmp` and renames. A crash between the
    ## two leaves a complete-or-not tmp and the *old* snapshot in place;
    ## recovery reads the old snapshot plus the WAL and must reach the
    ## last committed transaction regardless of what the tmp holds.
    let path = freshPath("w6-stale.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    for t in 1'u32 .. 8'u32:
      let tx = begin(store, w, t, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
      check tx.commit()
      if t == 5:
        writeSnapshot(store, path, uint64(w.nextLsn - 1))
    ## The interrupted checkpoint: a half-written tmp, as a SIGKILL in the
    ## middle of `writeSnapshot` would leave behind.
    writeFile(path & ".tmp", "GLYPHSN1-this-is-a-half-written-snapshot")
    closeWal(w)

    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.snapshotFound
    check lastMarker(s2) == 8
    checkClean(s2)
    ## The tmp is not part of the contract; recovery leaves it alone.
    check fileExists(path & ".tmp")

  test "a truncated snapshot is refused loudly, never half-applied":
    ## A snapshot that fails its CRC is worse than no snapshot if it were
    ## half-loaded and then replayed onto. Refusal is the documented
    ## behaviour (WAL.md §5); the test pins it so "fall back to the WAL"
    ## cannot be introduced silently — that would be a different, and
    ## defensible, policy, but it has to be a decision.
    let path = freshPath("w6-trunc.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(store, w, 1'u32, doSync = false)
    discard tx.createNode("Person")
    check tx.commit()
    writeSnapshot(store, path, uint64(w.nextLsn - 1))
    closeWal(w)
    var bytes = readFile(path)
    check bytes.len > SnapshotHeaderSize + 12
    bytes.setLen(SnapshotHeaderSize + 5)
    writeFile(path, bytes)
    expect(ValueError):
      discard recover(path, newStore())

  test "a crash between tmp write and rename still recovers to the last commit":
    ## The rename is the commit point of a checkpoint. Before it, the old
    ## snapshot plus the tail is the state of record; after it, the new
    ## snapshot is. Both must recover to the same transaction.
    let path = freshPath("w6-rename.glyph")
    let store = newStore()
    let w = openWal(path & "-wal")
    for t in 1'u32 .. 6'u32:
      let tx = begin(store, w, t, doSync = false)
      let m = tx.createNode("Marker")
      discard tx.setNodeProp(m, "txn", Value(kind: vkInt, i: int64(t)))
      check tx.commit()
      if t == 3:
        writeSnapshot(store, path, uint64(w.nextLsn - 1))
    ## A checkpoint of the *current* state that never got its rename.
    writeSnapshot(store, path & ".tmp", uint64(w.nextLsn - 1))
    closeWal(w)

    let s2 = newStore()
    let rec = recover(path, s2)
    check rec.snapshotFound
    check rec.transactionsCommitted == 3
    check lastMarker(s2) == 6
    checkClean(s2)

suite "review regressions: maintenance refuses a live writer (W11)":
  test "checkpoint is refused while a transaction is open, and works after":
    ## The committer appends and fsyncs its log BEFORE taking the merge
    ## gate, so the gate checkpoint holds cannot close the race: without
    ## the refusal, a checkpoint in the window snapshots pre-merge arrays
    ## stamped at the log's tip, truncates the frames the commit just made
    ## durable, and loses an acknowledged commit with no error at open.
    ## The fence reads the store's writer claim — the ground truth — so it
    ## catches transactions opened below the ABI (Database.beginTransaction,
    ## which is what this test does) as well as attached ones.
    let path = freshPath("w11-fence.glyph")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    block:
      let t = db.beginTransaction()
      discard t.createNode("A")
      check db.commitTransaction(t)
    let tx = db.beginTransaction()
    discard tx.setNodeProp(1, "x", Value(kind: vkInt, i: 1))
    expect GlyError:
      db.checkpoint()
    expect GlyError:
      db.vacuum()
    check db.rollbackTransaction(tx)
    ## Idle again: both maintenance verbs run, and the checkpoint stamp
    ## matches the applied position.
    db.checkpoint(truncate = true)
    check getFileSize(path & "-wal") == 0
    close(db)

suite "review regressions: frame validity is the opcode's business too":
  test "a crc-valid frame shorter than its opcode requires is named, not a defect":
    ## decodeFrame enforced length only against the *file*. A crafted frame
    ## — a recomputed CRC over a too-short payload — reached applyFrame's
    ## unchecked indexing and raised a Defect, which is not a CatchableError
    ## and so unwound past the ABI's guarded boundary into the host. WAL.md
    ## §2.1 makes the opcode's minimum part of validity; now validity is
    ## decided where it is checked.
    let short = encodeFrame(Frame(lsn: 9, txnId: 1, op: opSetProp,
                                  txnFlags: 0, payload: "\x00\x01\x02"))
    let r = decodeFrame(short, 0, short.len)
    check r.consumed == 0
    check r.corrupt == true
    check "shorter" in r.reason
    ## An unknown opcode — a frame this version never writes — is named
    ## too, rather than reaching applyFrame's catch-all raise.
    let unknown = encodeFrame(Frame(lsn: 10, txnId: 1, op: Opcode(3),
                                    txnFlags: 0, payload: ""))
    let u = decodeFrame(unknown, 0, unknown.len)
    check u.consumed == 0
    check u.corrupt == true
    check "unknown opcode" in u.reason
    ## A healthy frame still decodes: the table must not over-reject. A
    ## commit marker is exactly an empty-payload Noop.
    let good = encodeFrame(Frame(lsn: 11, txnId: 1, op: opNoop,
                                 txnFlags: TxnCommit, payload: ""))
    check decodeFrame(good, 0, good.len).consumed == FrameHeaderSize
