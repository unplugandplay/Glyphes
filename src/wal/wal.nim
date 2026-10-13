## glyphes — the write-ahead log (WAL.md §2)
##
## Append-only frames, never rewritten in place. The whole point of this
## file is that a process killed at any instruction leaves a prefix of
## valid frames followed by at most one torn one, and recovery can tell
## the two apart.
##
## Three decisions in here are load-bearing and were all paid for:
##
##   * **One write() per frame.** Frames from a single transaction may be
##     batched into one write when the buffer is large; frames from
##     different transactions are never batched. Batching across
##     transactions would make a partial write land mid-transaction and
##     turn a torn tail into a torn *commit*.
##
##   * **Per-frame CRC over the header and the payload.** Not a whole-log
##     checksum: one bad frame must not invalidate the ones before it.
##
##   * **A bump allocator cannot validate its own contents.** Every
##     variable-length value this log carries is length-prefixed, because
##     replay has no other way to know where a payload ends. That was M1's
##     first bug and it is why the rule is written down here rather than
##     left to whoever adds the next opcode.

when defined(posix):
  import posix
elif defined(windows):
  import winlean
import std/os
import std/strutils
import ./crc32

type
  Opcode* = uint32
    ## WAL.md §3. The ordinals are the format; never renumber.

const
  ## A frame with no operation. Used only for COMMIT and ROLLBACK
  ## markers, which are real frames in the log — so that a transaction
  ## without a COMMIT frame is detectable — but carry no mutation. WAL.md
  ## §3 originally implied a commit marker by flagging some other
  ## opcode's frame, which replay would then try to execute.
  opNoop*        = Opcode(0)
  opCreateNode*  = Opcode(1)
  opDeleteNode*  = Opcode(2)
  opAddLabel*    = Opcode(3)
  opRemoveLabel* = Opcode(4)
  opCreateEdge*  = Opcode(5)
  opDeleteEdge*  = Opcode(6)
  opSetProp*     = Opcode(7)
  opRemoveProp*  = Opcode(8)
  opCreateIndex* = Opcode(9)
  opDropIndex*   = Opcode(10)
  opNewLabel*    = Opcode(11)
  opNewRelType*  = Opcode(12)
  opNewPropKey*  = Opcode(13)

type
  OpcodeName* = object
    op*: Opcode
    name*: string

const OpcodeNames* = [
    OpcodeName(op: opCreateNode,  name: "CreateNode"),
    OpcodeName(op: opDeleteNode,  name: "DeleteNode"),
    OpcodeName(op: opAddLabel,    name: "AddLabel"),
    OpcodeName(op: opRemoveLabel, name: "RemoveLabel"),
    OpcodeName(op: opCreateEdge,  name: "CreateEdge"),
    OpcodeName(op: opDeleteEdge,  name: "DeleteEdge"),
    OpcodeName(op: opSetProp,     name: "SetProp"),
    OpcodeName(op: opRemoveProp,  name: "RemoveProp"),
    OpcodeName(op: opCreateIndex, name: "CreateIndex"),
    OpcodeName(op: opDropIndex,   name: "DropIndex"),
    OpcodeName(op: opNewLabel,    name: "NewLabel"),
    OpcodeName(op: opNewRelType,  name: "NewRelType"),
    OpcodeName(op: opNewPropKey,  name: "NewPropKey")
  ]

const
  FrameHeaderSize* = 32
  ## Bytes covered by the CRC *before* the crc32 field: lsn, txnId, op,
  ## payloadLen. See WAL.md §2.
  CrcCoveredHeaderBytes* = 20
  ## Bytes covered *after* it: txnFlags and the reserved tail. The first
  ## version covered only the first span and the payload, which left
  ## `txnFlags` unchecked — and txnFlags is where the COMMIT bit lives. A
  ## single flipped bit there turned a committed transaction into an
  ## uncommitted one: the log replayed "cleanly" into a graph holding the
  ## transaction's nodes as if they had committed, with the CRC still
  ## valid. The bit-flip sweep (W3) found it; no unit test had, because
  ## every unit test flipped a byte in the *payload* or the first span,
  ## which is exactly where the CRC was already watching.
  CrcCoveredTailBytes* = 8

  TxnCommit* = 1'u32
  TxnRollback* = 2'u32
  TxnCheckpoint* = 4'u32

type
  Frame* = object
    ## In-memory form. `payload` is length-prefixed inside itself where
    ## the contents are variable-length.
    lsn*: uint64
    txnId*: uint32
    op*: Opcode
    txnFlags*: uint32
    payload*: string

  Wal* = ref object
    ## Append-only. Opened with O_APPEND and never seeked for writing.
    path*: string
    handle: File
    size*: int64
    nextLsn*: uint64
    readOnly*: bool

proc opcodeName(op: Opcode): string =
  for entry in OpcodeNames:
    if entry.op == op:
      return entry.name
  result = "opcode(" & $op & ")"

# ----------------------------------------------------------------- encode

proc writeU16(buf: var string, v: uint16) =
  buf.add char(v and 0xFF'u16)
  buf.add char((v shr 8) and 0xFF'u16)

proc writeU32(buf: var string, v: uint32) =
  for i in 0 ..< 4:
    buf.add char((v shr (i * 8)) and 0xFF'u32)

proc writeU64(buf: var string, v: uint64) =
  for i in 0 ..< 8:
    buf.add char((v shr (i * 8)) and 0xFF'u64)

proc writeI64(buf: var string, v: int64) =
  writeU64(buf, cast[uint64](v))

proc encodeFrame*(f: Frame): string =
  ## Header, then payload, then the CRC field patched in. Building the
  ## whole frame in one buffer is what makes "one write() per frame" a
  ## property of the call site rather than a hope.
  var head = newStringOfCap(FrameHeaderSize)
  writeU64 head, f.lsn
  writeU32 head, f.txnId
  writeU32 head, f.op
  writeU32 head, uint32(f.payload.len)
  writeU32 head, 0'u32                      ## crc32 placeholder
  writeU32 head, f.txnFlags
  writeU32 head, 0'u32                      ## reserved
  assert head.len == FrameHeaderSize

  ## Two calls rather than a concatenated buffer: the non-destructive
  ## seed interface exists precisely so a large payload is not copied just
  ## to be checksummed.
  ##
  ## Seeding the second call with the first's finalized value is exact,
  ## not approximate: finalization XORs with FFFFFFFF and initialization
  ## XORs with it again, so the two cancel and the result equals
  ## crc32(header[0..20] ++ payload). The unit tests check that against a
  ## genuinely concatenated buffer, because this is the sort of thing
  ## that is true until someone changes the constants.
  var crc = crc32(head[0 ..< CrcCoveredHeaderBytes])
  crc = crc32(head[CrcCoveredHeaderBytes + 4 ..< FrameHeaderSize], crc)
  if f.payload.len > 0:
    crc = crc32(f.payload, crc)

  result = head & f.payload
  result[20] = char(crc and 0xFF'u32)
  result[21] = char((crc shr 8) and 0xFF'u32)
  result[22] = char((crc shr 16) and 0xFF'u32)
  result[23] = char((crc shr 24) and 0xFF'u32)

proc readU16(b: string, at: int): uint16 =
  uint16(byte(b[at])) or (uint16(byte(b[at + 1])) shl 8)

proc readU32(b: string, at: int): uint32 =
  result = 0
  for i in 0 ..< 4:
    result = result or (uint32(byte(b[at + i])) shl (i * 8))

proc readU64(b: string, at: int): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = result or (uint64(byte(b[at + i])) shl (i * 8))

type
  DecodeResult* = object
    frame*: Frame
    ## Total bytes consumed, or 0 when the buffer does not hold a complete
    ## frame. 0 is the only failure signal: a torn tail and a truncated
    ## read are the same thing to a recovery loop, and recovery treats
    ## them identically by stopping.
    consumed*: int
    ## Why decoding stopped, for the report `integrity_check` shows.
    reason*: string
    ## The frame was complete but failed its CRC: the file is *damaged*,
    ## not truncated. A torn tail is a frame that was never finished (a
    ## crash mid-write) and is correct to drop; damage is a finished frame
    ## whose content does not match its checksum, and dropping the rest of
    ## the log for it is silent data loss. `consumed == 0` on both, so a
    ## caller that does not look here cannot tell them apart — which is how
    ## a corrupted log came to open "successfully" with every transaction
    ## after the damage missing and the damaged bytes truncated away.
    corrupt*: bool
    ## The header is complete but its declared payload runs past the end of
    ## the readable bytes. This is the one genuinely *ambiguous* stop: a
    ## crash between writing the header and writing the payload looks
    ## exactly like this, and dropping it is correct. A corrupted
    ## `payloadLen` looks exactly the same. `replay` resolves it by looking
    ## at whether the log continues past the frame (see `overrun`).
    overrun*: bool

proc decodeFrame*(buf: string; at: int; limit: int): DecodeResult =
  ## `limit` is the end of readable data, which for a file read is the
  ## file length and for a torn tail is short of a full header.
  result.consumed = 0
  if at + FrameHeaderSize > limit:
    result.reason = "incomplete header"
    return
  let lsn = readU64(buf, at)
  let txnId = readU32(buf, at + 8)
  let op = readU32(buf, at + 12)
  let payloadLen = readU32(buf, at + 16)
  let wantCrc = readU32(buf, at + 20)
  let txnFlags = readU32(buf, at + 24)

  # A payload length that runs past the end of the file is the torn-tail
  # case. Reject before allocating: a corrupt 4 GB length field must not
  # become a 4 GB allocation on the recovery path.
  if payloadLen > uint32(limit - at - FrameHeaderSize):
    result.reason = "payload length " & $payloadLen & " runs past end of log"
    result.overrun = true
    return

  let payloadAt = at + FrameHeaderSize
  let payload = if payloadLen == 0: "" else: buf[payloadAt ..< payloadAt + int(payloadLen)]

  var gotCrc = crc32(buf[at ..< at + CrcCoveredHeaderBytes])
  gotCrc = crc32(buf[at + CrcCoveredHeaderBytes + 4 ..< at + FrameHeaderSize], gotCrc)
  if payloadLen > 0:
    gotCrc = crc32(payload, gotCrc)
  if gotCrc != wantCrc:
    result.reason = "crc mismatch: have " & toHex(wantCrc, 8) &
                    " want " & toHex(gotCrc, 8)
    result.corrupt = true
    return

  result.frame = Frame(lsn: lsn, txnId: txnId, op: op,
                       txnFlags: txnFlags, payload: payload)
  result.consumed = FrameHeaderSize + int(payloadLen)

proc readI64(b: string, at: int): int64 = cast[int64](readU64(b, at))

# ------------------------------------------------------------------- file

proc scanLsn*(path: string): tuple[lsn: uint64, size: int64]

proc openWal*(path: string; readOnly = false): Wal =
  ## Creates the file if absent. The lock lives beside it and is taken by
  ## the caller (`WAL.md` §1); this proc only owns the log's handle.
  new(result)
  result.path = path
  result.readOnly = readOnly
  if readOnly:
    if not fileExists(path):
      raise newException(IOError, "wal: no such file: " & path)
    result.handle = open(path, fmRead)
    result.size = getFileSize(path)
  else:
    ## `fmAppend`, not `fmWrite`: Nim's fmWrite is C "wb" and destroys
    ## the file it opens. Every earlier caller only ever opened a log it
    ## had just created, so the destruction was invisible until a test
    ## reopened one. fmAppend is the kernel's O_APPEND — every write
    ## lands at end-of-file, so a concurrent writer cannot interleave
    ## into the middle of a frame — and it creates the file if absent.
    let scanned = scanLsn(path)
    result.handle = open(path, fmAppend)
    ## Resume, do not restart. An LSN that reset to 1 on every open would
    ## hand the same LSN to two different frames; recovery, which skips
    ## everything at or below the snapshot's LSN, would then silently
    ## drop the reopened log's frames as if they were already in the
    ## snapshot.
    result.size = scanned.size
    result.nextLsn = scanned.lsn + 1

proc closeWal*(w: Wal) =
  if w.handle != nil:
    w.handle.close()
    w.handle = nil

proc scanLsn*(path: string): tuple[lsn: uint64, size: int64] =
  ## Last valid frame's LSN and the byte length that reached it, read
  ## through a handle opened for reading.
  ##
  ## The handle matters: an append-mode handle is write-only, so reading
  ## the log through the writer's own handle is how this scan once
  ## returned "empty" for a log that had frames in it — and with the LSN
  ## restarting at 1, recovery would then skip the reopened log's frames
  ## as though its snapshot already contained them. Called once at open;
  ## a log that does not fit in memory is read whole anyway, which is a
  ## phase-2 item (WAL.md §1) rather than a correctness one.
  result.lsn = 0
  result.size = 0
  if not fileExists(path):
    return
  var f = open(path, fmRead)
  defer: f.close()
  result.size = getFileSize(f)
  let whole = f.readAll()
  var at = 0
  while at < whole.len:
    let d = decodeFrame(whole, at, whole.len)
    if d.consumed == 0:
      break
    result.lsn = d.frame.lsn
    at += d.consumed

proc highestLsn*(w: Wal): uint64 =
  ## The log's last valid LSN, whatever kind of handle `w` holds.
  scanLsn(w.path).lsn

proc appendFrames*(w: Wal, frames: openArray[Frame]): int {.raises: [IOError].} =
  ## One write() per frame. `batchIfBytes` exists only so a large
  ## transaction does not issue 10^6 syscalls; it must never be set
  ## across a transaction boundary.
  if w.readOnly:
    raise newException(IOError, "wal: append to a read-only log")
  var written = 0
  for f in frames:
    let encoded = encodeFrame(f)
    w.handle.write(encoded)
    inc written
    inc w.size, encoded.len
  written

proc flush*(w: Wal) {.raises: [].} =
  if not w.readOnly:
    w.handle.flushFile()

proc sync*(w: Wal) {.raises: [].} =
  ## fdatasync: the durability point. Not `close`, because closing is not
  ## something a database does at every commit, and not `flushFile`,
  ## because that only reaches the OS.
  if w.readOnly:
    return
  w.handle.flushFile()
  when defined(posix):
    ## Nim's `File` exposes the underlying file descriptor directly as
    ## `getFileHandle`; there is no `fileno` to go through. fdatasync is
    ## the right call rather than fsync: it flushes data without the
    ## metadata cost, and for an append-only log whose length is not
    ## load-bearing metadata, that is the whole durability point.
    discard posix.fdatasync(w.handle.getFileHandle)

proc truncateTo*(w: Wal, offset: int64) {.raises: [IOError].} =
  ## Cut a torn tail. Used only by recovery, and only to a position the
  ## scanner has already validated as frame-aligned.
  if w.readOnly:
    raise newException(IOError, "wal: truncate of a read-only log")
  ## truncate(2) through the descriptor: Nim's `File` has no truncate, and
  ## going through `setFilePos` + a reopen would leave a window where the
  ## file is longer than the last valid frame.
  discard posix.ftruncate(w.handle.getFileHandle, posix.Off(offset))
  w.size = offset

proc readAll*(w: Wal): string =
  if w.readOnly or w.size == 0:
    return ""
  w.handle.setFilePos(0, fspSet)
  result = w.handle.readAll()[0 ..< w.size.int]

proc frames*(buf: string): seq[Frame] =
  ## Whole-log scan. Every valid frame, in order. Stops at the first
  ## invalid one, which is the torn tail by definition.
  var at = 0
  while at < buf.len:
    let d = decodeFrame(buf, at, buf.len)
    if d.consumed == 0:
      break
    result.add d.frame
    at += d.consumed

proc scanReport*(buf: string): tuple[frames: int, validBytes: int, reason: string,
                                     corrupt: bool] =
  ## For `integrity_check` and for the crash harness: how far the log is
  ## good, and why it stops.
  var at = 0
  result.validBytes = 0
  result.reason = "clean"
  result.corrupt = false
  while at < buf.len:
    let d = decodeFrame(buf, at, buf.len)
    if d.consumed == 0:
      result.reason = d.reason
      result.corrupt = d.corrupt
      return
    inc result.frames
    at += d.consumed
    result.validBytes = at

proc describe*(f: Frame): string =
  "lsn " & $f.lsn & " txn " & $f.txnId & " " & opcodeName(f.op) &
    " payload " & $f.payload.len & "B" &
    (if (f.txnFlags and TxnCommit) != 0'u32: " COMMIT"
     elif (f.txnFlags and TxnRollback) != 0'u32: " ROLLBACK"
     else: "")

export crc32
export Frame, Wal, DecodeResult, opcodeName, decodeFrame, encodeFrame,
  readI64, readU16, readU32, readU64, frames, scanReport, appendFrames,
  truncateTo, openWal, closeWal, highestLsn, flush, sync, readAll, describe
export FrameHeaderSize, TxnCommit, TxnRollback, TxnCheckpoint,
  opNoop, opCreateNode, opDeleteNode, opAddLabel, opRemoveLabel,
  opCreateEdge, opDeleteEdge, opSetProp, opRemoveProp, opCreateIndex,
  opDropIndex, opNewLabel, opNewRelType, opNewPropKey
