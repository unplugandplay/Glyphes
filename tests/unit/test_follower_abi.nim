## glyphes — the follower surface as a *foreign caller* sees it (S1, gate SS1).
##
## Every follower suite so far drives the engine from the inside:
## `openFollower`, `refresh`, `head`. That proves the follower. It does not
## prove the thing S1 actually delivers — that the functions in
## src/glyphes.h are reachable, correctly typed, and safe against a caller
## that knows nothing about Nim.
##
## So this file calls the exported procs themselves, through `GlyHandle`
## integers, exactly as C and Ruby will:
##
##   - `glyphes_follower_open` hands back a uintptr_t naming a Follower the
##     caller never sees; every question goes through the handle.
##   - the ABI follower must *agree* with the Nim follower on the same
##     database (SS1) — the boundary must carry the truth, not approximate it.
##   - a follower handle is not a database handle: passing one where the
##     other is expected is GLY_ERR_STALE, the write-defense holding at the
##     boundary the same way it holds inside (B4).
##
## The write-defense itself — that there is no glyphes_follower_commit to
## call — is a property of the exported symbol table (SS2), checked with
## `nm` rather than here: a test cannot reference a symbol that must not
## exist.

import std/unittest
import std/os
import std/posix
import ../../src/abi
import ../../src/errors
import ../../src/handles
import ../../src/glyphes
import ../../src/database
import ../../src/store/store
import ../../src/store/prop
import ../../src/store/follow
import ../../src/store/shm
import ../../src/txn/txn

proc abiDir(): string =
  let d = "tmp" / "test-follower-abi"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = abiDir() / name
  for suf in ["", "-wal", "-lock", "-shm", "-indexes", ".vhist"]:
    removeFile(p & suf)
  result = p

proc openWriter(path: string): Database =
  openDatabase(path, int32(GLY_OPEN_CREATE))

proc commitOne(db: Database; label: string) =
  let tx = db.beginTransaction()
  discard tx.createNode(label)
  discard db.commitTransaction(tx)

proc openAbiFollower(path: string): GlyHandle =
  ## Through the exported proc, so the handle encoding and registration are
  ## part of what is under test — not just the follower's own logic.
  var h: GlyHandle
  let status = glyphes_follower_open(path.cstring, addr h)
  if status != 0:
    raise newException(AssertionDefect,
      "glyphes_follower_open(" & path & ") -> " & $status & ": " &
      globalErrorMsg())
  check h != 0
  h

suite "ABI: follower (S1, PRD-SHARED F2)":
  test "the ABI follower agrees with the Nim follower (SS1)":
    ## The boundary must carry the truth, not approximate it: head,
    ## generation and lsn read through the C ABI have to equal what the
    ## in-process follower computes on the same database.
    let path = freshPath("agree.glyph")
    let w = openWriter(path)
    for i in 1 .. 5:
      w.commitOne("N" & $i)

    let nimSide = openFollower(path)
    check nimSide.refresh()

    let h = openAbiFollower(path)
    var advanced: int32
    check glyphes_follower_refresh(h, addr advanced) == 0
    check advanced == 1                 ## new commits were folded in

    var head, gen, lsn: uint64
    check glyphes_follower_head(h, addr head) == 0
    check glyphes_follower_generation(h, addr gen) == 0
    check glyphes_follower_lsn(h, addr lsn) == 0

    check head == nimSide.head
    check gen == nimSide.generation
    check lsn == nimSide.lsn
    check head == 5                     ## and it is the right answer, not
    check gen == nimSide.generation     ## merely a self-consistent one

    ## A second refresh reports nothing new — the ABI path is idempotent
    ## the same way the Nim path is.
    check glyphes_follower_refresh(h, addr advanced) == 0
    check advanced == 0

    check glyphes_follower_close(h) == 0
    close(w)

  test "refresh reflects a live writer between polls":
    ## Following is polling, not a snapshot: commits that land after the
    ## first refresh must be visible to the next one through the ABI.
    let path = freshPath("live.glyph")
    let w = openWriter(path)
    w.commitOne("first")

    let h = openAbiFollower(path)
    var advanced: int32
    check glyphes_follower_refresh(h, addr advanced) == 0
    var head: uint64
    check glyphes_follower_head(h, addr head) == 0
    check head == 1

    w.commitOne("second")
    check glyphes_follower_refresh(h, addr advanced) == 0
    check advanced == 1
    check glyphes_follower_head(h, addr head) == 0
    check head == 2

    check glyphes_follower_close(h) == 0
    close(w)

  test "a follower handle is refused where a database is expected":
    ## The write-defense at the boundary: a follower names no graph, so it
    ## must be unusable at every entry point that mutates one. These are
    ## type errors, not behavioural checks — the registry refuses them
    ## before any follower state is touched.
    let path = freshPath("type.glyph")
    let w = openWriter(path)
    w.commitOne("n")
    let h = openAbiFollower(path)

    ## glyphes_close on a follower: not a database.
    check glyphes_close(h) == int32(glyErrStale)
    ## Beginning a transaction on a follower: not a database.
    var txh: GlyHandle
    check glyphes_tx_begin(h, addr txh) == int32(glyErrStale)
    check txh == 0

    close(w)

  test "a database handle is refused where a follower is expected":
    ## The same defense the other way: a database is not a follower, and
    ## asking follower questions of one must not read follower fields out of
    ## a database object. No writer is opened here — the type confusion is
    ## the only thing under test, and a second writable open of the same
    ## file would be refused by the writer lock before it reached the type
    ## check.
    let path = freshPath("type2.glyph")
    var dbh: GlyHandle
    check glyphes_open(path.cstring, int32(GLY_OPEN_CREATE), addr dbh) == 0

    var out64: uint64
    check glyphes_follower_head(dbh, addr out64) == int32(glyErrStale)
    check glyphes_follower_generation(dbh, addr out64) == int32(glyErrStale)
    check glyphes_follower_lsn(dbh, addr out64) == int32(glyErrStale)
    var adv: int32
    check glyphes_follower_refresh(dbh, addr adv) == int32(glyErrStale)
    ## And a database cannot be closed through the follower close.
    check glyphes_follower_close(dbh) == int32(glyErrStale)

    check glyphes_close(dbh) == 0

  test "a closed follower handle is stale":
    ## After close, the handle names nothing; every question is refused, not
    ## answered from freed state (B8).
    let path = freshPath("stale.glyph")
    let w = openWriter(path)
    w.commitOne("n")
    let h = openAbiFollower(path)
    check glyphes_follower_close(h) == 0

    var head: uint64
    check glyphes_follower_head(h, addr head) == int32(glyErrStale)
    var adv: int32
    check glyphes_follower_refresh(h, addr adv) == int32(glyErrStale)
    ## Closing again is a stale-handle error, not a double free.
    check glyphes_follower_close(h) == int32(glyErrStale)
    close(w)

  test "a watermark-less database opens with the reason, not a failure":
    ## Attaching before a writer has published is a race, not an error: the
    ## open succeeds, refresh reports nothing new, and the reason is
    ## readable through the error accessor.
    let path = freshPath("nowm.glyph")
    let w = openWriter(path)          ## creates db but the shm exists...
    w.commitOne("x")                  ## ...so actually publish something, then
    removeFile(path & "-shm")         ## remove only the watermark, as a crash might.

    let h = openAbiFollower(path)
    var adv: int32
    check glyphes_follower_refresh(h, addr adv) == 0
    check adv == 0
    let reason = $glyphes_follower_error(h)
    check reason != ""
    check glyphes_follower_close(h) == 0
    close(w)

  test "null out-pointers are refused, not written through":
    ## A foreign caller passes null sometimes; the boundary must answer
    ## GLY_ERR rather than segfault.
    let path = freshPath("null.glyph")
    let w = openWriter(path)
    w.commitOne("n")
    let h = openAbiFollower(path)

    check glyphes_follower_head(h, nil) == int32(glyErr)
    check glyphes_follower_refresh(h, nil) == int32(glyErr)
    var adv: int32
    check glyphes_follower_refresh(h, addr adv) == 0
    check glyphes_follower_close(h) == 0
    close(w)

suite "ABI: the follower survives a crashed writer (S4, SS5)":
  ## SG7, pointed at the boundary. A writer is SIGKILLed after its history
  ## frame is durable but before the watermark moves; the ABI follower must
  ## be off by exactly the unacknowledged commit, the same guarantee the
  ## Nim-side gate proves, now carried across the C ABI. If the boundary
  ## weakened it -- if an out-param or the refresh path read past the
  ## watermark -- this fails.

  test "a writer SIGKILLed mid-commit leaves the ABI follower off by exactly one":
    let path = freshPath("crash.glyph")

    let pid = posix.fork()
    if pid == 0:
      putEnv("GLYPHES_CRASH_AT", "after-vhist-sync:5")
      let w = openWriter(path)
      for i in 1 .. 4:
        w.commitOne("acked" & $i)
      w.commitOne("doomed")             ## dies inside: frame durable,
      quit(0)                           ## watermark never moved

    var st: cint
    discard posix.waitpid(pid, st, 0)
    check (st and 0x7f) == 9

    let h = openAbiFollower(path)
    var advanced: int32
    check glyphes_follower_refresh(h, addr advanced) == 0
    check advanced == 1
    var head, gen, lsn: uint64
    check glyphes_follower_head(h, addr head) == 0
    check glyphes_follower_generation(h, addr gen) == 0
    check glyphes_follower_lsn(h, addr lsn) == 0

    ## Exactly the four acknowledged commits, no phantom fifth: the safety
    ## property SG7 exists for, carried across the boundary.
    check head == 4
    let wm = openShmReadOnly(path).loadGeneration()
    check gen == wm

    ## And the follower's own view agrees with a fresh Nim follower on the
    ## same crashed database -- the two surfaces see the same history.
    let nimSide = openFollower(path)
    check nimSide.refresh()
    check head == nimSide.head
    check gen == nimSide.generation
    check lsn == nimSide.lsn

    check glyphes_follower_close(h) == 0
