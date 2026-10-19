## glyphes — the version-history sidecar (`<db>.vhist`, PRD §4.1)
##
## Durable revisions, in a file beside the snapshot and not in the WAL.
## That separation is a pin, and WAL.md §6 is the reason: a checkpoint
## truncates the log to zero, so a log that also carried history would mean a
## history-preserving database can never truncate, and the cheapest possible
## backup — copy the file — turns into a streaming problem. The sidecar keeps
## one rule intact: the store's durability story is unchanged, and a database
## is backed up by copying two files.
##
## The naming precedent is index.nim's `IndexSidecarSuffix` (".indexes"),
## written and read in exactly this shape.
##
## ## Framing
##
## Append-only, framed exactly like the WAL — same idea, different file — so
## the length-in-header argument, the CRC argument and the recovery argument
## are all already argued in WAL.md rather than re-argued here:
##
##   [payloadLen u32][commitId u64][generation u64][kind u32][payload][crc32 u32]
##
## One frame per commit, holding the commit header and every revision in it.
## A commit is the transaction, and a transaction is atomic, so making the
## frame the commit is what makes recovery trivial: a frame either validates
## or it does not, and there is no partial commit to reason about.
##
## ## Why one frame and not one per revision
##
## One frame per revision would let a crash mid-commit leave a commit header
## with only some of its revisions, and recovery would have to decide whether
## a half-written commit happened. It did not — the engine never acknowledged
## it — but the reader of this format would have to know that, and would have
## to reconstruct it. One frame makes the answer structural: the CRC and the
## length either cover the whole commit or the whole commit is discarded.
##
## The cost is a frame as large as the largest transaction, which for a bulk
## load is the load. That is a real cost and it is recorded in
## limitations.md rather than left for someone to find.
##
## ## Generation, and why it is in the header
##
## The sidecar is written *inside* the transaction's fsync (PRD §4.1, V1.3),
## so the history is durable no later than the graph it describes. That
## ordering means the history can be *ahead* of the graph: a crash between
## the history append and the log's COMMIT frame leaves a commit in the file
## that the graph never accepted. Each frame therefore carries the store
## generation it was written against, and replay stops at the first frame
## whose generation the graph has not reached. The trailing frames are then
## truncated away, so the incoherence is repaired once rather than being
## re-examined at every open.
##
## ## Absent is not empty
##
## A missing sidecar means a database whose history was never enabled or was
## lost, and it opens as a store with no history rather than failing: the
## index sidecar sets that precedent (index.nim:657), and the reasoning is
## the same — history is additive, so losing it costs the history and not the
## data. A file that *exists* and cannot be read is a different thing, and is
## a refusal, because a torn frame in the middle of the file is not a
## question this format will guess at (PRD G4).

import std/[tables, os]
when defined(posix):
  import std/posix
import ../wal/crc32
import ../store/prop
import ../store/revision

const
  VhistSuffix* = ".vhist"
  ## The magic is not a header field — it is the first frame's payload prefix
  ## check below — so a database with an empty history is a file of zero
  ## frames and opens as "no history" without a special case.
  VhistMagic* = "GLYVHI01"

  VFrameHeaderSize* = 24
  ## [payloadLen u32][commitId u64][generation u64][kind u32]
  VFrameKindCommit* = 1'u32

type
  VhistFile* = ref object
    ## An open sidecar, append-only. The `f` handle is the append side; the
    ## replay side works on a whole-file string so a partial tail can be
    ## measured before anything is trusted.
    path*: string
    f*: File
    ## Bytes durable at the last successful sync. A checkpoint that rewrites
    ## the file must reset it, or the next append would claim bytes that are
    ## no longer there.
    synced*: int64

  VFrame* = object
    commitId*: uint64
    generation*: uint64
    payload*: string

# ------------------------------------------------------------------ framing

proc putU64(b: var string, v: uint64) {.inline.} =
  for i in 0 ..< 8:
    b.add char((v shr (8 * uint(i))) and 0xFF'u64)

proc putU32(b: var string, v: uint32) {.inline.} =
  for i in 0 ..< 4:
    b.add char((v shr (8 * uint(i))) and 0xFF'u32)

proc readU32(b: string; at: int): uint32 {.inline.} =
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(uint8(b[at + i])) shl (8 * uint(i)))

proc readU64(b: string; at: int): uint64 {.inline.} =
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(uint8(b[at + i])) shl (8 * uint(i)))

proc buildFrame(commitId, generation: uint64; payload: string): string =
  var head = newStringOfCap(VFrameHeaderSize)
  putU32(head, uint32(payload.len))
  putU64(head, commitId)
  putU64(head, generation)
  putU32(head, VFrameKindCommit)
  ## The CRC covers the header *and* the payload — everything but the CRC
  ## field itself. Covering only the header would leave the payload
  ## unwatched, which is the same mistake WAL.md §2 records being made and
  ## fixed: a commit's whole content lives in the payload, so an unprotected
  ## payload is an unprotected commit.
  let crc = crc32(head & payload)
  var tail = newStringOfCap(4)
  putU32(tail, crc)
  result = head & payload & tail

# --------------------------------------------------------------- the payload

proc encodeCommitPayload(rv: Revisions; rec: CommitRecord): string =
  ## The commit header, then every revision in the commit.
  ##
  ## `changed` is written, not recomputed from the revisions: it is the
  ## load-bearing field (PRD §4.1) and a replay that rebuilt it would be
  ## asserting that revisions and `changed` agree, which is a property this
  ## writer should not have to defend on the way back in.
  ##
  ## Each revision is the node's *effective* revision at this commit (see
  ## `revisionAt`), so a commit is one row per node whatever the transaction
  ## did to arrive there. Values go through prop.nim's codec, the same one
  ## the WAL uses, so there is one value vocabulary rather than two that have
  ## to agree.
  var b = newStringOfCap(512)
  b.add VhistMagic
  b.add '\x00'
  putU64(b, uint64(rec.changed.len))
  for id in rec.changed:
    putU64(b, uint64(id))
  ## Parents: count then ids. A merge has two, and the reader needs both —
  ## the whole merge fix was about a second parent being dropped.
  putU64(b, uint64(rec.parents.len))
  for p in rec.parents:
    putU64(b, p)
  putU64(b, rec.lsn)                        ## the WAL position (PRD §4.3)
  putU64(b, uint64(rec.changed.len))
  for id in rec.changed:
    let rev = rv.revisionAt(id, rec.id)
    putU64(b, uint64(id))
    b.add (if rev.live: '\x01' else: '\x00')
    putU64(b, uint64(rev.props.len))
    for (k, v) in rev.props:
      putU32(b, cast[uint32](k))
      let enc = encodeValue(v)
      putU64(b, uint64(enc.len))
      b.add enc
    putU64(b, uint64(rev.removed.len))
    for k in rev.removed:
      putU32(b, cast[uint32](k))
  b

type DecodedCommit* = object
  changed*: seq[int64]
  parents*: seq[uint64]
  lsn*: uint64
  ## nodeId -> its revision at the commit.
  revisions*: Table[int64, Revision]

proc decodeCommitPayload*(payload: string): DecodedCommit =
  ## The inverse of `encodeCommitPayload`. Every length is checked against
  ## what is actually there: a payload that declares more than it holds is
  ## refused rather than read past the end of.
  if payload.len < VhistMagic.len + 1:
    raise newException(ValueError, "vhist payload is too short to carry the magic")
  if payload[0 ..< VhistMagic.len] != VhistMagic:
    raise newException(ValueError, "vhist payload does not start with " & VhistMagic)
  var at = VhistMagic.len + 1

  proc need(n: int) =
    if n < 0 or at + n > payload.len:
      raise newException(ValueError,
        "vhist payload is truncated: needs " & $n & " bytes at offset " &
        $at & " of " & $payload.len)

  need(8); let nChanged = int(readU64(payload, at)); at += 8
  result.changed = newSeq[int64](nChanged)
  for i in 0 ..< nChanged:
    need(8); result.changed[i] = int64(readU64(payload, at)); at += 8
  need(8); let nParents = int(readU64(payload, at)); at += 8
  result.parents = newSeq[uint64](nParents)
  for i in 0 ..< nParents:
    need(8); result.parents[i] = readU64(payload, at); at += 8
  need(8); result.lsn = readU64(payload, at); at += 8
  need(8); let nNodes = int(readU64(payload, at)); at += 8
  result.revisions = initTable[int64, Revision]()
  for i in 0 ..< nNodes:
    need(9)
    let id = int64(readU64(payload, at)); at += 8
    let liveByte = uint8(payload[at]); at += 1
    var rev = Revision(commit: 0'u64, live: liveByte != 0'u8)
    need(8); let nProps = int(readU64(payload, at)); at += 8
    rev.props = newSeq[(int32, Value)](nProps)
    for j in 0 ..< nProps:
      need(4); let key = cast[int32](readU32(payload, at)); at += 4
      need(8); let vlen = int(readU64(payload, at)); at += 8
      need(vlen)
      rev.props[j] = (key, decodeValue(payload[at ..< at + vlen]))
      at += vlen
    need(8); let nRemoved = int(readU64(payload, at)); at += 8
    rev.removed = newSeq[int32](nRemoved)
    for j in 0 ..< nRemoved:
      need(4); rev.removed[j] = cast[int32](readU32(payload, at)); at += 4
    result.revisions[id] = rev
  if at != payload.len:
    raise newException(ValueError,
      "vhist payload has " & $(payload.len - at) & " trailing bytes")

# ------------------------------------------------------------------- writing

proc openVhist*(path: string): VhistFile =
  ## Open (creating if absent) the sidecar for appending.
  result = VhistFile(path: path & VhistSuffix)
  if not fileExists(result.path):
    writeFile(result.path, "")
  result.f = open(result.path, fmAppend)
  ## `fmAppend` positions at end-of-file on every write, so the size is the
  ## durable length only after a sync; measure it once here for a fresh open.
  result.synced = getFileSize(result.f)

proc appendCommit*(vf: VhistFile; commitId, generation: uint64;
                   payload: string) =
  ## Append one commit frame. Not synced — `syncVhist` is separate so the
  ## caller can place it inside the transaction's fsync discipline rather
  ## than having it implied by the append.
  let frame = buildFrame(commitId, generation, payload)
  vf.f.write(frame)

proc syncVhist*(vf: VhistFile) =
  ## Durable. Called before the log's COMMIT frame so history is never behind
  ## the graph it describes (PRD §4.1, V1.3).
  ##
  ## `flushFile` is only the stdio buffer. A "synced" sidecar that reached the
  ## OS page cache and not the platter is the exact incoherence this file
  ## exists to prevent — it would survive a process crash and not a power
  ## cut, which is precisely the failure a durability pin is about.
  vf.f.flushFile()
  ## fdatasync, the same call WAL.md's sync makes and for the same reason:
  ## data without the metadata cost, which is the whole durability point for
  ## an append-only file whose length is not load-bearing metadata.
  when defined(posix):
    if posix.fdatasync(vf.f.getFileHandle) != 0:
      raise newException(IOError,
                         "vhist: fdatasync failed: " & osErrorMsg(osLastError()))
  vf.synced = getFileSize(vf.f)

proc closeVhist*(vf: VhistFile) =
  if vf != nil and vf.f != nil:
    vf.f.close()
    vf.f = nil

# ------------------------------------------------------------------- reading

proc replayVhist*(path: string; uptoGeneration: uint64;
                  fromByte = 0): tuple[
    frames: seq[VFrame], goodBytes: int, truncated: bool, corrupted: bool] =
  ## Read every complete frame whose generation the graph has reached, and
  ## report the byte length of what was trusted.
  ##
  ## `goodBytes` is what makes truncation possible and safe: it is the end of
  ## the last frame that was both structurally complete and CRC-valid, so
  ## cutting the file back to it discards exactly the untrusted tail. It is
  ## set *before* the loop to `fromByte` itself — a scan that accepts nothing
  ## new still proved every byte up to the caller's offset, and answering 0
  ## for "nothing new" made a follower's next poll replay the whole file into
  ## an already-populated timeline (duplicate commits, shifted ids) and made
  ## an open that hit a bad first frame truncate the sidecar to zero.
  ##
  ## Four endings are distinguished and they are not the same answer:
  ##
  ##  * A clean end of file. Everything was read; `truncated` is false.
  ##  * A frame past `uptoGeneration`. The graph never accepted it, so it is
  ##    dropped and `truncated` is true — this is the crash-between-append-and
  ##    -commit case the generation stamp exists for.
  ##  * A partial frame: a length that runs past EOF. Everything before it is
  ##    still trusted, the rest is discarded, and `truncated` is true. A
  ##    partial *trailing* frame is the ordinary torn tail.
  ##  * A structurally complete frame whose CRC does not match, or whose kind
  ##    this version does not write. That is corruption, not a torn tail: the
  ##    bytes it promised are all there, so "the tail was torn" is not a
  ##    possible reading, and `corrupted` is true. The caller must refuse —
  ##    truncating here would delete every valid frame after the bad one, and
  ##    a rotted byte in the *first* frame would erase the whole sidecar. The
  ##    earlier behaviour treated both endings alike and truncated to
  ##    `goodBytes`, which is exactly the destruction PRD G4 forbids.
  ##
  ## `fromByte` resumes a scan at an offset a previous replay proved good, and
  ## is what makes a *polling* reader cheap: a follower that re-read the whole
  ## sidecar on every tick would pay O(history) per tick forever, which is the
  ## difference between "follows" and "keeps up". The offset is never a guess
  ## -- callers pass back a `goodBytes` from an earlier call.
  let file = path & VhistSuffix
  if not fileExists(file):
    return
  let buf = readFile(file)
  var at = fromByte
  if at < 0 or at > buf.len:
    ## The file shrank under us (a writer truncated its own untrusted tail).
    ## Restart from the top rather than trusting an offset that no longer
    ## refers to a frame boundary we validated.
    at = 0
  ## Accepting nothing new is still a proof: every byte up to `fromByte` was
  ## validated by the call that produced it. Starting `goodBytes` at 0 instead
  ## made a no-frame poll hand the caller an offset that had never been good,
  ## and a first-frame failure cut the file to nothing.
  result.goodBytes = at
  while at + VFrameHeaderSize + 4 <= buf.len:
    let payloadLen = int(readU32(buf, at))
    let commitId = readU64(buf, at + 4)
    let generation = readU64(buf, at + 12)
    let kind = readU32(buf, at + 20)
    if payloadLen < 0 or at + VFrameHeaderSize + payloadLen + 4 > buf.len:
      result.truncated = true
      break                                  # torn tail, or a lie in the length
    if kind != VFrameKindCommit:
      ## All the bytes the header promises are present, so this is not a torn
      ## tail — it is a frame this reader must not interpret. Refuse rather
      ## than cut: the frames after it may be perfectly good history.
      result.corrupted = true
      break
    let payload = buf[at + VFrameHeaderSize ..< at + VFrameHeaderSize + payloadLen]
    let stored = readU32(buf, at + VFrameHeaderSize + payloadLen)
    if crc32(buf[at ..< at + VFrameHeaderSize + payloadLen]) != stored:
      ## Same reasoning: structurally complete, CRC-bad. That is corruption.
      ## The old answer folded this into the torn-tail case and the caller
      ## truncated — measured, a single flipped byte in the first frame of a
      ## three-frame sidecar erased all three.
      result.corrupted = true
      break                                  # refuse; do not guess, do not cut
    if generation > uptoGeneration:
      result.truncated = true
      break                                  ## the graph never accepted it
    result.frames.add VFrame(commitId: commitId, generation: generation,
                             payload: payload)
    at += VFrameHeaderSize + payloadLen + 4
    result.goodBytes = at
  ## Bytes left over that no ending above explained — the while loop's own
  ## minimum (header + CRC) does not fit — are the torn tail. A corruption
  ## break already stopped with bytes remaining; its reason is named, and
  ## `truncated` must not claim "torn tail" on top of it.
  if at != buf.len and not result.corrupted:
    result.truncated = true

proc truncateVhist*(path: string; goodBytes: int) =
  ## Cut the file back to the last trusted byte, so a discarded tail is
  ## discarded once rather than re-examined at every open.
  let file = path & VhistSuffix
  if not fileExists(file):
    return
  if getFileSize(file) == goodBytes.int64:
    return
  ## Never grow. A `goodBytes` past the end means the caller computed an
  ## offset that does not correspond to a validated frame, and extending the
  ## file to reach it would fabricate history. A truncation that cannot
  ## shrink the file leaves it alone and says so.
  if goodBytes.int64 > getFileSize(file):
    return
  ## `fmAppend`, and the mode is the whole subtlety here. Nim's
  ## `fmWrite` **and `fmReadWrite` both truncate to zero on open** — so
  ## opening a 102-byte file and calling `ftruncate(102)` leaves 102 bytes of
  ## *zeroes*, destroying the very history the truncation was supposed to
  ## keep. The first version of this did exactly that, and it failed in the
  ## most dangerous way: the bad tail was gone, so a test checking only that
  ## would have passed while the trusted history was silently erased.
  ## `fmAppend` opens read/write positioned at the end without truncating, so
  ## `ftruncate` shortens and the bytes before the cut survive. It is the
  ## same mode `openWal` uses for its own `truncateTo`.
  let f = open(file, fmAppend)
  when defined(posix):
    if posix.ftruncate(f.getFileHandle, posix.Off(goodBytes.int64)) != 0:
      f.close()
      raise newException(IOError,
                         "vhist: truncate failed: " & osErrorMsg(osLastError()))
  f.close()

export encodeCommitPayload, decodeCommitPayload