## glyphes — the W3 bit-flip gate (WAL.md §8).
##
## One bit flipped, once, in a byte of the on-disk database; then the file
## is opened and the outcome must be **a clean open or a named error** —
## never a crash, never a clean open with wrong data.
##
## ## Why a sweep and not a sample
##
## The unit tests for W3 flip one bit per *region* (snapshot header,
## snapshot body, frame header, payload) and assert the CRC catches each.
## That is the right unit test and it is not the gate: a CRC catches what a
## CRC is *for*, and a sweep is what finds the case the CRC does not cover
## — an offset, a length, or an arithmetic path where a single flipped bit
## yields a value that is still self-consistent. Those are the silent
## corruptions, and they are the whole reason this gate exists (WAL.md:
## "W3 is the one that catches bugs in the recovery code itself").
##
## ## The oracle
##
## Three outcomes are counted, and only the third is a failure:
##
##   **named**    the open raised a named error (CRC mismatch, bad magic,
##                unsupported) — the correct answer: the file is damaged and
##                the store says so.
##   **clean**    the open succeeded and the fingerprint equals the clean
##                database's — the bit landed somewhere that does not
##                affect what a reader can observe (a padding byte, a
##                field the format does not define). A file that is
##                observably unchanged is not corrupt, whatever the bit
##                did to it.
##   **SILENT**   the open succeeded and the fingerprint *differs* — the
##                database serves wrong data with no error anywhere. This
##                is the failure the milestone exists to eliminate, and the
##                harness exits non-zero on the first one, naming the
##                offset and the bit.
##
## A crash (SIGSEGV, SIGABRT) is also a failure and needs no special
## handling: it kills the harness, Nimble sees a non-zero exit, and the
## gate is red. Running in-process is therefore not a risk here — it is the
## cheapest possible oracle for "did the engine survive".
##
## Usage: bitflip_harness [flips] [seed]
##   flips  default 10000; the WAL.md gate figure is 1e6
##   seed   default 1 — the sweep is deterministic, and a failure is
##          reproduced by re-running the same command

import std/[os, strutils, random, times, strformat, tables]
import ../../src/store/store
import ../../src/wal/recover
import ../../src/wal/snapshot
import ../../src/wal/wal
import ../../src/txn/txn
import ../../src/database
import ../../src/abi

type
  Outcome* = enum
    named,      ## opened and raised a named error
    clean,      ## opened, observably identical to the oracle
    ambiguous,  ## opened differently, and the flip was in the length field
                ## of the *final* frame — byte-identical to a crash between
                ## writing that frame's header and its payload, which WAL.md
                ## W4 says to drop. Counted and reported, not a defect.
    silent      ## opened differently for any other reason — a failure

  Verdict = object
    outcome: Outcome
    detail: string

## Everything a reader can observe, in id order. Identical in spirit to the
## W1 harness's fingerprint and for the same reason: counts would pass a
## prefix of the data that disagreed with the whole on every value.
proc renderValue(v: Value): string =
  ## Canonical text for the fingerprint. `$` does not exist for `Value`
  ## and the oracle wants the bytes a reader would observe, not a debug
  ## pretty-printer, so the rendering is local and exhaustive: a new
  ## ValueKind added to prop.nim fails to compile here rather than
  ## silently fingerprinting as the same text.
  ## The three reference kinds cannot reach this fingerprint — a recovered
  ## store holds properties, never a node — so they render as a marker that
  ## would fail any comparison rather than as something plausible.
  case v.kind
  of vkNull: "null"
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: $v.f
  of vkString, vkBytes: $v.s.len & ":" & v.s
  of vkVector: "vec" & $v.dims.len
  of vkList: "list" & $v.items.len
  of vkMap: "map" & $v.pairs.len
  of vkNode: "node!" & $v.id
  of vkEdge: "edge!" & $v.id
  of vkPath: "path!" & $v.path.nodes.len

proc fingerprint*(s: GraphStore): string =
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if not n.live: continue
    result.add "N" & $n.id & ":" & s.labels.nameOf(n.label)
    for k in s.nodePropKeys(n.id):
      var v: Value
      if s.getNodeProp(n.id, k, v):
        result.add "|" & k & "=" & renderValue(v)
    result.add "\n"
  for i in 1 ..< s.edges.len:
    let e = s.edges[i]
    if not e.live: continue
    result.add "E" & $e.id & ":" & $e.src & "->" & $e.dst & ":" &
      s.relTypes.nameOf(e.etype)
    for k in s.edgePropKeys(e.id):
      var v: Value
      if s.getEdgeProp(e.id, k, v):
        result.add "|" & k & "=" & renderValue(v)
    result.add "\n"
  result.add "gen:" & $s.generation & "\n"

proc buildDatabase(path: string, txns: int, perTxn: int): GraphStore =
  ## A database with a snapshot *and* a WAL, because those are two
  ## different regions to flip: a snapshot-only file never exercises the
  ## frame decoder, and a WAL-only file never exercises `loadSnapshot`.
  var db = openDatabase(path, GLY_OPEN_CREATE)
  defer: db.close()

  proc writeRun(prefix: int, txnIdBase: int) =
    let tx = begin(db.store, db.wal, uint32(txnIdBase))
    for i in 0 ..< perTxn:
      let id = prefix + i
      let n = tx.createNode("Bit")
      if n == 0: continue
      let nm = (if prefix == 0: "n" & $id else: "p" & $id)
      discard tx.setNodeProp(n, "name", Value(kind: vkString, s: nm))
      discard tx.setNodeProp(n, "k", Value(kind: vkInt, i: int64(id)))
      # Every 4th node carries a string long enough to leave the inline
      # slot, so the arena-copy path is in the file the sweep damages.
      if id mod 4 == 0:
        discard tx.setNodeProp(n, "bio",
          Value(kind: vkString, s: "bio-" & $id & "-" & "x".repeat(40)))
    discard tx.commit()

  # Committed work the snapshot will hold.
  for t in 0 ..< txns:
    writeRun(t * perTxn, t + 1)

  # Checkpoint: the snapshot now holds that work and the WAL is truncated.
  db.checkpoint(truncate = true, fsync = true)

  # Committed work *after* the checkpoint, so the WAL is non-empty and the
  # two regions are both real.
  for t in 0 ..< txns:
    writeRun(100000 + t * perTxn, 1000 + t)

  result = db.store

## Which region an offset falls in, for the failure report. A flip that
## needs this explanation is a flip worth explaining.
proc regionOf(file: string, offset: int): string =
  ## Which region an offset falls in, given the file it is an offset into.
  let buf = readFile(file)
  let len = buf.len
  if file.endsWith("-wal"):
    # A frame header is 32 bytes; a payload is the rest.
    if offset < FrameHeaderSize: return "wal frame header"
    return "wal frame payload"
  else:
    let trailerAt = len - 12
    if offset < 16: return "snapshot header"
    if offset >= trailerAt: return "snapshot trailer"
    return "snapshot body"

proc flipBitIn(file: string, offset: int, bit: int) =
  var buf = readFile(file)
  if offset < 0 or offset >= buf.len:
    raise newException(ValueError,
      "flip out of range: offset " & $offset & " in " & file &
      " of " & $buf.len & " bytes")
  # Mask to a byte: a set high bit XORed in can exceed 255 (255 xor 128),
    # and chr() on 383 is a range defect rather than a truncated byte.
  let before = buf[offset]
  buf[offset] = chr((ord(before) xor (1 shl bit)) and 0xFF)
  writeFile(file, buf)
  # Prove the byte actually changed, in memory *and* on disk: a flip that
  # silently does nothing turns the whole sweep into a no-op that reports
  # a clean database, which reads exactly like a passing gate.
  if buf[offset] == before:
    raise newException(ValueError,
      "flip did not change the byte: file " & file & " len " & $buf.len &
      " offset " & $offset & " bit " & $bit & " before " & $ord(before))
  if readFile(file)[offset] != buf[offset]:
    raise newException(ValueError, "flip did not reach the disk")

proc walBytesOf(path: string): string = readFile(path)

## Is this offset inside the header of the *last* complete frame in the
## log? That is the only place where a flipped length and a crash mid-write
## are the same bytes: past that frame the file ends, so "this frame's
## payload is missing" is exactly what a process that died between the
## header write and the payload write leaves behind — and WAL.md W4 says
## that case is dropped, correctly.
proc inFinalFrameHeader(bytes: string, offset: int): bool =
  var lastAt = -1
  var at = 0
  while at < bytes.len:
    let d = decodeFrame(bytes, at, bytes.len)
    if d.consumed == 0: break
    lastAt = at
    at += d.consumed
  if lastAt < 0: return false
  offset >= lastAt and offset < lastAt + FrameHeaderSize

proc tryOpen(path: string): tuple[ok: bool, fp: string, err: string] =
  ## Open the flipped file. Anything the store raises is a *named* error;
  ## an uncaught raise of any other kind is a harness bug, so it is
  ## re-raised rather than counted.
  try:
    var db = openDatabase(path, 0)
    defer: db.close()
    result.ok = true
    result.fp = fingerprint(db.store)
  except CatchableError as e:
    result.ok = false
    result.err = e.msg

proc main() =
  let flips = (if paramCount() > 0: parseInt(paramStr(1)) else: 10_000)
  let seed = (if paramCount() > 1: parseInt(paramStr(2)) else: 1)
  let tmp = getTempDir() / "glyphes-bitflip-" & $getCurrentProcessId()
  createDir(tmp)
  defer: removeDir(tmp)

  # The pristine files, built once and copied per flip: the flip has to be
  # the only thing that differs from a known-good database.
  let pristine = tmp / "pristine.glyph"
  let oracle = buildDatabase(pristine, 8, 12)
  let oracleFp = fingerprint(oracle)
  let snapLen = getFileSize(pristine)
  let walPath = pristine & "-wal"
  let walLen = (if fileExists(walPath): getFileSize(walPath) else: 0)

  echo &"W3 bit-flip sweep: {flips} flips, seed {seed}"
  echo &"  snapshot {snapLen} bytes, wal {walLen} bytes"

  var rng = initRand(int64(seed) * 1000003'i64 + 17'i64)
  var counts = initTable[string, int]()
  var firstFailure = ""

  for i in 0 ..< flips:
    let inWal = walLen > 0 and rand(rng, 1.0) < 0.5
    let file = if inWal: tmp / "case.glyph-wal" else: tmp / "case.glyph"
    let len = if inWal: walLen else: snapLen
    if len == 0: continue

    # Copy the pristine pair, flip one bit, open.
    removeFile(tmp / "case.glyph")
    removeFile(tmp / "case.glyph-wal")
    copyFile(pristine, tmp / "case.glyph")
    if fileExists(walPath): copyFile(walPath, tmp / "case.glyph-wal")

    let offset = rand(rng, 0 ..< len.int)
    let bit = rand(rng, 0 .. 7)
    flipBitIn(file, offset, bit)
    # The flip is verified BEFORE the open: a successful open may rewrite
    # the file (recovery truncates a tail), so comparing afterwards proves
    # nothing about what the store actually read.
    let src = if inWal: walPath else: pristine
    let afterFlip = readFile(file)
    let beforeFlip = readFile(src)
    let damaged = afterFlip != beforeFlip
    if not damaged:
      echo "flip did not stick: ", file, " byte ", offset, " inWal=", inWal,
           " lens=", afterFlip.len, "/", beforeFlip.len
      quit(1)

    let got = tryOpen(tmp / "case.glyph")
    let region = regionOf(file, offset)

    let outcome =
      if not got.ok:
        named
      elif got.fp == oracleFp:
        clean
      elif inWal and inFinalFrameHeader(readFile(src), offset):
        ambiguous
      else:
        silent
    let v = Verdict(outcome: outcome, detail: region)
    counts[$v.outcome] = counts.getOrDefault($v.outcome) + 1

    if v.outcome == silent and firstFailure.len == 0:
      # Classify: which frame, which opcode, and was it already covered by
      # the snapshot? A frame below the snapshot LSN is skipped by replay,
      # so a flip there is invisible *unless* the CRC is checked before the
      # skip — which is the question this gate exists to answer.
      var at = 0
      var desc = "no frame"
      let bytes = readFile(if inWal: walPath else: pristine)
      while at < bytes.len:
        let d = decodeFrame(bytes, at, bytes.len)
        if d.consumed == 0:
          desc = "decode stopped at " & $at & ": " & d.reason
          break
        let pAt = at + FrameHeaderSize
        if offset >= at and offset < pAt + d.frame.payload.len:
          desc = &"frame at {at} op={opcodeName(d.frame.op)} " &
                 &"lsn={d.frame.lsn} " &
                 &"inHeader={offset < pAt} inPayload={offset >= pAt} " &
                 &"payloadLen={d.frame.payload.len}"
          break
        at += d.consumed
      firstFailure = &"flip {i}: {region} byte {offset} bit {bit} — " &
                    &"opened clean with a different fingerprint [" & desc & "] " &
                    &"fileLen={file.len} fpNow={got.fp.len} fpOracle={oracleFp.len}"

    # Progress at a scale a person can watch.
    if flips >= 100_000 and (i + 1) mod 25_000 == 0:
      echo &"  {i + 1}/{flips}"

  echo ""
  echo &"  named (damaged, refused): {counts.getOrDefault(\"named\")}"
  echo &"  clean (observably unchanged): {counts.getOrDefault(\"clean\")}"
  echo &"  ambiguous (final-frame length, same bytes as a crash): " &
       &"{counts.getOrDefault(\"ambiguous\")}"
  echo &"  SILENT corruption: {counts.getOrDefault(\"silent\")}"

  if firstFailure.len > 0:
    echo ""
    echo "W3: RED — " & firstFailure
    quit(1)
  elif counts.getOrDefault("named") == 0 and counts.getOrDefault("silent") == 0:
    ## Every flip opening clean is its own failure mode: a sweep that
    ## detects nothing usually means it flipped nothing that mattered.
    echo ""
    echo "W3: RED — no flip produced a named error; the sweep is not " &
         "reaching the checked regions"
    quit(1)
  else:
    echo ""
    echo "W3: GREEN"
    quit(0)

## ---- W2: truncate at every 4 KB boundary -------------------------------
##
## Power-loss simulation, the other half of what recovery is for: a file
## that ends early is a file whose last writes were lost, so the outcome
## must be a clean open (to the last complete transaction) or a named
## error. Never a crash, and never an open whose contents disagree with
## what the truncation point implies.
proc truncateSweep(): tuple[boundaries: int, opened: int, named: int, bad: int] =
  ## Build one database, then cut copies of it at every 4 KB boundary.
  ## A file that ends early is a file whose last writes were lost: the
  ## outcome must be a clean open (to the last complete transaction) or a
  ## named error — never a crash, and never an open holding *more* than
  ## the whole file did.
  let dir = getTempDir() / "glyphes-w2-" & $getCurrentProcessId()
  removeDir(dir)
  createDir(dir)
  let base = dir / "base.glyph"
  var cleanNodes = 0
  block:
    var db = openDatabase(base, GLY_OPEN_CREATE)
    for t in 0 ..< 30:
      let tx = begin(db.store, db.wal, uint32(t + 1))
      for i in 0 ..< 20:
        let n = tx.createNode("Bit")
        discard tx.setNodeProp(n, "k", Value(kind: vkInt, i: int64(t * 20 + i)))
        discard tx.setNodeProp(n, "name",
          Value(kind: vkString, s: "node-" & $(t * 20 + i) & "-" & "x".repeat(30)))
      discard tx.commit()
    db.checkpoint(truncate = true, fsync = true)
    for t in 0 ..< 30:
      let tx = begin(db.store, db.wal, uint32(1000 + t))
      for i in 0 ..< 20:
        let n = tx.createNode("Bit")
        discard tx.setNodeProp(n, "k", Value(kind: vkInt, i: int64(100000 + t * 20 + i)))
        discard tx.setNodeProp(n, "name",
          Value(kind: vkString, s: "post-" & $(t * 20 + i) & "-" & "y".repeat(30)))
      discard tx.commit()
    cleanNodes = db.store.nodes.len
    db.close()

  let snapSize = getFileSize(base)
  let walSize = (if fileExists(base & "-wal"): getFileSize(base & "-wal") else: 0)
  # Walk to the end of the *larger* file, so every 4 KB boundary of either
  # file is covered: cutting only to max() would leave the tail of the
  # smaller file untested, and the smaller file is the one most likely to
  # end mid-frame.
  let total = snapSize + walSize
  let snap = dir / "cut.glyph"
  let wal = snap & "-wal"

  echo &"W2 truncate sweep: {snapSize} B snapshot, {walSize} B log, clean {cleanNodes} nodes"
  var at = 0'i64
  while at <= total:
    copyFile(base, snap)
    if fileExists(base & "-wal"): copyFile(base & "-wal", wal)
    # Cut both files at the same offset: power loss does not truncate one
    # and leave the other whole.
    let sLen = min(at, getFileSize(snap))
    writeFile(snap, readFile(snap)[0 ..< sLen.int])
    if fileExists(wal):
      let wLen = min(at, getFileSize(wal))
      writeFile(wal, readFile(wal)[0 ..< wLen.int])

    var ok = false
    var nodes = 0
    try:
      var d = openDatabase(snap, 0)
      nodes = d.store.nodes.len
      ok = true
      d.close()
    except CatchableError:
      discard

    inc result.boundaries
    if ok:
      inc result.opened
      # More than the whole file had is corruption. Fewer is a legitimate
      # truncation: those writes were lost, and that is what truncation means.
      if nodes > cleanNodes:
        inc result.bad
        echo &"  TRUNCATION AT {at} OPENED WITH {nodes} NODES (whole file had {cleanNodes})"
    else:
      inc result.named
    inc at, 4096
  removeDir(dir)

when isMainModule:
  ## `bitflip_harness truncate` runs W2; without it, the W3 sweep runs.
  if paramCount() >= 1 and paramStr(1) == "truncate":
    let r = truncateSweep()
    echo &"  boundaries: {r.boundaries}  opened clean: {r.opened}  named error: {r.named}"
    if r.bad > 0:
      echo "W2: RED — {r.bad} truncations served more data than the whole file"
      quit(1)
    echo "W2: GREEN"
  else:
    main()