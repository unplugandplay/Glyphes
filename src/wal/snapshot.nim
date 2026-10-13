## glyphes — the snapshot file (WAL.md §4)
##
## One file, written at checkpoint, replacing the old one, and `mmap`ed
## read-only on open. This is the property that makes Phase A's claim
## true: after recovery, everything is in one file and nothing is lost.
##
## ##1 Every field here was added because a store field demanded it
##
## M1 invented two pieces of state the format originally did not mention,
## and both are mandatory rather than optional (WAL.md §4.2a):
##
##   * **Id allocator high-water marks.** Omit them and a reopen starts
##     at id 1 and hands out ids live records already hold.
##   * **`labelPos`.** Omit it and every label membership position reads as
##     -1, so the next delete removes an arbitrary member.
##
## The third, allocated-slot counts, is not correctness but size: the
## arrays double as they grow, so a reopened store has trailing zeroed
## slots and a reader needs to know where the padding ends.
##
## ##2 Zero-copy was deferred, and that is a deviation
##
## WAL.md §4.1 specifies an mmap read path with no copy. This
## implementation mmaps the file, validates the header and trailer CRC
## *against the mapped bytes*, and then copies the sections into the
## store's arrays. So the mapping is real and the corruption check is
## done on the mapped bytes rather than on a copy that could not have
## been corrupted in transit — but the records themselves are copied.
##
## The reason is structural: `seq[NodeRec]` cannot alias foreign memory,
## and giving it a zero-copy path means either a second store type or
## unsafe pointer discipline in every record access. `STORAGE.md` S11
## already forbids holding pointers into the record arrays, so the
## pointer discipline is decided; it is *worse* to reintroduce it in one
## place to save one memcpy. Recorded as a phase-2 item rather than
## quietly omitted.

when defined(posix):
  import posix
import std/os
import std/strutils
import ./crc32
import ../store/store

const
  SnapshotMagic* = "GLYPHSN1"
  SnapshotFormatVersion* = 1'u32
  SnapshotHeaderSize* = 160

type
  SnapshotHeader* = object
    lsn*: uint64
    nodeCount*: uint64        ## allocated slots, tombstones and padding included
    edgeCount*: uint64
    slotCount*: uint64
    arenaBytes*: uint64
    labelCount*: uint64
    relTypeCount*: uint64
    propKeyCount*: uint64
    indexCount*: uint64
    generation*: uint64
    nextNodeId*: uint64
    nextEdgeId*: uint64
    liveNodeCount*: uint64
    liveEdgeCount*: uint64

proc putU16*(buf: var string, v: uint16) =
  buf.add char(uint8(v and 0xFF'u16))
  buf.add char(uint8((v shr 8) and 0xFF'u16))

proc putU32*(buf: var string, v: uint32) =
  for i in 0 ..< 4:
    buf.add char(uint8((v shr (i * 8)) and 0xFF'u32))

proc putU64*(buf: var string, v: uint64) =
  for i in 0 ..< 8:
    buf.add char(uint8((v shr (i * 8)) and 0xFF'u64))

proc getU16*(b: string, at: int): uint16 =
  uint16(byte(b[at])) or (uint16(byte(b[at + 1])) shl 8)

proc getU32*(b: string, at: int): uint32 =
  result = 0
  for i in 0 ..< 4:
    result = result or (uint32(byte(b[at + i])) shl (i * 8))

proc getU64*(b: string, at: int): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = result or (uint64(byte(b[at + i])) shl (i * 8))

# ------------------------------------------------------------------ writer

proc encodeSnapshot*(s: GraphStore, lsn: uint64 = 0): string =
  ## The whole file as one string. Written with a single `write` so the
  ## file is either entirely there or entirely absent — a snapshot that
  ## is half-written is worse than no snapshot, because the old one has
  ## already been replaced by then.
  var body = newStringOfCap(1 shl 20)

  # Dictionaries. Codes are implicit by position (STORAGE.md §4), which
  # is only safe because they are append-only.
  for code in 1 ..< s.labels.codes.len:
    body.add s.labels.codes[code]
    body.add '\0'
  for code in 1 ..< s.relTypes.codes.len:
    body.add s.relTypes.codes[code]
    body.add '\0'
  for code in 1 ..< s.propKeys.codes.len:
    body.add s.propKeys.codes[code]
    body.add '\0'

  # Records, in id order. `nodes[i].id == i` is the invariant, so the
  # array order *is* id order and nothing has to be sorted. The record
  # bytes below carry the ids already; a separate id section would be a
  # second source of truth that the reader has no way to check.
  ## Both record kinds contribute: the copy loop below packs nodes *then*
  ## edges into one block, so the header count has to be the sum over the
  ## same two populations or the reader walks off the end.
  var totalSlots = 0
  for i in 1 ..< s.nodes.len:
    totalSlots += int(s.nodes[i].propCount)
  for i in 1 ..< s.edges.len:
    totalSlots += int(s.edges[i].propCount)

  # The record bytes, memcpy'd. A per-field serializer would be more
  # portable and would also be a second place for a layout bug; the
  # records are POD by construction (STORAGE.md §1.5) and the tests
  # assert sizeof/offsetOf against the spec.
  ## Slot 0 is the padding slot, not a record. Sizing these buffers by
  ## `s.nodes.len` writes 48 bytes of zeros that no reader is expecting,
  ## which shifts the edge, slot and arena sections by exactly one record.
  var nodeBytes = newString((s.nodes.len - 1) * sizeof(NodeRec))
  if s.nodes.len > 1:
    copyMem(addr nodeBytes[0], unsafeAddr s.nodes[1], (s.nodes.len - 1) * sizeof(NodeRec))
  body.add nodeBytes
  var edgeBytes = newString((s.edges.len - 1) * sizeof(EdgeRec))
  if s.edges.len > 1:
    copyMem(addr edgeBytes[0], unsafeAddr s.edges[1], (s.edges.len - 1) * sizeof(EdgeRec))
  body.add edgeBytes

  ## `written` counts bytes, and `slotBytes` is a byte string, so the
  ## destination has to be a byte-offset pointer. Indexing it as
  ## `slotBytes[written]` treats the offset as a character index and runs
  ## off the end at exactly one record past the last.
  var slotBytes = newString(totalSlots * sizeof(PropSlot))
  var written = 0
  if written < slotBytes.len:
    let dst = cast[ptr UncheckedArray[uint8]](addr slotBytes[0])
    for i in 1 ..< s.nodes.len:
      let n = s.nodes[i]
      if n.propSlots != 0 and n.propCount > 0:
        let src = s.arena.ptrAt(n.propSlots, n.propCount.int * sizeof(PropSlot))
        if src != nil:
          copyMem(addr dst[written], src, n.propCount.int * sizeof(PropSlot))
          written += n.propCount.int * sizeof(PropSlot)
    for i in 1 ..< s.edges.len:
      let e = s.edges[i]
      if e.props != 0 and e.propCount > 0:
        let src = s.arena.ptrAt(e.props, e.propCount.int * sizeof(PropSlot))
        if src != nil:
          copyMem(addr dst[written], src, e.propCount.int * sizeof(PropSlot))
          written += e.propCount.int * sizeof(PropSlot)
  if written != slotBytes.len:
    raise newException(ValueError,
      "snapshot: wrote " & $written & " bytes of slots, header claims " &
      $(totalSlots * sizeof(PropSlot)))
  body.add slotBytes

  # Arena, verbatim from offset 0 so the first 8 bytes — the hole that
  # makes 0 mean "none" — come along and every offset still resolves.
  ##
  ## Capped at the bytes that actually exist. A fresh arena reports
  ## `bump == ArenaFirstOffset` while its backing seq still has length 0 —
  ## `initArena` uses `newSeqOfCap`, which reserves capacity without
  ## setting the length — so `bump > 0` alone indexed an empty container
  ## and no store that had never allocated arena space could be
  ## snapshotted at all. Writing zero bytes there is also the correct
  ## content: the loader rebuilds the same hole-and-offset shape from an
  ## empty section.
  let arenaLen = min(s.arena.bump, s.arena.bytes.len)
  var arenaBytes = newString(arenaLen)
  if arenaLen > 0:
    copyMem(addr arenaBytes[0], unsafeAddr s.arena.bytes[0], arenaLen)
  body.add arenaBytes

  # Label member lists.
  for slot in 0 ..< s.labelIndex.members.len:
    let m = s.labelIndex.members[slot]
    putU64(body, uint64(m.len))
    for id in m:
      putU64(body, cast[uint64](id))

  # labelPos, one i32 per node slot, and the free-id lists.
  var posBytes = newString(s.labelPos.len * 4)
  if s.labelPos.len > 0:
    copyMem(addr posBytes[0], unsafeAddr s.labelPos[0], s.labelPos.len * 4)
  body.add posBytes
  putU64(body, uint64(s.nodeIds.free.len))
  for id in s.nodeIds.free:
    putU64(body, cast[uint64](id))
  putU64(body, uint64(s.edgeIds.free.len))
  for id in s.edgeIds.free:
    putU64(body, cast[uint64](id))

  let live = s.nodeCount()
  let liveEdges = s.edgeCount()
  let header = SnapshotHeader(
    lsn: lsn,
    nodeCount: uint64(s.nodes.len - 1),
    edgeCount: uint64(s.edges.len - 1),
    slotCount: uint64(totalSlots),
    arenaBytes: uint64(arenaLen),
    labelCount: uint64(s.labels.codes.len - 1),
    relTypeCount: uint64(s.relTypes.codes.len - 1),
    propKeyCount: uint64(s.propKeys.codes.len - 1),
    indexCount: 0,
    generation: s.generation,
    nextNodeId: uint64(s.nodeIds.next),
    nextEdgeId: uint64(s.edgeIds.next),
    liveNodeCount: uint64(live),
    liveEdgeCount: uint64(liveEdges))

  var head = newStringOfCap(SnapshotHeaderSize)
  for ch in SnapshotMagic: head.add ch
  putU32(head, SnapshotFormatVersion)
  putU32(head, 0)                     # header_crc placeholder
  putU64(head, header.lsn)
  putU64(head, header.nodeCount)
  putU64(head, header.edgeCount)
  putU64(head, header.slotCount)
  putU64(head, header.arenaBytes)
  putU64(head, header.labelCount)
  putU64(head, header.relTypeCount)
  putU64(head, header.propKeyCount)
  putU64(head, header.indexCount)
  putU64(head, header.generation)
  putU64(head, header.nextNodeId)
  putU64(head, header.nextEdgeId)
  putU64(head, header.liveNodeCount)
  putU64(head, header.liveEdgeCount)
  while head.len < SnapshotHeaderSize:
    head.add '\0'
  assert head.len == SnapshotHeaderSize

  let headerCrc = crc32(head[0 ..< 12])
  head[12] = char(headerCrc and 0xFF'u32)
  head[13] = char((headerCrc shr 8) and 0xFF'u32)
  head[14] = char((headerCrc shr 16) and 0xFF'u32)
  head[15] = char((headerCrc shr 24) and 0xFF'u32)

  # The trailer CRC covers the header from offset 16 onward plus the body.
  # header_crc alone only covers the magic and the version, so without this
  # the allocator high-water marks could be edited without detection —
  # which is the specific corruption that renumbers a reopened database on
  # top of live ids.
  var trailer = newStringOfCap(12)
  var bodyCrc = crc32(head[16 ..< head.len])
  bodyCrc = crc32(body, bodyCrc)
  putU32(trailer, bodyCrc)
  for ch in SnapshotMagic: trailer.add ch

  result = head & body & trailer

proc writeSnapshot*(s: GraphStore, path: string; lsn: uint64) =
  ## Write to a temporary and rename. A crash mid-write leaves the old
  ## snapshot intact; a crash after the rename leaves the new one. There
  ## is no third outcome, which is the only reason this is safe.
  ##
  ## The lsn travels *into* the file rather than only alongside it: it is
  ## what tells recovery where the WAL replay starts, and a snapshot that
  ## recorded lsn 0 would make every pre-checkpoint frame replay again on
  ## top of state that already contains it.
  let tmp = path & ".tmp"
  var f = open(tmp, fmWrite)
  let bytes = encodeSnapshot(s, lsn)
  f.write(bytes)
  f.flushFile()
  when defined(posix):
    discard posix.fdatasync(f.getFileHandle)
  f.close()
  moveFile(tmp, path)
  ## fsync the *directory* as well as the file. Without it the rename may
  ## not survive a crash even though the data does, which is the one case
  ## where the atomic-replace dance silently does nothing.
  when defined(posix):
    let dir = parentDir(path)
    if dir.len > 0 and dir != ".":
      let dfd = posix.open(dir.cstring, O_RDONLY)
      if dfd >= 0:
        discard posix.fsync(dfd)
        discard posix.close(dfd)
