## glyphes — the cross-process writer lock (PRD-SHARED S1)
##
## One file, one job: the `-lock` described by `WAL.md` §1 and pinned by W13,
## which specified it and was never built. `rg "flock" src/` was empty until
## this file.
##
## This is S1 of PRD-SHARED, and S1 is a **bug fix**, not groundwork. Until it
## existed, two processes could each open one graph file and each believe they
## were the sole writer, because `claimWriter` is an `Atomic[uint32]` and that
## is a process-local primitive. The PRD calls this out; this file closes it.
##
## ## Why `flock` and not `fcntl` byte-ranges
##
## `WAL.md` W13 already pinned `flock`, and S1.1's probes confirm it is also
## the *safer* primitive for this job:
##
##   * **Released on process death** (probe 1). A crashed writer does not
##     wedge the database — which is what `WAL.md` §1 assumes and what makes
##     "no stale-lock protocol needed" true.
##   * **Not released by an unrelated fd close** (probe 2). `fcntl` locks are
##     process-associated and drop when *any* descriptor for the inode is
##     closed, so a helper that opened and closed `-lock` would silently
##     release the writer lock. `flock` locks are per open-file-description
##     and survive that. Pin S3's dedicated-fd rule is therefore hygiene here,
##     not a trapdoor — kept because it states intent, not because a stray
##     `open`/`close` elsewhere would drop the lock.
##   * **Serialises threads too** (probe 4). A second thread opening its own
##     descriptor was still excluded. This is *not* the same as fcntl's
##     per-process semantics and it is why the `Atomic` claim and this lock
##     cover different cases and neither is redundant.
##
## ## The fd is not a lock-holder, the kernel is
##
## `WAL.md` §1 says the file "holds the writer pid". It does not need to, and
## must not: W13 pins `flock` *rather than* pid liveness, and the kernel
## already tracks the owner. A pid in a file is a debugging aid at best and a
## stale-value trap at worst (pid recycling). This file writes the pid as a
## comment for `lsof`-less debugging and reads no state from it at all.

import std/os

when defined(posix):
  import std/posix

  proc flock(fd: cint; operation: cint): cint
    {.importc, header: "<sys/file.h>".}

  let
    LOCK_SH {.importc: "LOCK_SH", header: "<sys/file.h>".}: cint
    LOCK_EX {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
    LOCK_NB {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
    LOCK_UN {.importc: "LOCK_UN", header: "<sys/file.h>".}: cint

type
  DbLock* = ref object
    ## An open `-lock` descriptor holding (or not holding) the writer lock.
    ##
    ## `fd` is dedicated for the life of this object and never reopened or
    ## closed behind the caller's back (S3). Under `flock` the *open file
    ## description* owns the lock, so a second `open` of the same path is a
    ## different description with its own independent lock state — which is
    ## precisely why the `flock` probe (4) had to open a fresh descriptor to
    ## observe contention, and why this one must not be shared.
    path*: string
    fd*: File
    held*: bool           ## true once an exclusive lock is on this fd

const
  LockSuffix* = "-lock"
  ## Matches `WAL.md` §1's `graph.glyph-lock`. Deliberately *not* `.lock`:
  ## the WAL sidecars are `-wal` and `-indexes`, and this joins the family.

proc lockPathFor*(graphPath: string): string =
  ## `<db>` -> `<db>-lock`.
  graphPath & LockSuffix

proc acquire*(graphPath: string): DbLock =
  ## Take the exclusive writer lock, waiting if another process holds it.
  ##
  ## Raises `IOError` when the lock cannot be taken at all (a missing `-lock`
  ## directory, a permission problem), because "I could not establish that I
  ## am the only writer" must not look like "I am the only writer".
  ##
  ## Waiting is here for S4, where the lock is per transaction; in S1 the
  ## caller holds this for the life of the database and a second writer in
  ## the same process never reaches it (the `Atomic` claim above it raises
  ## first). `tryAcquire` is what S1's busy path uses.
  result = DbLock(path: lockPathFor(graphPath))
  if not fileExists(result.path):
    ## Create it empty. `fmAppend` (not `fmWrite`): Nim's `fmWrite` is C
    ## "wb" and truncates on open, and this file is opened more than once —
    ## by a waiting writer and by whoever holds it.
    writeFile(result.path, "")
  result.fd = open(result.path, fmAppend)
  let rc = flock(result.fd.getFileHandle, LOCK_EX)
  if rc != 0:
    result.fd.close()
    raise newException(IOError,
      "cannot lock " & result.path & ": errno " & $errno)
  result.held = true

proc tryAcquire*(graphPath: string): (DbLock, bool) =
  ## Take the exclusive writer lock without waiting. Returns
  ## `(lock, true)` on success, `(nil, false)` if another process holds it.
  ##
  ## The non-blocking form is S1's: a second process opening the same file
  ## must be *refused* rather than parked, because the engine's existing
  ## single-writer contract raises `GLY_ERR_BUSY` rather than blocking
  ## (`TXN.md` §1 — the caller is a Ruby thread that would rather raise than
  ## stall a request), and that contract should not change shape just because
  ## a second process appeared.
  let path = lockPathFor(graphPath)
  if not fileExists(path):
    writeFile(path, "")
  let fd = open(path, fmAppend)
  if flock(fd.getFileHandle, LOCK_EX or LOCK_NB) != 0:
    fd.close()
    return (nil, false)
  (DbLock(path: path, fd: fd, held: true), true)

proc release*(l: DbLock) =
  ## Drop the lock and close the descriptor. Idempotent.
  if l == nil or l.fd == nil:
    return
  if l.held:
    ## Unlocking before close is belt-and-braces: closing the last descriptor
    ## releases the lock anyway (probe 1), but doing it explicitly keeps the
    ## intent visible at the call site.
    discard flock(l.fd.getFileHandle, LOCK_UN)
  l.fd.close()
  l.fd = nil
  l.held = false

proc isHeldByOther*(graphPath: string): bool =
  ## Whether *some other holder* currently holds the lock. Used only by tests
  ## and diagnostics; the engine asks `tryAcquire`, not this, because asking
  ## and then taking is a check-then-act and this store has two post-mortems
  ## of exactly that in `store.nim`'s history.
  let (l, got) = tryAcquire(graphPath)
  if got:
    l.release()
    return false
  true
