## glyphes — S1: the two-process write soak (gate SG1b)
##
## `soak_leak.nim` runs many threads in one process, which is the whole of
## what it proves about concurrency. S1 made the writer claim hold across
## *processes*, so this is the soak that has two: a parent and a child, each
## opening the same database, each writing in a loop, contending for the lock.
##
## What it asserts, and why each is a real failure mode rather than a
## formality:
##
##   * **No corruption.** Every writer's commit is either fully in the WAL or
##     not there. A writer that got in while another held the lock would show
##     up here as interleaved frames.
##   * **`GLY_ERR_BUSY` is the only refusal.** A writer is never left to
##     block forever, never half-admitted, and never refused with something
##     other than BUSY — which is `TXN.md` §1's contract, and a change in its
##     shape would be a change in the engine's behaviour under contention.
##   * **The final graph replays.** After every writer stops, a fresh recovery
##     yields a store whose invariants hold and whose node count matches the
##     number of successful commits.
##
## Run: `nim c -r tests/soak/soak_shared.nim [seconds]`
##   nimble soakShared 240         # a smoke run
##   nimble soakShared 43200       # 12 hours

import std/[times, os, posix, strutils, strformat]
import ../../src/store/store
import ../../src/store/prop
import ../../src/store/dblock
import ../../src/wal/wal
import ../../src/wal/recover
import ../../src/txn/txn

const
  ## Each writer creates this many nodes per transaction before committing,
  ## so a run makes progress rather than measuring lock traffic alone.
  Batch = 5

type
  Stats = object
    committed*: int
    busy*: int
    errors*: int

proc dbPathFor(tag: string): string =
  result = "tmp" / ("soak-shared-" & tag & ".glyph")

proc resetDb(path: string) =
  for suf in ["", "-wal", "-lock", "-indexes", ".vhist"]:
    removeFile(path & suf)

proc writerLoop(path: string, label: string, durationSec: int): Stats =
  ## One writer process. Each iteration takes the cross-process lock, opens
  ## or recovers, writes a batch, and commits. The lock is taken per
  ## transaction (the S4 shape) rather than held for the process life (the S1
  ## shape) because that is the harder case and the one that exercises
  ## contention: this soak would not be interesting if each writer held the
  ## lock once and never gave it up.
  let deadline = epochTime() + durationSec.float
  var committed, busy, errors = 0
  while epochTime() < deadline:
    let (lk, got) = tryAcquire(path)
    if not got:
      inc busy                     ## someone else has it; back off by yielding
      sleep(1)
      continue
    try:
      ## Recover every time, as a second process must: a store that does not
      ## replay the log before writing reuses node ids already in the file.
      let s = newStore()
      discard recover(path, s)
      let w = openWal(path & "-wal")
      let tx = begin(s, w, 1'u32, doSync = false)
      for i in 0 ..< Batch:
        let n = tx.createNode("Soak")
        discard tx.setNodeProp(n, "writer", Value(kind: vkString, s: label))
      if tx.commit():
        inc committed
      else:
        inc errors
      closeWal(w)
    except TxError as e:
      ## BUSY here would mean the intra-process atomic fired — possible only
      ## if something in this process also held it, which cannot happen with
      ## one writer per process. Anything else is a real error.
      if e.code == tcBusy:
        inc busy
      else:
        inc errors
    except CatchableError:
      inc errors
    lk.release()
  result = Stats(committed: committed, busy: busy, errors: errors)

# ------------------------------------------------------------------ child

proc childMain(path: string, label: string, durationSec: int) =
  ## The second writer, in its own process. Reports on stdout as a single
  ## line the parent parses.
  let st = writerLoop(path, label, durationSec)
  echo "CHILD committed=", st.committed, " busy=", st.busy, " errors=", st.errors
  quit(0)

if paramCount() >= 3 and paramStr(1) == "child":
  childMain(paramStr(2), paramStr(3), parseInt(paramStr(4)))

# ------------------------------------------------------------------- main

proc parseStats(line: string): Stats =
  for tok in line.splitWhitespace():
    let kv = tok.split('=')
    if kv.len != 2: continue
    case kv[0]
    of "committed": result.committed = parseInt(kv[1])
    of "busy": result.busy = parseInt(kv[1])
    of "errors": result.errors = parseInt(kv[1])
    else: discard

proc main() =
  let durationSec = if paramCount() > 0: parseInt(paramStr(1)) else: 240
  let path = dbPathFor("main")
  resetDb(path)

  echo "S1 two-process write soak — ", durationSec, "s, 2 writer processes"
  echo "  database: ", path
  echo ""

  ## Spawn the child writer, then run this process's writer alongside it.
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    quit("cannot create a pipe for the child writer")
  var argv: array[8, cstring]
  argv[0] = getAppFilename().cstring
  argv[1] = "child".cstring
  argv[2] = path.cstring
  argv[3] = "B".cstring
  argv[4] = ($durationSec & "\x00").cstring
  argv[5] = nil
  let pid = posix.fork()
  if pid == 0:
    discard posix.close(fds[0])
    discard posix.dup2(fds[1], 1)
    discard posix.close(fds[1])
    discard posix.execv(argv[0], cast[cstringArray](addr argv[0]))
    quit(127)
  discard posix.close(fds[1])

  ## This process is writer A. Same loop, same contention.
  let parentStats = writerLoop(path, "A", durationSec)

  ## Wait for the child and read its one-line report.
  var acc = newStringOfCap(64)
  var chunk: array[128, char]
  while true:
    let n = posix.read(fds[0], addr chunk[0], 128)
    if n <= 0: break
    for i in 0 ..< n: acc.add chunk[i]
  discard posix.close(fds[0])
  var st: cint
  discard posix.waitpid(pid, st, 0)
  let childStats = parseStats(acc)

  let totalCommitted = parentStats.committed + childStats.committed
  let totalBusy = parentStats.busy + childStats.busy
  let totalErrors = parentStats.errors + childStats.errors

  echo "writer A: committed=", parentStats.committed, " busy=", parentStats.busy, " errors=", parentStats.errors
  echo "writer B: committed=", childStats.committed, " busy=", childStats.busy, " errors=", childStats.errors
  echo ""
  echo "total: ", totalCommitted, " commits, ", totalBusy, " refusals, ", totalErrors, " errors"
  echo ""

  ## The invariant: no errors, and the graph replays to a consistent store
  ## whose node count is exactly the number of committed batches' nodes.
  var red = false
  let s = newStore()
  let recovery = recover(path, s)
  let nodeCount = s.nodeCount()
  let expectedNodes = totalCommitted * Batch
  echo "recovery: ", nodeCount, " nodes (expected ", expectedNodes,
       "), ", recovery.transactionsCommitted, " transactions replayed, lsn ", s.lastLsn

  if totalErrors > 0:
    echo "SG1b: RED — {totalErrors} non-BUSY errors during concurrent writes"
    red = true
  if nodeCount != expectedNodes:
    echo "SG1b: RED — recovered {nodeCount} nodes, expected {expectedNodes}; the WAL"
    echo "        does not replay to the set of successful commits"
    red = true
  ## Every store invariant must hold after concurrent writes.
  for inv in s.check():
    if not inv.ok:
      echo "SG1b: RED — invariant {inv.code}: {inv.detail}"
      red = true
  if red:
    quit(1)
  echo "SG1b: GREEN — ", totalCommitted, " commits across 2 processes, ", totalBusy,
       " refusals (all GLY_ERR_BUSY), 0 errors, graph replays clean."
  echo ""
  echo "  A non-zero refusal count is the lock working: two processes cannot"
  echo "  both write, so one of them waits. A zero refusal count would mean"
  echo "  the two processes never actually contended."

main()
