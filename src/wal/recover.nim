## glyphes — the snapshot reader and WAL recovery (WAL.md §4.1, §5)
##
## Open in five steps, and the order is the whole design:
##
##   1. lock
##   2. load the snapshot, if there is one, validating its CRCs
##   3. replay the WAL from `snapshot.lsn + 1`, stopping at the first bad
##      frame
##   4. truncate the WAL to the last valid frame
##   5. rebuild anything derived
##
## Step 3's stop condition is the torn tail, and step 4 exists because a
## tail that is left in place will be re-examined on every subsequent
## open and will keep producing the same warning.
##
## ##1 A transaction is committed or it does not exist
##
## Replay applies frames into per-transaction deltas and merges a
## transaction's effects only when its COMMIT frame arrives. A transaction
## whose frames are all present but whose COMMIT frame is not — the
## normal outcome of `kill -9` between the last mutation frame and the
## commit marker — is discarded whole. That is the atomicity guarantee,
## and it falls out of the log format rather than being bolted on.

when defined(posix):
  import posix
import std/os
import std/strutils
import ./wal
import ./crc32
import ./snapshot
import ../store/store
import ../errors
from ../abi import glyErrCorrupt
import ../txn/txn

type
  Recovery* = object
    snapshotFound*: bool
    snapshotLsn*: uint64
    snapshotGeneration*: uint64
    walBytesScanned*: int64
    framesReplayed*: int
    transactionsCommitted*: int
    transactionsDiscarded*: int
    tornTail*: bool
    ## Set only for the torn tail, never for damage: a damaged log refuses
    ## to open, so a Recovery that exists at all has no damage in it. The
    ## field exists so `integrity_check` on a database opened *after* a
    ## truncation can say what was dropped.
    corruptReason*: string
    tornReason*: string
    validBytes*: int64
    replayedUpToLsn*: uint64

proc readSnapshotHeader(buf: string): SnapshotHeader =
  ## A `doAssert` here is a crash, not an error: in a release build the
  ## assert is compiled out, and in a checked build `AssertionDefect` is
  ## *not* a `CatchableError`, so it unwinds past every host `rescue` and
  ## takes the process down. A snapshot truncated by power loss is shorter
  ## than its own header — the ordinary case W2 sweeps — and the answer to
  ## "this file is too short to be a snapshot" is a refusal the caller can
  ## catch, not an abort.
  if buf.len < SnapshotHeaderSize:
    fail(glyErrCorrupt,
         "snapshot: " & $buf.len & " bytes is shorter than the " &
         $SnapshotHeaderSize & "-byte header; the file is truncated or damaged")
  let magic = buf[0 ..< SnapshotMagic.len]
  if magic != SnapshotMagic:
    raise newException(ValueError, "snapshot: bad magic")
  let version = getU32(buf, 8)
  if version != SnapshotFormatVersion:
    raise newException(ValueError,
      "snapshot: format version " & $version & ", expected " &
      $SnapshotFormatVersion)
  let wantCrc = getU32(buf, 12)
  let gotCrc = crc32(buf[0 ..< 12])
  if wantCrc != gotCrc:
    raise newException(ValueError, "snapshot: header CRC mismatch")
  result.lsn = getU64(buf, 16)
  result.nodeCount = getU64(buf, 24)
  result.edgeCount = getU64(buf, 32)
  result.slotCount = getU64(buf, 40)
  result.arenaBytes = getU64(buf, 48)
  result.labelCount = getU64(buf, 56)
  result.relTypeCount = getU64(buf, 64)
  result.propKeyCount = getU64(buf, 72)
  result.indexCount = getU64(buf, 80)
  result.generation = getU64(buf, 88)
  result.nextNodeId = getU64(buf, 96)
  result.nextEdgeId = getU64(buf, 104)
  result.liveNodeCount = getU64(buf, 112)
  result.liveEdgeCount = getU64(buf, 120)

proc loadSnapshot*(buf: string, into: GraphStore): SnapshotHeader =
  ## Fills `into` from a validated snapshot. Raises on any structural
  ## problem: a corrupt snapshot is refused rather than partially applied,
  ## because a half-loaded store that then gets WAL replay on top of it is
  ## worse than a clean refusal.
  result = readSnapshotHeader(buf)

  # Trailer: body CRC then a second copy of the magic.
  if buf.len < SnapshotHeaderSize + 12:
    raise newException(ValueError, "snapshot: truncated, no trailer")
  let trailerAt = buf.len - 12
  let wantCrc = getU32(buf, trailerAt)
  if buf[trailerAt + 4 ..< trailerAt + 12] != SnapshotMagic:
    raise newException(ValueError, "snapshot: trailer magic missing")
  var bodyCrc = crc32(buf[16 ..< SnapshotHeaderSize])
  bodyCrc = crc32(buf[SnapshotHeaderSize ..< trailerAt], bodyCrc)
  if wantCrc != bodyCrc:
    raise newException(ValueError, "snapshot: body CRC mismatch")

  var at = SnapshotHeaderSize

  proc takeStrings(n: uint64, target: var Dictionary) =
    for _ in 0 ..< n.int:
      var stop = at
      while stop < buf.len and buf[stop] != '\0':
        inc stop
      if stop >= buf.len:
        raise newException(ValueError, "snapshot: unterminated dictionary string")
      let word = buf[at ..< stop]
      at = stop + 1
      let want = target.codes.len
      let got = target.intern(word)
      ## Codes are implicit by position (STORAGE.md §4), so a snapshot
      ## whose strings do not reproduce that order would silently
      ## reassign every code in the file. Checked rather than assumed.
      if got != int32(want):
        var have = ""
        for c in target.codes: have.add '|' & c
        raise newException(ValueError, "snapshot: dictionary entry " &
          $word & " got code " & $got & ", expected " & $want &
          " have=" & have & " at=" & $at)

  takeStrings(result.labelCount, into.labels)
  takeStrings(result.relTypeCount, into.relTypes)
  takeStrings(result.propKeyCount, into.propKeys)

  # Records. nodeCount includes tombstones and doubling padding, so the
  # array is that long and `live == 0` marks a slot with no record.
  let nodeSlots = result.nodeCount.int
  let edgeSlots = result.edgeCount.int
  if at + nodeSlots * sizeof(NodeRec) + edgeSlots * sizeof(EdgeRec) > buf.len:
    raise newException(ValueError, "snapshot: record section runs past end")
  into.nodes = newSeq[NodeRec](nodeSlots + 1)
  if nodeSlots > 0:
    copyMem(addr into.nodes[1], unsafeAddr buf[at], nodeSlots * sizeof(NodeRec))
  at += nodeSlots * sizeof(NodeRec)
  into.edges = newSeq[EdgeRec](edgeSlots + 1)
  if edgeSlots > 0:
    copyMem(addr into.edges[1], unsafeAddr buf[at], edgeSlots * sizeof(EdgeRec))
  at += edgeSlots * sizeof(EdgeRec)

  # Slot section, contiguous, in the order the records' offsets expect.
  let slotBytes = result.slotCount.int * sizeof(PropSlot)
  if at + slotBytes > buf.len:
    raise newException(ValueError, "snapshot: slot section runs past end")
  var slots = newSeq[PropSlot](max(result.slotCount.int, 1))
  if result.slotCount > 0:
    copyMem(addr slots[0], unsafeAddr buf[at], slotBytes)
  at += slotBytes

  # Arena, copied verbatim so every offset in every slot still resolves
  # with no rebasing pass.
  if at + result.arenaBytes.int > buf.len:
    raise newException(ValueError, "snapshot: arena section runs past end")
  into.arena.bytes = newSeq[uint8](max(result.arenaBytes.int, ArenaFirstOffset * 4))
  into.arena.bump = ArenaFirstOffset
  if result.arenaBytes > 0:
    copyMem(addr into.arena.bytes[0], unsafeAddr buf[at], result.arenaBytes.int)
    into.arena.bump = int(result.arenaBytes)
  at += result.arenaBytes.int

  # Distribute the slot block into the arena, giving each record its own
  # array, and rebuild the label index and labelPos together — they must
  # be built in the same pass or positions point at the wrong members.
  into.labelPos = newSeq[int32](nodeSlots + 1)
  for i in 0 .. nodeSlots:
    into.labelPos[i] = -1
  ## `consumed` is a *byte* offset into the slot block, so the source is a
  ## base pointer indexed by byte. Writing `slots[consumed]` instead reads
  ## element number `consumed`, which goes out of bounds as soon as any
  ## record has more than one property.
  var consumed = 0
  if result.slotCount > 0:
    if slots.len != result.slotCount.int:
      raise newException(ValueError, "snapshot: header says " &
        $result.slotCount & " slots, body has " & $slots.len)
    let src = cast[ptr UncheckedArray[uint8]](addr slots[0])
    for i in 1 .. nodeSlots:
      var n = into.nodes[i]
      if n.id == 0 or n.propCount <= 0:
        continue
      let need = n.propCount.int * sizeof(PropSlot)
      let off = into.arena.alloc(need)
      if off <= 0:
        raise newException(ValueError, "snapshot: arena exhausted rebuilding slots")
      let dst = into.arena.ptrAt(off, need)
      if dst == nil:
        raise newException(ValueError, "snapshot: allocated slot block is unreachable")
      copyMem(dst, cast[ptr uint8](addr src[consumed]), need)
      consumed += need
      n.propSlots = off
      n.slotCapacity = uint32(n.propCount)
      into.nodes[i] = n
    for i in 1 .. edgeSlots:
      var e = into.edges[i]
      if e.id == 0 or e.propCount <= 0:
        continue
      let need = e.propCount.int * sizeof(PropSlot)
      let off = into.arena.alloc(need)
      if off <= 0:
        raise newException(ValueError, "snapshot: arena exhausted rebuilding slots")
      let dst = into.arena.ptrAt(off, need)
      if dst == nil:
        raise newException(ValueError, "snapshot: allocated slot block is unreachable")
      copyMem(dst, cast[ptr uint8](addr src[consumed]), need)
      consumed += need
      e.props = off
      e.slotCapacity = uint32(e.propCount)
      into.edges[i] = e
  else:
    for i in 1 .. nodeSlots:
      if into.nodes[i].id != 0 and into.nodes[i].propCount > 0:
        raise newException(ValueError, "snapshot: node " & $i &
          " has properties but the header claims no slot block")
    for i in 1 .. edgeSlots:
      if into.edges[i].id != 0 and into.edges[i].propCount > 0:
        raise newException(ValueError, "snapshot: edge " & $i &
          " has properties but the header claims no slot block")

  if consumed != result.slotCount.int * sizeof(PropSlot):
    raise newException(ValueError, "snapshot: consumed " & $consumed &
      " bytes of slots, header says " &
      $(result.slotCount.int * sizeof(PropSlot)))

  # Label member lists. `labelIndex.members` is indexed by *label slot*
  # while `labelPos` is indexed by *node id* — two different index spaces,
  # and conflating them was exactly this loop's first bug.
  into.labelIndex.members = newSeq[seq[int64]]()
  for labelIdx in 0 ..< result.labelCount.int:
    if at + 8 > buf.len:
      raise newException(ValueError, "snapshot: truncated label section")
    let n = getU64(buf, at).int
    at += 8
    if n < 0 or at + n * 8 > buf.len:
      raise newException(ValueError, "snapshot: label list runs past end")
    into.labelIndex.members.add @[]
    for _ in 0 ..< n:
      let id = cast[int64](getU64(buf, at))
      at += 8
      if id <= 0 or id.int > nodeSlots:
        raise newException(ValueError,
          "snapshot: label member " & $id & " is out of the node table")
      if into.nodes[id.int].id != id:
        raise newException(ValueError,
          "snapshot: label member " & $id & " does not name a live node")
      into.labelIndex.members[labelIdx].add id
      into.labelPos[id.int] = int32(into.labelIndex.members[labelIdx].len - 1)
  # Cross-check the list against the records: a node whose label does not
  # match the list it appears in would remove the wrong member on delete.
  for labelIdx in 0 ..< into.labelIndex.members.len:
    let code = int32(labelIdx + 1)
    for id in into.labelIndex.members[labelIdx]:
      if into.nodes[id.int].label != code:
        raise newException(ValueError,
          "snapshot: node " & $id & " is listed under label " & $code &
          " but its record says " & $into.nodes[id.int].label)

  # `labelPos` is rebuilt above from the member lists rather than read
  # back — the list is the authority, and trusting the position array
  # would mean trusting a second copy of the same fact. It is still in
  # the file, so its bytes have to be stepped over.
  at += (nodeSlots + 1) * 4
  if at > buf.len:
    raise newException(ValueError, "snapshot: truncated labelPos section")

  # Allocator state. Without these the reopen renumbers from 1.
  for i in 1 .. nodeSlots:
    if into.nodes[i].id != 0 and into.nodes[i].id != int64(i):
      raise newException(ValueError, "snapshot: node id " & $into.nodes[i].id &
        " at slot " & $i)
  into.nodeIds.next = int64(result.nextNodeId)
  into.edgeIds.next = int64(result.nextEdgeId)
  if at + 8 > buf.len:
    raise newException(ValueError, "snapshot: truncated allocator section")
  let nfree = getU64(buf, at).int
  at += 8
  for _ in 0 ..< nfree:
    if at + 8 > buf.len:
      raise newException(ValueError, "snapshot: truncated node free list")
    into.nodeIds.free.add cast[int64](getU64(buf, at))
    at += 8
  if at + 8 > buf.len:
    raise newException(ValueError, "snapshot: truncated allocator section")
  let efree = getU64(buf, at).int
  at += 8
  for _ in 0 ..< efree:
    if at + 8 > buf.len:
      raise newException(ValueError, "snapshot: truncated edge free list")
    into.edgeIds.free.add cast[int64](getU64(buf, at))
    at += 8

  into.generation = result.generation
  ## A snapshot puts the store at the snapshot's LSN. S3's catch-up replays
  ## from here, so it must be set on this path too, not only when a
  ## transaction commits (txn.nim) — otherwise a store that was rebuilt from
  ## a snapshot rather than a commit would claim to have applied nothing and
  ## would replay the whole log on top of state it already holds.
  into.lastLsn = result.lsn

# ----------------------------------------------------------------- replay

proc applyFrame(s: GraphStore, f: Frame): bool =
  ## Applies one committed frame directly to the store. Replay is *not*
  ## routed through WriteTransaction: the log already contains the
  ## validated decision, so re-deriving it would only be a second chance
  ## to disagree with itself.
  let p = f.payload
  proc i64At(at: int): int64 = cast[int64](readU64(p, at))
  proc i32At(at: int): int32 = cast[int32](readU32(p, at))

  case f.op
  of opNewLabel:
    discard s.labels.intern(p[4 ..< p.len])
  of opNewRelType:
    discard s.relTypes.intern(p[4 ..< p.len])
  of opNewPropKey:
    discard s.propKeys.intern(p[4 ..< p.len])
  of opCreateNode:
    let id = i64At(0)
    let code = i32At(8)
    if s.nodes.len <= id.int:
      s.nodes.setLen(max(id.int + 1, s.nodes.len * 2))
      s.labelPos.setLen(s.nodes.len)
    s.nodes[id.int] = newNode(id, code)
    s.attachToLabel(id, code)
  of opDeleteNode:
    let id = i64At(0)
    if s.nodes.len > id.int and s.nodes[id.int].id != 0 and s.nodes[id.int].live:
      s.detachFromLabel(id, s.nodes[id.int].label)
      var n = s.nodes[id.int]
      n.setFlag nfTombstone
      n.propCount = 0
      n.propSlots = 0
      n.slotCapacity = 0
      s.nodes[id.int] = n
  of opCreateEdge:
    let id = i64At(0)
    let code = i32At(8)
    let src = i64At(12)
    let dst = i64At(20)
    if s.edges.len <= id.int:
      s.edges.setLen(max(id.int + 1, s.edges.len * 2))
    if s.nodes.len <= max(src, dst).int:
      raise newException(ValueError, "replay: edge " & $id & " references a node the log never created")
    ## Bounds alone are not enough: a crafted id can name a padding slot
    ## (id 0) or a tombstone, and either would attach a live edge to a node
    ## that cannot own it. A frame the log itself wrote always names a live
    ## node — commit validation rejected anything else — so this costs a
    ## healthy replay nothing.
    if s.nodes[src.int].id != src or not s.nodes[src.int].live:
      raise newException(ValueError, "replay: edge " & $id & " references a dead or empty source node")
    if s.nodes[dst.int].id != dst or not s.nodes[dst.int].live:
      raise newException(ValueError, "replay: edge " & $id & " references a dead or empty destination node")
    var e = newEdge(id, src, dst, code)
    e.nextOut = s.nodes[src.int].outHead
    e.nextIn = s.nodes[dst.int].inHead
    s.edges[id.int] = e
    s.nodes[src.int].outHead = id
    s.nodes[src.int].outCount += 1
    s.nodes[dst.int].inHead = id
    s.nodes[dst.int].inCount += 1
  of opDeleteEdge:
    let id = i64At(0)
    if s.edges.len > id.int and s.edges[id.int].id != 0 and s.edges[id.int].live:
      var e = s.edges[id.int]
      s.unlinkEdge e
      e.setFlag efTombstone
      s.edges[id.int] = e
  of opSetProp:
    let isNode = p[0] == '\x00'
    let id = i64At(1)
    let code = i32At(9)
    let vtype = GlyType(byte(p[13]))
    let aux = getU16(p, 14)
    let inline = p[16] == char(SlotInline)
    if isNode:
      if s.nodes.len <= id.int:
        raise newException(ValueError, "replay: SetProp on a node the log never created")
      var n = s.nodes[id.int]
      var pv = n.propView
      var v: Value
      if inline:
        var slot = PropSlot(key: code, vtype: vtype, aux: aux,
                            sflags: SlotInline, payload: readU64(p, 17))
        v = decodeInlineValue(slot)
      else:
        v = decodeValue(p[17 ..< p.len])
      discard s.arena.setProp(pv, code, v)
      n.setPropView pv
      s.nodes[id.int] = n
    else:
      if s.edges.len <= id.int:
        raise newException(ValueError, "replay: SetProp on an edge the log never created")
      var e = s.edges[id.int]
      var pv = e.propView
      var v: Value
      if inline:
        var slot = PropSlot(key: code, vtype: vtype, aux: aux,
                            sflags: SlotInline, payload: readU64(p, 17))
        v = decodeInlineValue(slot)
      else:
        v = decodeValue(p[17 ..< p.len])
      discard s.arena.setProp(pv, code, v)
      e.setPropView pv
      s.edges[id.int] = e
  of opRemoveProp:
    ## M5.2's REMOVE. Same frame layout as SetProp minus the value: target
    ## byte, id, key code. Replay *removes* rather than writing a null — the
    ## two are different states, and a log that turned one into the other
    ## would resurrect every removed property as a stored null.
    let isNode = p[0] == '\x00'
    let id = i64At(1)
    let code = i32At(9)
    if isNode:
      if s.nodes.len <= id.int:
        raise newException(ValueError, "replay: RemoveProp on a node the log never created")
      var n = s.nodes[id.int]
      var pv = n.propView
      discard s.arena.removeProp(pv, code)
      n.setPropView pv
      s.nodes[id.int] = n
    else:
      if s.edges.len <= id.int:
        raise newException(ValueError, "replay: RemoveProp on an edge the log never created")
      var e = s.edges[id.int]
      var pv = e.propView
      discard s.arena.removeProp(pv, code)
      e.setPropView pv
      s.edges[id.int] = e
  of opNoop:
    discard
  else:
    raise newException(ValueError, "replay: unknown opcode " & $f.op)
  true

proc logContinuesPast(walBytes: string, at: int): bool =
  ## Is this really the tail, or does the log keep going?
  ##
  ## A crash between the header write and the payload write leaves a
  ## complete header whose declared payload runs past EOF, and dropping it
  ## is right — that frame genuinely never finished. A flipped `payloadLen`
  ## byte looks identical, and reading it as a tail is how a one-bit
  ## change opened a database with the tail of the log missing and no
  ## error anywhere.
  ##
  ## The two are told apart by what follows. A torn tail is at the *end*:
  ## whatever bytes remain are a partial frame at most, and nothing after
  ## them decodes. Damage leaves a substantial body behind it — the rest of
  ## the log, whose bytes are plainly there. So: if fewer than a full
  ## frame header remains, or the next frame header does not decode, it is
  ## the tail (or a cascade from it); if a valid frame follows, the log did
  ## not stop here and the length field is a lie.
  let next = at + FrameHeaderSize
  if next >= walBytes.len:
    return false
  # Fewer than a header's worth of bytes left cannot hold a next frame:
  # this is the tail, partial or not.
  if walBytes.len - next < FrameHeaderSize:
    return false
  # Scan the rest of the log, not just the next frame: a flipped length
  # swallows the bytes that *would* have been the next frame (they are the
  # overrun's payload), so the byte right after the header is not a frame.
  # What proves the log continues is that *somewhere* ahead there is still
  # a frame whose CRC is good — and if the whole tail is present, there is.
  var scan = next
  while scan + FrameHeaderSize <= walBytes.len:
    let d = decodeFrame(walBytes, scan, walBytes.len)
    if d.consumed > 0 and not d.corrupt and not d.overrun:
      return true
    scan += 1
  return false

proc replay*(s: GraphStore, walBytes: string,
             fromLsn: uint64): Recovery =
  ## Replay into a store, transaction by transaction. A transaction is
  ## merged only when its COMMIT frame is seen.
  var pending = newSeq[Frame]()
  var pendingTxn = 0'u32
  var at = 0
  var lastLsn = fromLsn
  ## The highest id the log ever issued, per allocator. Replay must
  ## advance the stores past these or the next open would renumber from 1
  ## on top of live records — the exact failure WAL.md §4.2a warns about.
  var maxNodeId = 0'i64
  var maxEdgeId = 0'i64

  while at < walBytes.len:
    let d = decodeFrame(walBytes, at, walBytes.len)
    if d.consumed == 0:
      # A CRC mismatch is not a torn tail. A torn tail is a frame that was
      # never finished — a crash mid-write — and dropping it is the correct
      # recovery. Damage is a *finished* frame whose content does not match
      # its checksum: dropping the rest of the log for it loses every
      # transaction after the damage with no error anywhere, and truncating
      # the file destroys the evidence. Refuse the open and leave the file
      # exactly as found (WAL.md W3).
      if d.corrupt:
        fail(glyErrCorrupt,
             "wal: " & d.reason & " at byte " & $at &
             " — the log is damaged; the file has been left untouched")
      if d.overrun and logContinuesPast(walBytes, at):
        ## A complete header whose payload length runs past the end of the
        ## log is ambiguous on its own: a crash between the header write
        ## and the payload write looks exactly like this, and dropping it is
        ## right. It stops being ambiguous the moment another *valid* frame
        ## sits behind it — the log did not stop here, so nothing truncated
        ## this frame, so its length field is a lie. Reading it as a torn
        ## tail is how a flipped byte in `payloadLen` opened a database
        ## with the tail of the log missing and no error anywhere.
        fail(glyErrCorrupt,
             "wal: " & d.reason & " at byte " & $at &
             " — the frame length does not fit and the log continues " &
             "behind it; the file has been left untouched")
      result.tornTail = true
      result.tornReason = d.reason
      break
    at += d.consumed
    result.validBytes = int64(at)

    let f = d.frame
    ## `fromLsn` is the last frame the snapshot already contains. Replaying
    ## from byte 0 instead re-applies the whole log on top of state that
    ## has it: create ids collide with live records, and the first array
    ## that is not grown before the write goes out of bounds. Skipping
    ## these *before* the pending-group bookkeeping matters too — letting
    ## them into the group would make the first post-checkpoint
    ## transaction look like it merged with a pre-checkpoint one.
    ## `fromLsn == 0` means "no snapshot": the whole log has to be
    ## replayed. Guarding on it explicitly matters because LSN 0 is not a
    ## real LSN — `openWal` starts at 1 — so an unguarded `lsn <= fromLsn`
    ## silently dropped the very first transaction of a log that had no
    ## snapshot to replay from.
    if fromLsn > 0 and f.lsn <= fromLsn:
      continue

    lastLsn = f.lsn
    inc result.framesReplayed

    if f.txnId != pendingTxn and pendingTxn != 0'u32:
      # One transaction's frames ran into the next without a commit
      # between: the earlier one never committed, so discard it whole.
      inc result.transactionsDiscarded
      pending.setLen(0)
    pendingTxn = f.txnId

    if (f.txnFlags and TxnCommit) != 0'u32:
      for pf in pending:
        if pf.op == opCreateNode and pf.payload.len >= 8:
          maxNodeId = max(maxNodeId, cast[int64](readU64(pf.payload, 0)))
        elif pf.op == opCreateEdge and pf.payload.len >= 8:
          maxEdgeId = max(maxEdgeId, cast[int64](readU64(pf.payload, 0)))
        discard applyFrame(s, pf)
      pending.setLen(0)
      # Clear the group marker with the group. Leaving it set makes the
      # *next* transaction look like it ran into this one without a
      # commit, so every clean transaction boundary after the first was
      # counted as a discarded transaction.
      pendingTxn = 0'u32
      inc result.transactionsCommitted
      s.generation += 1
    elif (f.txnFlags and TxnRollback) != 0'u32:
      pending.setLen(0)
      pendingTxn = 0'u32
      inc result.transactionsDiscarded
    else:
      pending.add f

  if pending.len > 0:
    # Frames with no commit at the end: the process died between the last
    # mutation and its commit marker. Discard whole — this is the ordinary
    # `kill -9` case, not an error.
    inc result.transactionsDiscarded

  s.nodeIds.advancePast(maxNodeId)
  s.edgeIds.advancePast(maxEdgeId)
  result.replayedUpToLsn = lastLsn
  ## The store now holds everything up to `lastLsn`. S3's catch-up replays
  ## from this field, so it has to reflect the replay and not just the
  ## snapshot — otherwise a store rebuilt by recovery would claim to be at
  ## the snapshot's LSN and re-apply every frame since, which W9's skip rule
  ## makes *safe* but not free.
  s.lastLsn = lastLsn

proc recover*(graphPath: string, into: GraphStore): Recovery =
  ## The whole of WAL.md §5, in order. Returns what it did so that
  ## `integrity_check` and the crash harness can report on it.
  ##
  ## Refuses a store that already holds records. Replay is exactly-once
  ## per store: running it again over a populated store would apply the
  ## same frames twice, and a silent double-apply is far worse than a loud
  ## refusal because it looks like success.
  if into.nodeCount() != 0 or into.edgeCount() != 0 or
     into.nodes.len != 1 or into.edges.len != 1:
    raise newException(ValueError,
      "recover: store already holds records; replay is exactly-once per store")
  var snapshotLsn = 0'u64
  if fileExists(graphPath):
    let bytes = readFile(graphPath)
    snapshotLsn = loadSnapshot(bytes, into).lsn
    result.snapshotFound = true
    result.snapshotLsn = snapshotLsn
    result.snapshotGeneration = into.generation

  let walPath = graphPath & "-wal"
  if not fileExists(walPath):
    return

  let walBytes = readFile(walPath)
  let replayed = replay(into, walBytes, snapshotLsn)
  # Preserve the snapshot facts `replay` does not know about; assigning
  # its whole result over this one is how they get lost. `snapshotFound`
  # keeps whatever the branch above set: true only when a snapshot file
  # was actually read, not merely because a log was replayed.
  result.snapshotLsn = snapshotLsn
  result.snapshotGeneration = into.generation
  result.walBytesScanned = int64(walBytes.len)
  result.framesReplayed = replayed.framesReplayed
  result.transactionsCommitted = replayed.transactionsCommitted
  result.transactionsDiscarded = replayed.transactionsDiscarded
  result.tornTail = replayed.tornTail
  result.tornReason = replayed.tornReason
  result.corruptReason = replayed.corruptReason
  result.validBytes = replayed.validBytes
  result.replayedUpToLsn = replayed.replayedUpToLsn

  # Truncate the torn tail. A tail left in place is re-examined on every
  # open and keeps producing the same warning, and it would be re-parsed
  # by the next replay.
  if result.tornTail and result.validBytes < int64(walBytes.len):
    ## `fmReadWriteExisting`, not `fmWrite` or `fmReadWrite`: Nim's
    ## fmWrite is C "w" and fmReadWrite is C "w+", and both truncate on
    ## open, so the "keep the valid prefix" step was replacing the log
    ## with zeros of the right length — recovery then read a log of
    ## zeros, refused the first frame on CRC, and truncated the file to
    ## nothing. r+ ("r+") is the one mode that opens an existing file in
    ## place.
    let f = open(walPath, fmReadWriteExisting)
    if posix.ftruncate(f.getFileHandle, posix.Off(result.validBytes)) != 0:
      f.close()
      raise newException(IOError,
                         "recovery: tail truncate failed: " & osErrorMsg(osLastError()))
    f.close()
