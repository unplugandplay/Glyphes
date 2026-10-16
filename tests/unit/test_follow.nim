## F2 — the follower: SG6 (watermark discipline) and SG7 (a real second
## process following a live writer).
##
## SG5 asked whether a follower can *trust* the watermark. These ask what it
## can do with one. The gate that matters is SG7, and it is deliberately
## cross-process: a follower that only works in-process has proved nothing,
## because the watermark's whole job is to cross a process boundary.

import std/[unittest, os, posix, times, strutils]
import ../../src/abi
import ../../src/store/prop
import ../../src/txn/txn
import ../../src/store/revision
import ../../src/store/shm
import ../../src/store/vhist
import ../../src/store/follow
import ../../src/database

var dbCounter = 0

proc freshDb(): string =
  inc dbCounter
  result = "tmp" / ("follow-db" & $dbCounter & ".glyph")
  for suf in ["", "-wal", "-lock", "-shm", "-indexes", ".vhist"]:
    removeFile(result & suf)

proc commit(db: Database; name: string): uint64 =
  ## One commit creating one node; returns the generation the watermark now
  ## names.
  let tx = db.beginTransaction()
  discard tx.createNode(name)
  discard db.commitTransaction(tx)
  db.store.shm.loadGeneration()

suite "F2 SG6 the follower applies exactly what the watermark covers":
  test "a follower sees the writer's commits":
    let p = freshDb()
    let w = openDatabase(p, GLY_OPEN_CREATE)
    let g1 = w.commit("Person")
    let g2 = w.commit("City")
    close(w)

    let f = openFollower(p)
    check f.unavailable == ""
    check f.head == 0              ## nothing applied until refresh
    check f.refresh()
    ## `g2` is the writer's *generation*; `f.generation` is the follower's view
    ## of the same thing. `f.head` is a commit id, a different counter, and
    ## comparing the two is the confusion this feature is built to avoid.
    check f.generation == g2
    ## Both commits, and in the writer's order.
    let seen = f.followAt(0)
    check seen.len == 2

  test "refresh is incremental and idempotent":
    ## The cost that matters: a follower that re-reads all of history per tick
    ## falls behind forever. Applying only new frames is what makes polling
    ## viable, and re-refreshing with nothing new must not double-apply.
    let p = freshDb()
    let w = openDatabase(p, GLY_OPEN_CREATE)
    discard w.commit("A")
    close(w)

    let f = openFollower(p)
    check f.refresh()
    let after1 = f.head
    let bytes1 = f.bytes
    check f.followAt(0).len == 1

    check not f.refresh()          ## nothing new
    check f.head == after1
    check f.bytes == bytes1        ## and it did not re-read the file
    check f.followAt(0).len == 1   ## still exactly one commit, not two

  test "a follower stops at the watermark, not at end of file":
    ## The reason the watermark exists. `.vhist` is fsynced before the commit
    ## record, so after a crash it can hold frames the graph never accepted.
    ## A follower that read to EOF would show those as real commits.
    let p = freshDb()
    let w = openDatabase(p, GLY_OPEN_CREATE)
    discard w.commit("A")
    discard w.commit("B")
    discard w.commit("C")
    close(w)

    ## Replay by hand to the *first* commit's generation, with three frames
    ## present on disk. The mark is read off the writer rather than hardcoded,
    ## because generations do not start at 0 and a hardcoded 1 would pass for
    ## "excludes everything" — a test that cannot tell those apart.
    let marks = replayVhist(p, high(uint64), 0).frames
    check marks.len == 3
    let rv = initRevisions()
    let first = replayInto(rv, p, 0, marks[0].generation)
    check first.applied == 1     ## the other two are past the mark
    check rv.commits.len == 1

    ## And the same file, followed normally, gets all three.
    let f = openFollower(p)
    check f.refresh()
    check f.followAt(0).len == 3

  test "a follower never truncates the sidecar":
    ## The one thing `replayHistory` does that a reader must not. A reader
    ## that truncated the untrusted tail would be a writer by another name,
    ## and two writers truncating one file concurrently is how the log dies.
    let p = freshDb()
    let w = openDatabase(p, GLY_OPEN_CREATE)
    discard w.commit("A")
    close(w)
    let vhist = p & ".vhist"
    let sizeBefore = getFileSize(vhist)

    ## Append a torn tail — a frame header promising more than it delivers.
    var f = open(vhist, fmAppend)
    f.write("\x40\x00\x00\x00" & repeat("\x11", 4))
    f.close()
    let sizeTorn = getFileSize(vhist)
    check sizeTorn > sizeBefore

    let fol = openFollower(p)
    check fol.refresh()
    check fol.followAt(0).len == 1     ## the good frame, and only that
    check getFileSize(vhist) == sizeTorn  ## and the tail is still there
    discard fol

  test "a follower of a watermark-less database says so":
    ## Attaching before a writer has published is an ordinary race, not an
    ## error. The follower exists, reports nothing applied, and says why.
    let p = freshDb()
    let f = openFollower(p)
    check f.unavailable != ""
    check not f.refresh()
    check f.head == 0

  test "two followers of one writer see the same history":
    ## "One writer, many followers" is the shape; this is the shape's floor.
    let p = freshDb()
    let w = openDatabase(p, GLY_OPEN_CREATE)
    for i in 1 .. 5: discard w.commit("N" & $i)
    close(w)
    let a = openFollower(p)
    let b = openFollower(p)
    check a.refresh() and b.refresh()
    check a.head == b.head
    check a.followAt(0).len == b.followAt(0).len
    ## And their timelines agree commit-for-commit, not merely in count.
    for c in a.followAt(0):
      let d = b.revisions.commitAt(c.id)
      check d.id == c.id and d.lsn == c.lsn

suite "F2 SG7 a second *process* follows a live writer":
  ## Everything above could be in-process and still prove nothing. The
  ## watermark exists to cross a process boundary, so the gate does too.

  const Child = 1

  proc childMain(path: string) =
    let db = openDatabase(path, GLY_OPEN_CREATE)
    for i in 1 .. 20:
      let tx = db.beginTransaction()
      discard tx.createNode("N" & $i)
      discard db.commitTransaction(tx)
    close(db)
    quit(0)

  test "a follower in the parent tracks a writer in the child":
    let p = freshDb()
    ## The parent opens the follower *first*, before the writer exists, so the
    ## "attach to an absent watermark" path is exercised for real rather than
    ## in a unit test's imagination.
    let f = openFollower(p)
    check f.unavailable != ""

    let pid = posix.fork()
    if pid == 0:
      childMain(p)

    ## Poll until the child's commits are visible, with a deadline. A follower
    ## that never converges is the failure; one that converges slowly is fine.
    let deadline = epochTime() + 30.0
    var converged = false
    while epochTime() < deadline:
      discard f.refresh()
      if f.head >= 20:
        converged = true
        break
      sleep(20)
    var st: cint
    discard posix.waitpid(pid, st, 0)

    check converged       ## the follower saw all 20 commits
    check f.followAt(0).len == 20
    check f.unavailable == ""   ## and it found the watermark on a later poll
