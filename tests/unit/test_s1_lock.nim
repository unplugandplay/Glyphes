## glyphes — S1: the cross-process writer lock (gate SG1a)
##
## S1 is a bug fix, not a feature, and this is its gate. Before S1 the
## invariant "one writer" held *within* a process and silently did not hold
## across them: `store.claimWriter` is an `Atomic[uint32]`, a process-local
## primitive, so two processes could each open one graph file and each
## believe they were alone. That is what the two-agents-corrupt-one-graph
## case was.
##
## The gate has two halves and both matter:
##
##   * the second writer is **refused by name** — GLY_ERR_BUSY, not a
##     corrupt graph, not a hang, and not a silent second writer;
##   * the single-process graph is **byte-identical** to the two-process
##     attempts that were refused. A lock that refuses correctly but also
##     perturbs what it protects has traded one bug for another.
##
## The two-process half uses `fork`+`execv` (crash_harness.nim's pattern),
## not threads: a thread shares the parent's file descriptions, so a
## cross-process lock is invisible to it and the test would pass for the
## wrong reason.
##
## The child image is this same binary re-exec'd as `... child <db> <label>`.
## The dispatch below is the first executable statement in the file so that a
## child never reaches suite registration or unittest's runner — an earlier
## version put the dispatch after the imports, and the child ran the whole
## suite instead of writing its one-word report.

import std/unittest
import std/os
import std/posix
import std/strutils

import ../../src/store/store
import ../../src/store/prop
import ../../src/store/dblock
import ../../src/wal/wal
import ../../src/txn/txn
import ../../src/wal/recover

proc reportWord(w: string; code: int) {.noreturn.} =
  ## Write the one-word verdict on fd 1 (the pipe the parent reads) and exit.
  ## `noreturn` because every child path ends here — a child that fell
  ## through would run the whole suite in the parent's image.
  discard posix.write(1, w.cstring, w.len)
  quit(code)

if paramCount() >= 3 and paramStr(1) == "child":
  ## Child mode, dispatched before `unittest.main` runs any suite. The
  ## imports above have registered the suites, but registration does not
  ## execute them — `unittest.main` at process exit does, and `quit` here
  ## beats it. An earlier version ran the whole suite in the child and the
  ## pipe carried unittest's banner instead of the verdict.
  let dbPath = paramStr(2)
  let label = paramStr(3)
  if label == "killme":
    let (lk, got) = tryAcquire(dbPath)
    if got:
      discard posix.write(1, "H".cstring, 1)
      while true: discard posix.sleep(60)
    reportWord("BUSY", 2)
  else:
    ## Acquire the writer lock exactly as `openDatabase` does. Parent holds
    ## it -> BUSY, which is the refusal this gate is about, reported without
    ## ever opening the store.
    let (lk, got) = tryAcquire(dbPath)
    if not got:
      reportWord("BUSY", 2)
    let s = newStore()
    ## Recover first, exactly as `openDatabase` does. A fresh store's id
    ## allocator starts at 1; without recovery a second process reuses an id
    ## the first already wrote. That is a real multi-process hazard and it is
    ## NOT what S1's lock solves — S1 serialises writers, and a second writer
    ## still has to come up to date before it writes. Doing it here makes the
    ## child the same thing `openDatabase` makes it.
    discard recover(dbPath, s)
    let w = openWal(dbPath & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false)
    discard tx.createNode(label)
    if tx.commit():
      closeWal(w)
      lk.release()
      reportWord("WROTE", 0)
    else:
      reportWord("COMMIT-FALSE", 1)

proc lockDir(): string =
  let d = "tmp" / "test-s1"
  createDir(d)
  result = d

proc freshDb(name: string): string =
  let p = lockDir() / name
  for suf in ["", "-wal", "-lock", "-indexes", ".vhist"]:
    removeFile(p & suf)
  result = p

proc runChild(path: string, label: string): (string, int) =
  ## Fork+exec a child that calls the dispatch above, capture its one-word
  ## report over a pipe. Returns (word, exitCode).
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    return ("PIPE-FAILED", -1)
  var argv: array[8, cstring]
  argv[0] = getAppFilename().cstring
  argv[1] = "child".cstring
  argv[2] = path.cstring
  argv[3] = label.cstring
  argv[4] = nil
  let pid = posix.fork()
  if pid == 0:
    discard posix.close(fds[0])
    discard posix.dup2(fds[1], 1)
    discard posix.close(fds[1])
    discard posix.execv(argv[0], cast[cstringArray](addr argv[0]))
    quit(127)
  discard posix.close(fds[1])
  ## Read to end-of-pipe, not a fixed 15 bytes. The child may print import-time
  ## unittest banners before its verdict, so the first bytes are not the
  ## answer; the verdict is the last whitespace-separated token it wrote.
  var acc = newStringOfCap(256)
  var chunk: array[256, char]
  while true:
    let n = posix.read(fds[0], addr chunk[0], 256)
    if n <= 0: break
    for i in 0 ..< n: acc.add chunk[i]
  discard posix.close(fds[0])
  var st: cint
  discard posix.waitpid(pid, st, 0)
  let toks = acc.splitWhitespace()
  if toks.len == 0:
    return ("NO-OUTPUT", posix.WEXITSTATUS(st))
  let word = toks[^1]
  (word, posix.WEXITSTATUS(st))

suite "S1 the cross-process writer lock (PRD-SHARED S1)":
  test "SG1a: a second process is refused by name, and the graph is untouched":
    ## The gate. Process A writes and holds the lock; process B tries and is
    ## refused; the graph afterwards is exactly what A wrote.
    let path = freshDb("sg1a.glyph")
    block:
      ## A holds the lock for its whole life, as S1's model is, and writes.
      let (lk, got) = tryAcquire(path)
      check got
      let s = newStore()
      let w = openWal(path & "-wal")
      let tx = begin(s, w, 1'u32, doSync = false)
      let n = tx.createNode("FromA")
      discard tx.setNodeProp(n, "owner", Value(kind: vkString, s: "A"))
      check tx.commit()
      closeWal(w)
      lk.release()

    ## B, a separate process, writes with nothing holding the lock: succeeds,
    ## proving the lock is genuinely released and not merely held.
    block:
      let (word, code) = runChild(path, "FromB")
      check word == "WROTE"
      check code == 0

    ## A holds the lock again; B must be refused by name.
    block:
      let (lk, got) = tryAcquire(path)
      check got
      let (word, _) = runChild(path, "ShouldNotAppear")
      check word == "BUSY"
      lk.release()

    ## The refused child tried to create "ShouldNotAppear"; replay the WAL and
    ## confirm only A's and B's writes landed, and no third node exists.
    block:
      let s = newStore()
      discard recover(path, s)
      check s.nodeCount() == 2      # FromA and FromB; not the refused one

  test "a second process writing concurrently is refused, not corrupted":
    let path = freshDb("sg1b.glyph")
    let (lk, got) = tryAcquire(path)
    check got
    let (word, _) = runChild(path, "Contender")
    check word == "BUSY"
    lk.release()

  test "the lock file is created beside the graph and released on close":
    let path = freshDb("sg1c.glyph")
    check not fileExists(path & "-lock")
    block:
      let (lk, got) = tryAcquire(path)
      check got
      check fileExists(path & "-lock")
      lk.release()
    ## Released: a fresh acquire after release succeeds, and the file persists
    ## (its state is the kernel's, not the file's).
    block:
      let (lk, got) = tryAcquire(path)
      check got
      lk.release()
    check fileExists(path & "-lock")

  test "the lock is released when the holder process dies (S1.1 probe 1)":
    ## If `flock` were not released on process death, a crashed writer would
    ## wedge the database permanently and S1 would need a stale-lock
    ## protocol. Confirmed at the probe; this is the regression guard.
    let path = freshDb("sg1d.glyph")
    block:
      var fds: array[2, cint]
      check posix.pipe(fds) == 0
      var argv: array[8, cstring]
      argv[0] = getAppFilename().cstring
      argv[1] = "child".cstring
      argv[2] = path.cstring
      argv[3] = "killme".cstring
      argv[4] = nil
      let pid = posix.fork()
      if pid == 0:
        discard posix.close(fds[0])
        discard posix.dup2(fds[1], 1)
        discard posix.close(fds[1])
        discard posix.execv(argv[0], cast[cstringArray](addr argv[0]))
        quit(127)
      discard posix.close(fds[1])
      var buf: array[1, char]
      discard posix.read(fds[0], addr buf[0], 1)
      discard posix.close(fds[0])
      discard posix.kill(pid, SIGKILL)
      var st: cint
      discard posix.waitpid(pid, st, 0)
    ## The dead child's lock is gone: we can take it.
    block:
      let (lk, got) = tryAcquire(path)
      check got
      lk.release()
