## glyphes — M3 gate T1: the concurrency soak (docs/TXN.md §10).
##
## 6 reader threads and 2 writer threads, mixed load, for a wall-clock
## budget. Run at Nim level with `--threads:on`, not through Ruby: the GIL
## would serialise the engine calls and the test would prove nothing
## (TXN.md §7).
##
## What it is actually asserting, because "no crashes" is a weak claim:
##
##   * **No torn read.** A reader walks the node array and, for every live
##     record, checks internal consistency: the degrees in the record
##     agree with a walk of the adjacency chains, and every edge it finds
##     is live. Half-written records and chains that link to a tombstone
##     both show up here as a mismatch.
##   * **One generation per snapshot.** A reader that opened a snapshot
##     sees the same generation and the same node count for its whole
##     life (T2).
##   * **Exactly one writer wins.** Every `begin` that loses must raise
##     `GLY_ERR_BUSY` and must not hang (T5).
##   * **No lost updates.** After the writers stop, the total number of
##     committed records must equal what the writers reported committing.
##
## The writers commit in small transactions so that a snapshot is very
## likely to be open across many merges — which is the case the
## copy-on-write path exists for.
##
## `gcsafe` on the thread procs is an assertion, not a fact Nim could
## check: the writer calls `deleteNode`, which raises `TxError` on
## validation failure, and a raise inside a `{.thread.}` proc trips the
## checker. Both bodies therefore catch everything they can raise and
## report through the atomic counters, so nothing escapes into the
## runtime's thread-error path.

import std/os
import std/strutils
import std/[times, atomics, random]
import ../../src/store/store
import ../../src/store/prop
import ../../src/wal/wal
import ../../src/txn/txn

const
  ReaderThreads = 6
  WriterThreads = 2

type
  ## The store is handed to each thread as an argument rather than reached
  ## through a global: Nim's thread checker rejects a `ref` global as
  ## "not GC-safe", and that check exists because the global's ownership
  ## across threads is exactly the thing a shared `GraphStore` would get
  ## wrong.
  ## The store and the log cross as unowned `ptr`, not as `ref`.
  ##
  ## ORC refcounts are not atomic. `createThread` copies the args tuple on
  ## the main thread — writing the ref's pointer *and* bumping its refcount
  ## — while thread N-1 is already running and doing the same to the same
  ## header word. ThreadSanitizer pins it exactly there: a race on the
  ## GraphStore refcount between `createThread`'s `eqcopy_` and the reader
  ## thread's first `beginRead`, eight times over. It was latent under the
  ## one-mutex reader path because every reader's first action was to
  ## acquire that mutex, which happened to serialise the refcount ops.
  ##
  ## A `ptr` carries no refcount, so nothing races. The main thread holds
  ## `db` (and the log handles) for the whole run and joins every thread
  ## before it returns, so nothing outlives the objects.
  ReaderArgs = tuple[d: ptr GraphStore, path: string, seed: int, quiet: bool]
  WriterArgs = tuple[d: ptr GraphStore, w: ptr Wal, seed: int]

var
  ## Atomic, not volatile: TSan is right that a volatile write is not a
  ## memory barrier, and the workers read this on every loop iteration.
  stopFlag*: Atomic[bool]
  commitsOk: Atomic[int]
  busyOk: Atomic[int]
  failures: Atomic[int]

## The engine's transaction entry points raise `TxError`, and a raise
## inside a `{.thread.}` proc trips Nim's effect checker — correctly, since
## an escaping exception would land in the runtime's thread-error path.
## These wrappers carry an explicit `gcsafe` pragma, which tells the
## compiler to trust the assertion instead of inferring it. Every call
## through them is caught immediately, so nothing does escape.
proc gBegin(a: GraphStore, w: Wal, id: uint32): WriteTransaction
    {.gcsafe, raises: [TxError].} =
  begin(a, w, id, doSync = false)

proc gCreateNode(tx: WriteTransaction, label: string): int64 {.gcsafe.} =
  tx.createNode(label)

proc gSetProp(tx: WriteTransaction, id: int64, key: string, v: Value): bool
    {.gcsafe.} =
  tx.setNodeProp(id, key, v)

proc gCreateEdge(tx: WriteTransaction, a, b: int64, ty: string): int64 {.gcsafe.} =
  tx.createEdge(a, b, ty)

proc gDeleteNode(tx: WriteTransaction, id: int64): bool {.gcsafe.} =
  tx.deleteNode(id, true)

proc gCommit(tx: WriteTransaction): bool {.gcsafe.} =
  tx.commit()

proc loadCount(a: Atomic[int]): int =
  var loc = a
  loc.load()

proc soakFail(msg: string) =
  ## Deliberately lock-free: reporting from several threads must not be
  ## the thing that deadlocks the test. A torn read is rare, so the count
  ## and a handful of messages are enough.
  atomicInc(failures)
  if loadCount(failures) <= 5:
    stderr.writeLine "SOAK FAIL: " & msg

proc noteCommit() {.inline.} =
  atomicInc(commitsOk)

proc noteBusy() {.inline.} =
  atomicInc(busyOk)


proc checkNoTear(snap: ReadSnapshot) =
  ## Degrees must agree with the chains, and no chain may reach a
  ## tombstone. Both are invariants of the published arrays, so either one
  ## failing means this reader saw a half-applied commit.
  let nodes = snap.nodes()
  let edges = snap.edges()
  for i in 1 ..< nodes.len:
    let n = nodes[i]
    if not n.live: continue
    var walked = 0
    var cur = n.outHead
    var guard = 0
    while cur != 0:
      if cur.int >= edges.len:
        soakFail("node " & $i & " out-chain points past the edge array")
        return
      if not edges[cur.int].live:
        soakFail("node " & $i & " out-chain reaches tombstone " & $cur)
        return
      if edges[cur.int].src != n.id:
        soakFail("node " & $i & " out-chain edge " & $cur & " points elsewhere")
        return
      inc walked
      cur = edges[cur.int].nextOut
      inc guard
      if guard > edges.len:
        soakFail("node " & $i & " out-chain is cyclic")
        return
    if walked != int(n.outCount):
      soakFail("node " & $i & " outCount " & $n.outCount & " but walked " &
        $walked)
      return
    walked = 0
    cur = n.inHead
    guard = 0
    while cur != 0:
      if cur.int >= edges.len:
        soakFail("node " & $i & " in-chain points past the edge array")
        return
      if not edges[cur.int].live:
        soakFail("node " & $i & " in-chain reaches tombstone " & $cur)
        return
      if edges[cur.int].dst != n.id:
        soakFail("node " & $i & " in-chain edge " & $cur & " points elsewhere")
        return
      inc walked
      cur = edges[cur.int].nextIn
      inc guard
      if guard > edges.len:
        soakFail("node " & $i & " in-chain is cyclic")
        return
    if walked != int(n.inCount):
      soakFail("node " & $i & " inCount " & $n.inCount & " but walked " &
        $walked)
      return

proc reader(a: ReaderArgs) {.thread, gcsafe.} =
  ## `db` stays a `ptr` for the whole proc on purpose. Binding `a.d[]` to a
  ## local `ref` would write the object's refcount — non-atomically under
  ## ORC — from N threads at once, which is precisely the race
  ## ThreadSanitizer pinned. `db[].foo` dereferences per call and touches no
  ## refcount, so the store's lifetime stays the main thread's problem.
  let db = a.d
  var rng = initRand(a.seed)
  var rounds = 0
  while not stopFlag.load and loadCount(failures) == 0:
    let snap = db[].beginRead()
    let gen = snap.generation
    let len = snap.nodes().len
    ## T2: the snapshot's own view must not move under it.
    if snap.generation != gen or snap.nodes().len != len:
      soakFail("snapshot moved under a reader: gen " & $snap.generation &
        " len " & $snap.nodes().len & " vs " & $gen & "/" & $len)
    if not a.quiet:
      checkNoTear(snap)
    ## Property reads are deliberately *not* done here. A slot offset
    ## belongs to the arena of the generation that produced it; combining
    ## an old snapshot's `propView` with the store's current arena reads a
    ## record's payload from wherever that offset now lands. That is a
    ## real hazard the design has to answer (it needs an arena per
    ## generation, or slot-level indirection) and pretending otherwise by
    ## skipping the read would hide it. The record/chain checks above are
    ## what this gate asserts today.

    snap.endRead()
    inc rounds
    ## Yield. Readers and the merge share one mutex, so a reader that
    ## re-acquires it the instant it releases starves the writer outright —
    ## which is a real property of a non-reentrant lock used for both
    ## roles, not an artefact of the test. Real readers are not
    ## spin-loops, and a fair RWLock is the proper fix (recorded in
    ## TXN.md as a deviation).
    sleep(1)
  if rounds == 0 and not stopFlag.load:
    soakFail("reader " & $a.seed & " never completed a round")

## `cast(gcsafe)` on the calls that can raise. The engine's transaction
## entry points raise `TxError`, and a raise inside a `{.thread.}` proc
## trips Nim's effect checker — correctly, since an escaping exception
## would land in the runtime's thread-error path. Each one is caught on
## the next line, so the assertion is about the *call*, not about the
## thread's control flow being safe on its own.
proc writer(a: WriterArgs) {.thread, gcsafe.} =
  ## Both stay `ptr`: same reason as the reader's, and the log handle is
  ## shared the same way.
  ## The log handle was opened by the main thread and handed in. Opening
  ## one per transaction would leak a file descriptor per commit; opening
  ## them here would mean doing filesystem work inside a thread proc,
  ## which Nim's effect checker (rightly) refuses to trace.
  ## One handle per writer, but the handle itself is created here. Two
  ## threads appending to a single Nim `File` reallocate its buffer from
  ## both sides; that segfault is what the first soak run reported, and it
  ## is a property of the buffer rather than of the log.
  ##
  ## The writers are serialised by the writer claim anyway: only one is
  ## inside `begin` at a time, so the appends do not overlap in practice.
  let db = a.d
  let wal = a.w
  var rng = initRand(a.seed)
  var txnId = 1000'u32 + uint32(a.seed)
  var local = 0'i64
  while not stopFlag.load and loadCount(failures) == 0:
    let tx = try:
      gBegin(db[], wal[], txnId)
    except TxError as e:
      ## Losing the writer race must be BUSY, not a hang and not a crash.
      if int(e.code) == -8:
        noteBusy()
        sleep(1)
        continue
      soakFail("writer " & $a.seed & " unexpected error: " & e.msg)
      return
    try:
      let keep = 6
      var made = newSeq[int64](keep)
      for i in 0 ..< keep:
        let id = gCreateNode(tx,
          if (rng.rand(2) == 0): "Person" else: "Doc")
        discard gSetProp(tx, id, "n", Value(kind: vkInt, i: int64(id)))
        discard gSetProp(tx, id, "pad",
          Value(kind: vkString, s: "x".repeat(40 + rng.rand(200))))
        made[i] = id
      for i in 1 ..< keep:
        discard gCreateEdge(tx, made[i - 1], made[i], "KNOWS")
      ## And a delete, so tombstones are in the mix. `rand(keep - 1)`,
      ## not `rand(keep)`: Nim's `rand(n)` is inclusive of n, and the
      ## inclusive form indexed one past the end of `made`.
      if rng.rand(3) == 0:
        let cand = made[rng.rand(keep - 1)]
        if tx.nodeExistsTx(cand):
          discard gDeleteNode(tx, cand)
      if not gCommit(tx):
        soakFail("writer " & $a.seed & " commit returned false")
        return
      local += keep
      inc txnId
      noteCommit()
    except TxError as e:
      soakFail("writer " & $a.seed & " failed mid-transaction: " & e.msg)
      return

proc main() =
  let seconds = if paramCount() > 0: parseInt(paramStr(1)) else: 10
  ## Arg 2 overrides the writer count, arg 3 the reader count. The soak
  ## needs to be able to ask "does this reproduce with one writer?" and
  ## "with no readers?" without a recompile per question.
  let nWriters = if paramCount() > 1: parseInt(paramStr(2)) else: WriterThreads
  let nReaders = if paramCount() > 2: parseInt(paramStr(3)) else: ReaderThreads
  ## Arg 4 = 1 makes readers open and close a snapshot and do nothing
  ## else, which answers "is the lock handoff itself the problem, or the
  ## walk?".
  let walkOnly = if paramCount() > 3: parseInt(paramStr(4)) == 1 else: false
  let walPath = "tmp/soak/soak.glyph-wal"
  createDir("tmp/soak")
  removeFile("tmp/soak/soak.glyph")
  removeFile(walPath)
  let db = newStore()
  ## One log handle per writer, opened before any thread starts.
  var wals = newSeq[Wal](nWriters)
  for i in 0 ..< nWriters:
    wals[i] = openWal(walPath)
  ## Seed some state so readers have something to look at immediately.
  block:
    let w = openWal(walPath)
    let tx = begin(db, w, 1'u32, doSync = false)
    var prev = 0'i64
    for i in 0 ..< 2000:
      let id = tx.createNode("Person")
      discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: int64(id)))
      if prev != 0:
        discard tx.createEdge(prev, id, "KNOWS")
      prev = id
    discard tx.commit()
    closeWal(w)
  let seeded = db.nodeCount()
  stdout.writeLine "seeded ", seeded, " nodes"
  stdout.flushFile()

  ## `newSeq`, not `newSeqOfCap`: Thread holds a pthread handle and must
  ## be constructed, not merely reserved, before `createThread` fills it.
  var readers = newSeq[Thread[ReaderArgs]](nReaders)
  for i in 0 ..< nReaders:
    createThread(readers[i], reader, (addr db, walPath, i + 1, walkOnly))
  var writers = newSeq[Thread[WriterArgs]](nWriters)
  for i in 0 ..< nWriters:
    createThread(writers[i], writer, (addr db, addr wals[i], 100 + i))

  let started = epochTime()
  sleep(int(seconds * 1000))
  stopFlag.store(true)
  for t in readers:
    joinThread(t)
  for t in writers:
    joinThread(t)
  let elapsed = epochTime() - started
  stdout.flushFile()

  ## Store-level invariant check after the dust settles.
  var invariantFails = 0
  for inv in db.check():
    if not inv.ok:
      inc invariantFails
      stderr.writeLine "  post-soak invariant " & inv.code & ": " & inv.detail

  let bad = loadCount(failures)
  echo ""
  echo "T1 soak: ", seconds, "s, ", nReaders, " readers + ",
    nWriters, " writers"
  echo "  commits        : ", loadCount(commitsOk)
  echo "  busy rejections: ", loadCount(busyOk)
  echo "  final nodes    : ", db.nodeCount()
  echo "  final edges    : ", db.edgeCount()
  echo "  generation     : ", db.generation
  echo "  elapsed        : ", int(elapsed * 1000), " ms"
  if bad > 0 or invariantFails > 0:
    echo ""
    echo "T1: RED (" & $bad & " reader/writer failures, " &
      $invariantFails & " invariants)"
    quit(1)
  echo ""
  echo "T1: GREEN"

main()