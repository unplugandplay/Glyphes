## glyphes — S1.1: what `flock` actually does here (PRD-SHARED S1.1)
##
## Four questions about the kernel, answered by the kernel. Each one is a
## question about the platform rather than about the design, and S1 is built
## on top of the answers — so they are asked before S1 exists, not after.
##
## These are probes, not the test suite. They print what they find; S1's
## unit tests then assert the answers that S1 depends on. The split matters:
## a test that re-derives the answer and a probe that reports it answer
## different questions, and only one of them tells you the answer changed.
##
## Run: `nim c -r tests/lock/lockprobe.nim`

import std/os
import std/posix
import std/strutils
import std/locks

when not defined(posix):
  {.error: "lockprobe is POSIX-only: it is about flock(2) and fork(2)".}

proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}

# `flock(2)` and its `LOCK_*` constants are not bound by Nim's std/posix on
# any platform. They are imported here rather than hardcoded because the
# values are the platform's, not ours, and a probe about what the kernel
# does is the last place to assume an ABI.
let
  LOCK_SH* {.importc: "LOCK_SH", header: "<sys/file.h>".}: cint
  LOCK_EX* {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
  LOCK_NB* {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
  LOCK_UN* {.importc: "LOCK_UN", header: "<sys/file.h>".}: cint

proc lockPath(): string =
  result = "tmp" / "lockprobe.lock"
  createDir("tmp")

## --- 1. is the lock released when the process dies? ------------------------
##
## `WAL.md` §1 says a stale lock is detected "via `flock` (OS-released on
## process death) rather than pid liveness, because pid recycling makes pid
## checks unsafe". If the OS does not release it, a crashed writer wedges the
## database until someone removes the file by hand — and S1's design changes,
## because it would need a stale-lock protocol.
proc probeProcessDeath(path: string): string =
  ## A child takes an exclusive lock and is killed without unlocking. The
  ## parent then tries the same lock: if the kernel released it on death, the
  ## parent's try succeeds.
  var argv: array[8, cstring]
  argv[0] = getAppFilename().cstring
  argv[1] = "child-hold".cstring
  argv[2] = path.cstring
  argv[3] = nil
  let pid = posix.fork()
  if pid == 0:
    let f = open(path, fmAppend)
    discard flock(f.getFileHandle, LOCK_EX)
    ## Signal the parent that the lock is held, then wait to be killed.
    discard posix.write(1, "H".cstring, 1)
    ## Sleep forever; the parent SIGKILLs us.
    while true: discard posix.sleep(60)
  ## Parent: wait for the child's "H", then kill it hard.
  var buf: array[1, char]
  discard posix.read(0, addr buf[0], 1)
  discard kill(pid, SIGKILL)
  var status: cint
  discard posix.waitpid(pid, status, 0)
  ## Now the dead child's lock must be gone.
  let f = open(path, fmAppend)
  let got = flock(f.getFileHandle, LOCK_EX or LOCK_NB)
  f.close()
  if got == 0:
    "released on process death (as WAL.md 1 assumes)"
  else:
    "NOT released on process death — a crashed writer would wedge the db"

## --- 2. is the lock released when ANY fd for the file is closed? -----------
##
## This is the one that changes the design. POSIX `fcntl` byte-range locks
## are *process*-associated and are released when *any* descriptor for that
## inode is closed — so a helper that opened and closed the lock file would
## silently drop the writer lock. BSD/Linux `flock` locks are per
## *open-file-description*, so an unrelated close must not release them.
##
## If this answers "released", S3's dedicated-fd rule stops being hygiene
## and becomes load-bearing: nothing anywhere may open `-lock` and close it.
proc probeFdClose(path: string): string =
  let keeper = open(path, fmAppend)
  discard flock(keeper.getFileHandle, LOCK_EX)
  ## Open a second, independent descriptor to the same file and close it.
  let other = open(path, fmAppend)
  other.close()
  ## If the lock survived, a *different* process still cannot take it. We
  ## cannot spawn a process without the fd dance, so test it the way the
  ## design depends on it: can a second, independent open+flock succeed?
  let second = open(path, fmAppend)
  let got = flock(second.getFileHandle, LOCK_EX or LOCK_NB)
  second.close()
  keeper.close()
  if got == 0:
    "closing another fd RELEASED the lock (per-process like fcntl) — " &
    "the dedicated-fd rule is load-bearing"
  else:
    "closing another fd did NOT release it (per-open-file-description, " &
    "like flock should be) — dedicated fd is hygiene, not a trapdoor"

## --- 3. do two processes see the same lock? -------------------------------
##
## This is the one S1 is actually about. Two *separate* processes — not
## threads, not two fds in one process — contend for the same file. If the
## lock were per-process (which `fcntl` is), both would succeed and S1 would
## be built on sand.
proc probeTwoProcesses(path: string): string =
  ## Two genuinely separate processes contending for one file. The pipe is
  ## what carries the answer, and `execv` is what makes the child a separate
  ## image: a bare `fork` shares the parent's open file descriptions, so a
  ## lock the parent holds via an inherited description is invisible to the
  ## child trying a *new* one — which would answer "excluded" for the wrong
  ## reason and prove nothing about cross-process exclusion.
  ##
  ## The first version of this probe read the answer from fd 0 while the
  ## child wrote it to fd 1, with no pipe between them, and reported a
  ## cross-process exclusion failure that was entirely its own plumbing.
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    return "could not create a pipe; probe inconclusive"
  var argv: array[8, cstring]
  argv[0] = getAppFilename().cstring
  argv[1] = "child-try".cstring
  argv[2] = path.cstring
  argv[3] = nil
  let pid = posix.fork()
  if pid == 0:
    ## Child: wire the pipe write end to fd 1, exec, and let the new image do
    ## the work. `execv` copies argv into the new image before this process
    ## can return, so building it on the stack here is safe (crash_harness
    ## .nim:160 says the same).
    discard posix.close(fds[0])
    discard posix.dup2(fds[1], 1)
    discard posix.close(fds[1])
    discard posix.execv(argv[0], cast[cstringArray](addr argv[0]))
    quit(127)
  ## Parent: hold the lock *before* the child tries it.
  discard posix.close(fds[1])
  let mine = open(path, fmAppend)
  discard flock(mine.getFileHandle, LOCK_EX)
  ## The child reports 'B' if it was excluded, 'A' if it got in.
  var buf: array[1, char]
  discard posix.read(fds[0], addr buf[0], 1)
  var status: cint
  discard posix.waitpid(pid, status, 0)
  discard posix.close(fds[0])
  mine.close()
  if buf[0] == 'B':
    "a second process is EXCLUDED while one holds it (correct)"
  else:
    "a second process got IN while one held it — the lock is per-process " &
    "and S1 would be built on sand"

## --- 4. does it compose with threads? -------------------------------------
##
## A lock held by one thread and contended by another *in the same process*.
## `flock` semantics here are the ones most likely to surprise, and S1 keeps
## the existing `Atomic` claim alongside the `flock` precisely because the
## two cover different axes — this probe is why that is not redundant.
var thrAttempt: Thread[tuple[p: string, res: ptr bool]]

proc attemptLock(a: tuple[p: string, res: ptr bool]) {.thread, gcsafe.} =
  ## A second thread in this process opening its own descriptor and trying
  ## the same exclusive lock. `createThread` copies the args tuple on the
  ## main thread, so the pointer is taken there and shared read-write here
  ## for one join — the soak's idiom.
  let g = open(a.p, fmAppend)
  a.res[] = flock(g.getFileHandle, LOCK_EX or LOCK_NB) == 0
  g.close()

proc probeThreads(path: string): string =
  let f = open(path, fmAppend)
  discard flock(f.getFileHandle, LOCK_EX)
  ## From another thread in this process, does a try-acquire on an
  ## independent descriptor succeed? Per-open-file-description locks are
  ## held per description, so a *second* open in the same process gets its
  ## own description and — with LOCK_NB — should fail, because this process
  ## holds an EX on the file. If it succeeds, the lock does not serialise
  ## threads at all and the Atomic claim is not optional.
  var gotOk = false
  createThread(thrAttempt, attemptLock, (p: path, res: addr gotOk))
  joinThread(thrAttempt)
  f.close()
  if gotOk:
    "a second thread in the SAME process got in — flock does not " &
    "serialise threads here, so the Atomic claim is mandatory"
  else:
    "a second thread was excluded — flock also serialises threads"

# ------------------------------------------------------------------ child

proc childHold(path: string) =
  let f = open(path, fmAppend)
  discard flock(f.getFileHandle, LOCK_EX)
  discard posix.write(1, "H".cstring, 1)
  while true: discard posix.sleep(60)

proc childTry(path: string) =
  let f = open(path, fmAppend)
  let got = flock(f.getFileHandle, LOCK_EX or LOCK_NB)
  discard posix.write(1, (if got == 0: "A" else: "B").cstring, 1)
  quit(0)

# ------------------------------------------------------------------ main

proc main() =
  if paramCount() >= 2:
    case paramStr(1)
    of "child-hold": childHold(paramStr(2)); return
    of "child-try": childTry(paramStr(2)); return
    else: discard
  let p = lockPath()
  removeFile(p)
  echo "S1.1 — four questions about flock(2) on this platform"
  echo "  (", hostCPU, ", ", hostOs, ")"
  echo ""
  echo "1. released on process death?  ", probeProcessDeath(p)
  echo "2. released on an unrelated fd close?  ", probeFdClose(p)
  echo "3. two processes excluded?  ", probeTwoProcesses(p)
  echo "4. serialises threads?  ", probeThreads(p)
  echo ""
  echo "S1 assumes 1=yes (WAL.md 1), 3=yes (the whole feature). 2 and 4"
  echo "shape whether the dedicated-fd rule and the Atomic claim are hygiene"
  echo "or load-bearing."

main()
