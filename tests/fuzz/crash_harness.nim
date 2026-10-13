## glyphes — the W1 crash gate (WAL.md §8).
##
## `kill -9` a deterministic importer at N random moments, then check that
## what came back is exactly a committed prefix of the schedule.
##
## ##1 This harness was written before the WAL existed, on purpose
##
## Its first run against the M1 store failed on every iteration, because
## a `kill -9` destroyed the whole in-memory graph. That is the correct
## failure and the reason to write the test first: a crash harness written
## after the durability code only exercises the paths its author already
## knew about, and this project's whole claim is the path the author did
## not think of — the process dying between the last mutation frame and
## its commit marker.
##
## ##2 What "correct" means here, precisely
##
## Three assertions per kill:
##
##   1. recovery completes without raising
##   2. the recovered graph is self-consistent (invariants S1-S10)
##   3. the recovered `marker.txn` equals k, and the graph contains
##      exactly the nodes and edges that schedule transaction k produced
##
## (3) is what makes this a gate rather than a smoke test, and it is
## possible only because the marker is written *inside* the transaction it
## describes. A marker file beside the graph would be one transaction
## behind whenever the process died in the window between the WAL fsync
## and the marker write, and every assertion built on it would have to
## carry that slop.
##
## Usage: crash_harness [kills] [ops] [opsPerTxn]

import std/os

import std/times
import std/random
import std/strutils
when defined(posix):
  import posix
import ../../src/store/store
import ../../src/wal/recover
import ../../src/wal/snapshot

const MarkerLabel = "Marker"

proc countNodes(store: GraphStore, label: string): int =
  let code = store.labels.lookup(label)
  if code == 0:
    return 0
  count(store.labelIndex, code)

proc markerTxn(store: GraphStore): int64 =
  ## The transaction index of the last durable commit, read out of the
  ## graph. -1 means the graph contains no marker at all, i.e. nothing
  ## committed.
  let code = store.labels.lookup(MarkerLabel)
  if code == 0:
    return -1
  var best: int64 = -1
  for id in members(store.labelIndex, code):
    var v: Value
    if store.getNodeProp(id, "txn", v) and v.kind == vkInt:
      if v.i > best:
        best = v.i
  best

type
  Outcome* = object
    killed*: bool
    recovered*: bool
    txn*: int64
    nodes*: int
    edges*: int
    invariantsOk*: bool
    firstBadInvariant*: string
    error*: string

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

proc fingerprint(s: GraphStore): string =
  ## Everything a reader can observe, in id order: label, endpoints, and
  ## every property with its value.
  ##
  ## This is what makes the oracle able to see a property that survived a
  ## kill when it should not have, or an edge that points at the wrong
  ## endpoint. Comparing node and edge *counts* — what this harness did
  ## first — would pass both: a prefix of the schedule and the full
  ## schedule can easily agree on how many records they hold while
  ## disagreeing on every value in them.
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

proc checkInvariants(store: GraphStore): tuple[ok: bool, detail: string] =
  for inv in store.check():
    if not inv.ok:
      return (false, inv.code & ": " & inv.detail)
  (true, "")

## Why fork/execve and not `osproc.startProcess`
##
## `sendSignal` takes a `Pid` and `osproc.Process` does not expose one.
## The alternatives were all worse: a pid file the child writes introduces
## a race the harness then has to poll around, and a shell wrapper (`sh -c
## 'echo $$; exec ...'`) puts a process between the harness and the child,
## so a SIGKILL aimed at the shell leaves the grandchild running and
## writing to the very file under test. Forking directly means the pid the
## harness kills is unambiguously the pid of the process doing the
## importing.
## `posix.execv`, not `execvpe`
##
## Nim's execv takes no envp, so the child inherits the harness's
## environment unchanged — which is what we want and is one fewer moving
## part. It also sidesteps C's `environ` and `execvpe`, both of which sit
## behind feature-test macros on Darwin.
proc spawnChild(exe: string, args: openArray[string]): Pid =
  ## `execv` wants a NULL-terminated `char**`. It is built in a plain
  ## local array rather than on the heap: the array lives in this frame,
  ## `fork` gives the child a copy-on-write image of the frame, and `execv`
  ## copies the strings into the new image before this process can return.
  ## Going through a heap allocation here instead produced argv entries
  ## that aliased each other, so the child silently read the same value
  ## for two different arguments.
  var argv: array[64, cstring]
  if args.len + 2 > argv.len:
    raise newException(ValueError, "spawnChild: too many arguments")
  argv[0] = exe.cstring
  for i, a in args:
    argv[i + 1] = a.cstring
  argv[args.len + 1] = nil
  let cargv = cast[cstringArray](addr argv[0])
  let pid = posix.fork()
  if pid == 0:
    ## The child branch. execv replaces the image, so nothing below it
    ## ever returns; the quit is only reached if exec itself failed, and
    ## it must not run Nim's runtime shutdown inside a forked child.
    discard posix.execv(exe.cstring, cargv)
    quit(127)
  pid

proc reapChild(pid: Pid) =
  var status: cint = 0
  discard posix.waitpid(pid, status, 0)

proc stillRunning(pid: Pid): bool =
  ## kill(pid, 0) is the portable "does this pid exist" probe. Returns
  ## false for a reaped child, which is how the harness tells "it finished
  ## before we could kill it" from "it was killed".
  when defined(posix):
    result = posix.kill(pid, 0) == 0

proc main() =
  let kills = if paramCount() > 0: parseInt(paramStr(1)) else: 100
  let ops = if paramCount() > 1: parseInt(paramStr(2)) else: 4000
  let opsPerTxn = if paramCount() > 2: parseInt(paramStr(3)) else: 20
  ## Scratch lives under the repo's own `tmp/` rather than the system temp
  ## dir, so a failed run leaves its files next to the build output where
  ## they can be inspected instead of being cleaned up out of reach.
  let work = "tmp/crash"
  createDir(work)
  let childExe = getEnv("GLYPHES_CRASH_CHILD")

  stderr.writeLine "W1: " & $kills & " kills, " & $ops & " ops, " &
    $opsPerTxn & " ops/txn"
  stderr.writeLine "    child: " & childExe

  var failures = 0
  var recoveries = 0
  var committedSeen = 0'u64
  var maxTxn = 0'i64

  # First: a clean run, so the harness knows what a complete import looks
  # like and how long it takes. Every kill delay is a fraction of this.
  let cleanPath = work / "clean.glyph"
  removeFile(cleanPath); removeFile(cleanPath & "-wal")
  let cleanStart = epochTime()
  reapChild(spawnChild(childExe, [cleanPath, "1", $ops, $opsPerTxn]))
  let cleanMs = int((epochTime() - cleanStart) * 1000)
  var cleanStore = newStore()
  discard recover(cleanPath, cleanStore)
  let cleanTxn = markerTxn(cleanStore)
  let cleanNodes = cleanStore.nodeCount()
  let cleanEdges = cleanStore.edgeCount()
  stderr.writeLine "    clean run: " & $cleanTxn & " txns, " & $cleanNodes &
    " nodes, " & $cleanEdges & " edges in " & $cleanMs & " ms"

  var rng = initRand(int64(epochTime().int64))

  for attempt in 0 ..< kills:
    let path = work / ("kill" & $attempt & ".glyph")
    removeFile(path); removeFile(path & "-wal")
    # A delay drawn from a log-ish spread: most kills land early (the
    # interesting window, while the WAL is small and no snapshot exists
    # yet) and a few land late (after a checkpoint, so recovery has to
    # combine snapshot + tail).
    let attemptSeed = rng.rand(9999) + 1
    let frac = rng.rand(1000).float64 / 1000.0
    let delayMs = max(2, int(frac * frac * cleanMs.float64))
    let pid = spawnChild(childExe,
      [path, $attemptSeed, $ops, $opsPerTxn])
    sleep(delayMs)
    let wasRunning = stillRunning(pid)
    if wasRunning:
      discard posix.kill(pid, posix.SIGKILL)
    reapChild(pid)
    if not wasRunning:
      # It finished before we could kill it; that is a wasted round, not a
      # failure, but it means the delay spread was too wide.
      continue

    var store = newStore()
    var outcome: Outcome
    outcome.killed = true
    try:
      let rec = recover(path, store)
      outcome.recovered = true
      inc recoveries
      let (ok, detail) = checkInvariants(store)
      outcome.invariantsOk = ok
      outcome.firstBadInvariant = detail
      outcome.txn = markerTxn(store)
      outcome.nodes = store.nodeCount()
      outcome.edges = store.edgeCount()
      if outcome.txn >= 0:
        inc committedSeen
        maxTxn = max(maxTxn, outcome.txn)
      else:
        # Nothing committed is a legitimate outcome for a very early kill,
        # but it must be *empty*, not partially populated.
        if store.nodeCount() != 0 or store.edgeCount() != 0:
          stderr.writeLine "  FAIL attempt " & $attempt & ": no marker but " &
            $store.nodeCount() & " nodes survived"
          inc failures
      discard rec
    except CatchableError as e:
      outcome.error = e.msg

    if outcome.error.len > 0:
      stderr.writeLine "  FAIL attempt " & $attempt & " (kill at " &
        $delayMs & "ms): recovery raised: " & outcome.error
      inc failures
    elif not outcome.invariantsOk:
      stderr.writeLine "  FAIL attempt " & $attempt & ": invariant " &
        outcome.firstBadInvariant
      inc failures
    elif outcome.txn > cleanTxn:
      stderr.writeLine "  FAIL attempt " & $attempt & ": recovered txn " &
        $outcome.txn & " exceeds the clean run's " & $cleanTxn
      inc failures
    elif outcome.txn >= 0:
      ## The exact check, from WAL.md W1: recovery must land on the last
      ## *committed* transaction, so the recovered graph has to be
      ## byte-for-byte the graph a clean run of the **same seed** produces
      ## at that transaction. Comparing against the harness's own clean
      ## run does not work — that run uses seed 1 and each killed run uses
      ## its own seed, so the two are different graphs and the comparison
      ## only ever measured the seeds disagreeing.
      let oraclePath = work / ("oracle" & $attempt & ".glyph")
      removeFile(oraclePath); removeFile(oraclePath & "-wal")
      reapChild(spawnChild(childExe,
        [oraclePath, $attemptSeed, $(outcome.txn * opsPerTxn), $opsPerTxn]))
      var oracleStore = newStore()
      discard recover(oraclePath, oracleStore)
      let oracleTxn = markerTxn(oracleStore)
      removeFile(oraclePath); removeFile(oraclePath & "-wal")
      ## The comparison is the whole observable graph, not its summary:
      ## two graphs can agree on every count while differing in values,
      ## and "exactly the last committed transaction" is a claim about
      ## bytes, not about arithmetic.
      let wantFp = fingerprint(oracleStore)
      let gotFp = fingerprint(store)
      if oracleTxn != outcome.txn or wantFp != gotFp:
        ## First differing line, so the failure names the record rather
        ## than reporting two opaque fingerprints.
        var detail = "identical"
        for i in 0 ..< max(wantFp.len, gotFp.len):
          let a = if i < wantFp.len: wantFp[i] else: '\0'
          let b = if i < gotFp.len: gotFp[i] else: '\0'
          if a != b:
            let lineA = wantFp[0 ..< min(i + 1, wantFp.len)]
            let lineB = gotFp[0 ..< min(i + 1, gotFp.len)]
            detail = "want " & $(lineA.splitLines()[^1]) & " got " &
              $(lineB.splitLines()[^1])
            break
        stderr.writeLine "  FAIL attempt " & $attempt & " (seed " &
          $attemptSeed & "): recovered txn " & $outcome.txn &
          " differs from the same-seed oracle at txn " & $oracleTxn &
          ": " & detail
        inc failures

  stderr.writeLine ""
  stderr.writeLine "kills attempted : " & $kills
  stderr.writeLine "recoveries      : " & $recoveries
  stderr.writeLine "committed seen  : " & $committedSeen & " (max txn " & $maxTxn & ")"
  stderr.writeLine "clean run       : " & $cleanTxn & " txns, " &
    $cleanNodes & " nodes, " & $cleanEdges & " edges"
  if failures == 0 and recoveries > 0:
    stderr.writeLine ""
    stderr.writeLine "W1: GREEN"
  else:
    stderr.writeLine ""
    stderr.writeLine "W1: RED (" & $failures & " failures)"
  quit(if failures == 0 and recoveries > 0: 0 else: 1)

main()
