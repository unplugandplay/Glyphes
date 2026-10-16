## SG7 — crash a writer mid-commit, and check the follower is off by exactly
## the unacknowledged commit.
##
## This is the gate the whole watermark exists for, and it cannot be simulated
## by damaging a file afterwards: `.vhist` is fsynced *before* the graph merge
## and before the watermark is published, so the state under test is a live
## process that stopped existing inside that window. A child is SIGKILLed
## there (see `txn.crashHook`) and the parent asks three questions:
##
##   1. Was the window actually entered? (`.vhist` ahead of the watermark)
##   2. Does the follower show a commit the database does not have?
##   3. Is it short by exactly the one commit that was in flight?
##
## Question 1 is why this gate is worth more than a pass: if the crash never
## reached the window, the run proves nothing and says so.
##
## Question 2 is the safety property. A follower that invents a commit is
## worse than one that lags, because a lagging follower re-reads and a wrong
## one is believed.
##
## Run: `nimble crashFollower`

import std/[os, posix, times, strutils]

import ../../src/store/shm
import ../../src/store/vhist
import ../../src/store/follow
import ../../src/abi
import ../../src/store/prop
import ../../src/txn/txn
import ../../src/database

const
  ## Crash on the 5th arrival: four commits must land first, or
  ## "off by exactly one" is a claim about nothing.
  CrashPoint = "after-vhist-sync:5"
  Acked = 4

proc dbPath(): string =
  "tmp" / "crashfollow.glyph"

proc reset(path: string) =
  for suf in ["", "-wal", "-lock", "-shm", "-indexes", ".vhist"]:
    removeFile(path & suf)

proc childMain(path: string) =
  ## Commit `Acked` transactions normally, then commit one more that will be
  ## killed after its history frame is durable but before the watermark moves.
  let db = openDatabase(path, GLY_OPEN_CREATE)
  for i in 1 .. Acked:
    let tx = db.beginTransaction()
    discard tx.createNode("acked" & $i)
    discard db.commitTransaction(tx)
  let tx = db.beginTransaction()
  discard tx.createNode("doomed")
  discard db.commitTransaction(tx)        ## dies in here
  ## Unreachable, and that is the point: if the hook ever fails to fire, this
  ## line runs and the parent sees a whole commit instead of a crash.
  stderr.writeLine "CHILD SURVIVED THE CRASH POINT"

proc main() =
  reset(dbPath())

  let pid = posix.fork()
  if pid == 0:
    putEnv("GLYPHES_CRASH_AT", CrashPoint)
    childMain(dbPath())
    quit(1)

  var st: cint
  ## The child is mid-commit for a moment; wait for it properly.
  let deadline = epochTime() + 60.0
  var reaped = false
  while epochTime() < deadline and not reaped:
    if posix.waitpid(pid, st, posix.WNOHANG) == pid:
      reaped = true
    else:
      sleep(10)
  if not reaped:
    echo "FAIL: the child never exited"
    quit(1)

  let signalled = (st and 0x7f) != 0
  echo "child exited: signal ", (if signalled: 0x7f and st else: 0),
       (if signalled: " (SIGKILL expected)" else: " (clean exit -- WRONG)")
  if not signalled:
    echo "FAIL: the crash hook did not fire, so nothing was tested"
    quit(1)

  let path = dbPath()
  let wm = openShmReadOnly(path).loadGeneration()
  let allFrames = replayVhist(path, high(uint64), 0).frames
  echo "watermark generation: ", wm
  echo "frames in .vhist: ", allFrames.len, ", last stamped generation ",
       (if allFrames.len > 0: allFrames[^1].generation else: 0'u64)

  ## Was the window under test actually entered?
  if allFrames.len == 0:
    echo "FAIL: .vhist is empty; the crash never reached a commit"
    quit(1)
  if allFrames[^1].generation <= wm:
    echo "FAIL: .vhist is not ahead of the watermark, so the window was never"
    echo "      entered and this run proves nothing"
    quit(1)
  echo "OK: .vhist is ahead of the watermark -- the state under test exists"

  ## The follower, before anything else touches the directory. Opening a
  ## writer here would legitimately truncate the untrusted tail -- that is what
  ## a writer is *for* -- and would destroy the very evidence this gate checks
  ## the follower for not destroying. Order is the test.
  let f = openFollower(path)
  if f.unavailable != "":
    echo "FAIL: follower could not map the watermark: ", f.unavailable
    quit(1)
  discard f.refresh()
  echo "follower head (commit id): ", f.head, ", generation: ", f.generation

  var failures = 0
  ## The tail is still physically there, and it is the *same* tail: every
  ## frame that was present before the follower ran is present after. Checking
  ## only that *some* frames survive would miss a follower that truncated the
  ## untrusted tail down to the acknowledged commits -- the file would still
  ## hold frames, the check would pass, and the regression the comment claims
  ## to guard would sail through. So the guard is against the count from
  ## before the follower existed, not against zero.
  let tailSize = getFileSize(path & VhistSuffix)
  let framesAfter = replayVhist(path, high(uint64), 0).frames.len
  echo ".vhist size after following: ", tailSize, ", frames: ", framesAfter,
       " (was ", allFrames.len, ")"
  if tailSize <= 0:
    echo "FAIL: the untrusted tail was removed; a follower must not write"
    inc failures
  if framesAfter != allFrames.len:
    echo "FAIL: following changed the frame count from ", allFrames.len,
         " to ", framesAfter, " -- the follower altered the log it was"
    echo "      only meant to read"
    inc failures

  ## Safety: the follower stops at the watermark.
  if f.generation != wm:
    echo "FAIL: follower generation ", f.generation, " != watermark ", wm
    inc failures
  ## Exactness: short by exactly the in-flight commit, no more and no less.
  if f.head != Acked.uint64:
    echo "FAIL: follower saw ", f.head, " commits, expected ", Acked,
         " -- not off by exactly the unacknowledged commit"
    inc failures

  ## The independent cross-check: a writer recovering this database must keep
  ## exactly the same commits the follower showed. This compares *commit
  ## counts*, not generations -- those are different numbers that advance
  ## together, and reading one as the other is the mistake this test has
  ## already made twice.
  let db = openDatabase(path, GLY_OPEN_CREATE)
  let kept = db.store.history.commits.len
  close(db)
  echo "recovery kept: ", kept, " commits (watermark generation ", wm, ")"
  if kept != f.revisions.commits.len:
    echo "FAIL: recovery kept ", kept, " commits; the follower showed ",
         f.revisions.commits.len
    inc failures

  if failures == 0:
    echo "PASS: the follower is off by exactly the unacknowledged commit (",
         Acked, " of ", allFrames.len, " frames), shows no commit the database"
    echo "      does not have, and left the tail for its owner"
    quit(0)
  quit(1)

main()
