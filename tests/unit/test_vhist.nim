## glyphes — version history, V1: the `.vhist` sidecar (gate G4, PRD R2)
##
## A durable history is not a file that exists; it is a file that comes back
## the same after a crash, and refuses to come back *wrong*. Every test here
## is one of the ways it can fail to do that, and each one is a way the format
## could be subtly wrong while still working on the happy path.

import std/unittest
import std/os
import std/tables

import ../../src/store/store
import ../../src/store/prop
import ../../src/store/revision
import ../../src/store/vhist
import ../../src/wal/wal
import ../../src/txn/txn
import ../../src/abi
import ../../src/database
import ../../src/errors

proc txnDir(): string =
  let d = "tmp" / "test-vhist"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = txnDir() / name
  removeFile(p); removeFile(p & "-wal"); removeFile(p & ".vhist")
  removeFile(p & ".vhist.tmp"); removeFile(p & "-indexes")
  result = p

suite "V1 the history sidecar (VERSIONING-PLAN V1)":
  test "a reopened database has the same history it closed with":
    ## The whole point of the file. A history that survives the process is
    ## the difference between a feature and a demo.
    ##
    ## Driven through `openDatabase`, not `newStore`, because that is what
    ## associates a store with a sidecar: a bare `newStore()` has no path, so
    ## it has history in memory and nothing on disk — which is the V0 mode,
    ## not a bug, but it would make this test pass without writing anything.
    let path = freshPath("roundtrip.glyph")
    block:
      let db = openDatabase(path, GLY_OPEN_CREATE)
      block:
        let t1 = db.beginTransaction()
        let n = t1.createNode("Person")
        discard t1.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
        discard t1.setNodeProp(n, "age", Value(kind: vkInt, i: 36))
        check db.commitTransaction(t1)
      block:
        let t2 = db.beginTransaction()
        discard t2.setNodeProp(1, "name", Value(kind: vkString, s: "grace"))
        check db.commitTransaction(t2)
      check db.store.history.commits.len == 2
      check db.store.vhistFile != nil
      close(db)

    check fileExists(path & ".vhist")
    ## Reopen: the graph comes back from its own recovery, and the history
    ## comes back from the sidecar.
    let db2 = openDatabase(path, 0'i32)
    let h = db2.store.history
    check h.commits.len == 2
    ## The states, not just the count: the first commit's value and the second's.
    let s1 = h.stateAt(1, 1'u64)
    check s1.live == true
    var sawAda = false
    for (k, v) in s1.props:
      if v.kind == vkString and v.s == "ada": sawAda = true
    check sawAda
    let s2 = h.stateAt(1, 2'u64)
    var sawGrace = false
    for (k, v) in s2.props:
      if v.kind == vkString and v.s == "grace": sawGrace = true
    check sawGrace
    ## And a diff across the reopened history still works.
    check h.diff(1'u64, 2'u64).len == 1
    close(db2)

  test "every property kind survives the round trip byte for byte":
    ## The encoder writes through prop.nim's codec, so this is mostly a check
    ## that nothing was dropped on the way — and vectors are the case where a
    ## dropped or truncated blob still "decodes" to something.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    let vec = Value(kind: vkVector, dims: @[1.5'f32, -2.25'f32, 0.0'f32])
    let lst = Value(kind: vkList, items: @[Value(kind: vkInt, i: 1),
                                           Value(kind: vkString, s: "x")])
    let mp = Value(kind: vkMap, pairs: @[("k", Value(kind: vkBool, b: true))])
    rv.noteRevision(c1, 1, @[(1'i32, Value(kind: vkBool, b: false)),
                             (2'i32, Value(kind: vkFloat, f: 1.5)),
                             (3'i32, Value(kind: vkString, s: "hi")),
                             (4'i32, vec), (5'i32, lst), (6'i32, mp)], true)
    rv.sealCommit(c1)

    let payload = encodeCommitPayload(rv, rv.commits[0])
    let dec = decodeCommitPayload(payload)
    check dec.changed == @[1'i64]
    let revTable: Table[int64, Revision] = dec.revisions
    check revTable.hasKey(1)
    let rev = revTable[1]
    check rev.live == true
    var kinds: seq[ValueKind] = @[]
    for (k, v) in rev.props:
      case k
      of 1: check v.kind == vkBool; check v.b == false
      of 2: check v.kind == vkFloat; check v.f == 1.5
      of 3: check v.kind == vkString; check v.s == "hi"
      of 4:
        check v.kind == vkVector
        check v.dims == @[1.5'f32, -2.25'f32, 0.0'f32]
      of 5:
        check v.kind == vkList
        check v.items.len == 2
        check v.items[0].i == 1
      of 6:
        check v.kind == vkMap
        check v.pairs[0][0] == "k"
      else: discard
      kinds.add v.kind
    check rev.props.len == 6

  test "a removed property round trips as removed, not as a null":
    ## The absence must survive the file. A removal that came back as a null
    ## would be the silent data loss CYPHER.md §3.2 pins, now across a
    ## restart instead of across a fold.
    let rv = initRevisions()
    let c1 = rv.openCommit("main")
    rv.noteRevision(c1, 1, @[(1'i32, Value(kind: vkString, s: "x"))], true,
                    @[2'i32])
    rv.sealCommit(c1)
    let dec = decodeCommitPayload(encodeCommitPayload(rv, rv.commits[0]))
    let rev = dec.revisions[1'i64]
    check rev.removed == @[2'i32]
    check rev.props.len == 1

  test "a torn trailing frame is truncated and the open continues":
    ## The crash case. A frame that is half-written is a commit that was never
    ## acknowledged, so discarding it is correct — and the whole point of the
    ## CRC and the length-in-header is that "half-written" is detectable
    ## rather than a guess.
    let path = freshPath("torn.glyph")
    block:
      let w = openWal(path & "-wal")
      let s = newStore()
      let t1 = begin(s, w, 1'u32, doSync = false)
      discard t1.createNode("A")
      check t1.commit()
      closeWal(w)
    ## Append a complete frame, then a partial one.
    block:
      let vf = openVhist(path)
      let rv = initRevisions()
      let c = rv.openCommit("main")
      rv.noteRevision(c, 2, @[], true)
      rv.sealCommit(c)
      appendCommit(vf, 1, 2, encodeCommitPayload(rv, rv.commits[0]))
      syncVhist(vf)
      closeVhist(vf)
    block:
      let f = open(path & ".vhist", fmAppend)
      f.write("GLYVH\x00\x01")     ## a header that promises more than follows
      f.close()
    let replay = replayVhist(path, 99'u64)
    check replay.frames.len == 1   ## the complete frame survived
    check replay.truncated == true
    ## ...and the file is cut back so the torn tail is discarded once.
    truncateVhist(path, replay.goodBytes)
    check getFileSize(path & ".vhist").int == replay.goodBytes
    ## A second replay now sees nothing to complain about.
    let again = replayVhist(path, 99'u64)
    check again.frames.len == 1
    check again.truncated == false

  test "a frame whose CRC is wrong is named corruption, not a torn tail":
    ## A bit flip in the payload is corruption, not a torn tail. The frame is
    ## structurally complete — every byte the header promises is present — so
    ## "the tail was torn" is not a possible reading, and the two endings must
    ## not share an answer: a torn tail is cut, a corrupt frame refuses the
    ## open. Both stop the replay at the same byte, which is still the
    ## intended answer: the last thing provably intact is what gets read, and
    ## nothing after it is guessed at.
    let path = freshPath("crc.glyph")
    block:
      let vf = openVhist(path)
      let rv = initRevisions()
      let c = rv.openCommit("main")
      rv.noteRevision(c, 1, @[], true)
      rv.sealCommit(c)
      appendCommit(vf, 1, 1, encodeCommitPayload(rv, rv.commits[0]))
      syncVhist(vf)
      closeVhist(vf)
    ## Flip a byte inside the payload.
    let raw = readFile(path & ".vhist")
    var corrupted = raw
    corrupted[corrupted.len - 2] = chr(ord(corrupted[corrupted.len - 2]) xor 0xFF)
    writeFile(path & ".vhist", corrupted)
    let replay = replayVhist(path, 99'u64)
    check replay.frames.len == 0
    check replay.corrupted == true
    check replay.truncated == false

  test "a corrupt first frame refuses the open instead of erasing the sidecar":
    ## One rotted byte used to cost the whole file. The replay answered
    ## `goodBytes = 0` for a first-frame failure — an offset nothing had
    ## validated — and the open truncated to it: three frames, 322 bytes,
    ## became zero commits and an empty sidecar, with the graph itself fine
    ## and nothing signalling the loss. Now the open refuses by name, the
    ## file is left exactly as it was, and the replay names the corruption
    ## rather than calling it torn.
    let path = freshPath("corrupt-first.glyph")
    block:
      let db = openDatabase(path, GLY_OPEN_CREATE)
      for i in 1 .. 3:
        let t = db.beginTransaction()
        discard t.createNode("N")
        check db.commitTransaction(t)
      close(db)
    let sizeBefore = getFileSize(path & ".vhist")
    check sizeBefore > 0
    var raw = readFile(path & ".vhist")
    ## Byte 28 sits inside the first frame's payload (the header is 24 bytes).
    raw[28] = chr(uint8(raw[28]) xor 0x01'u8)
    writeFile(path & ".vhist", raw)
    expect GlyError:
      discard openDatabase(path, 0'i32)
    check getFileSize(path & ".vhist").int == sizeBefore.int
    ## And the replay itself says corruption, at the offset it stopped on.
    let replay = replayVhist(path, high(uint64))
    check replay.corrupted == true
    check replay.truncated == false
    check replay.goodBytes == 0
    ## The earlier file is still readable up to the bad frame's byte — which
    ## is what a *repair* decision, if one is ever added, would need.
    check replay.frames.len == 0

  test "a frame above the graph's generation is dropped":
    ## The crash-between-append-and-COMMIT case. The history is written inside
    ## the fsync and before the log's COMMIT frame, so it can be one commit
    ## *ahead* of a graph that did not accept it. The generation stamp is how
    ## replay tells that apart from a real commit.
    let path = freshPath("ahead.glyph")
    block:
      let vf = openVhist(path)
      let rv = initRevisions()
      let c = rv.openCommit("main")
      rv.noteRevision(c, 1, @[], true)
      rv.sealCommit(c)
      appendCommit(vf, 1, 7, encodeCommitPayload(rv, rv.commits[0]))  ## gen 7
      syncVhist(vf)
      closeVhist(vf)
    ## The graph only reached generation 5.
    let replay = replayVhist(path, 5'u64)
    check replay.frames.len == 0
    check replay.truncated == true
    ## Up to 7 and it is accepted.
    check replayVhist(path, 7'u64).frames.len == 1

  test "an absent sidecar is no history, not a failure":
    ## A database whose history was never enabled, or was lost, still opens.
    ## History is additive; losing it costs the history and not the data.
    let path = freshPath("absent.glyph")
    block:
      let w = openWal(path & "-wal")
      let s = newStore()
      let t1 = begin(s, w, 1'u32, doSync = false)
      discard t1.createNode("Person")
      check t1.commit()
      closeWal(w)
    removeFile(path & ".vhist")
    let replay = replayVhist(path, 99'u64)
    check replay.frames.len == 0
    check replay.truncated == false