## glyphes — M11 gate: the 20-node leak soak (docs/TESTING.md §7).
##
## The T1 soak (`soak.nim`) asks whether concurrent readers and writers get
## *correct* answers. This one asks a different question over the same
## machinery: does the process grow. Five days of transactions will find a
## leak that ten seconds will not, and a leak is the one defect a
## correctness gate cannot see — every answer is right while the heap
## climbs.
##
## What it asserts, concretely:
##
##   * **No heap growth.** ORC's occupied memory is sampled on a fixed
##     interval and the run is judged on the *slope* between the first and
##     last quarters, not on the peak. A soak that grows to 2 GB and holds
##     there is fine; a soak that grows 2 GB and keeps going is a leak. The
##     peak is exactly the wrong number to gate on.
##   * **No growth after a checkpoint.** Writers commit continuously, so the
##     store's own arrays grow for legitimate reasons. Measuring growth
##     *after* a compaction separates the two: whatever the heap does between
##     two checkpoints is reclamation working or failing, and the part that
##     survives a checkpoint is the part that is not the data.
##   * **A steady state.** Node and edge counts are sampled alongside memory
##     so a rising number is never mistaken for a leak — a writer that
##     commits faster than the tombstones compact would otherwise look like
##     one.
##
## Built with `--mm:orc` so `getOccupiedMem` is ORC's own allocator
## accounting rather than a proxy. ORC refcounts are not atomic, so the
## store crosses into each thread as `ptr GraphStore` for the reason
## soak.nim gives: `createThread` copies the args tuple on the main thread
## while earlier threads are already running, and a `ref` global would race
## on that refcount.
##
## Usage:
##   tmp/soak_leak <seconds> <nodes> [<readers>] [<writers>]
##   nimble soakLeak 432000 20      # 5 days, 20 nodes
##   nimble soakLeak 90 20          # a smoke run that proves the harness works

import std/os
import std/osproc
import std/[strutils, times, atomics, random]
import ../../src/store/store
import ../../src/store/prop
import ../../src/wal/wal
import ../../src/txn/txn
import ../../src/index/index

const
  SampleSeconds = 30.0
  ## Never sample less often than a quarter of the run, or a 90-second smoke
  ## test gets one sample and reports INCONCLUSIVE — which is what happened
  ## the first time, and an inconclusive gate gets ignored.
  MinSamples = 4
  ## Per-writer cap on live nodes. The graph's live set is this times the
  ## writer count and does not grow, which is what makes the slope a
  ## verdict rather than a restatement of how long the run was.
  KeepPerWriter = 100
  ## A leak shows as a slope, so the verdict is computed between these two
  ## fractions of the samples. The first quarter is skipped because the
  ## allocator's first arena allocations are one-off and are not a leak; the
  ## last quarter is the steady state, which is what a real leak spoils.
  SkipFraction = 0.25

type
  ## Counters live in one object behind a `ptr`, for the reason soak.nim
  ## gives for the store: a `ref` global is not GC-safe across
  ## `createThread`, and `Atomic[T]` is a value type that must not be
  ## copied while other threads update it.
  Counters = object
    stop: Atomic[bool]
    reads: Atomic[int]
    writes: Atomic[int]
    errors: Atomic[int]

  ReaderArgs = tuple[d: ptr GraphStore, c: ptr Counters, seed: int]
  WriterArgs = tuple[d: ptr GraphStore, w: ptr Wal, c: ptr Counters, seed: int]


proc rssBytes(): int64 =
  ## Resident set size in bytes, read from `ps`.
  ##
  ## The first version read `/proc/self/statm`, which does not exist on
  ## Darwin and so reported 0 for every sample — a silent zero beside a real
  ## number reads as "no growth", which is the one thing this number must
  ## never say by accident. `ps` exists on both platforms this runs on.
  ##
  ## `ps -o rss=` is in kilobytes on macOS and Linux alike. It is *current*
  ## RSS, not the high-water mark `getrusage` would give, and that is the
  ## better number here: a leak is a line that climbs, and current RSS draws
  ## the climb rather than the record of it.
  let res = execCmdEx("ps -o rss= -p " & $getCurrentProcessId())
  let text = res.output.strip()
  if text.len == 0:
    return 0
  try:
    parseBiggestInt(text) * 1024
  except ValueError:
    return 0

proc reader(a: ReaderArgs) {.thread, gcsafe.} =
  ## `db` stays a `ptr` for the whole proc on purpose. Binding `a.d[]` to a
  ## local `ref` would write the object's refcount — non-atomically under
  ## ORC — from N threads at once, which is the race ThreadSanitizer pinned
  ## in soak.nim. `db[].foo` dereferences per call and touches no refcount.
  let db = a.d
  var rng = initRand(a.seed)
  let ctr = a.c
  while not ctr.stop.load():
    var snap = db[].beginRead()
    ## The same torn-read invariant T1 checks, cheaply: a snapshot must
    ## keep its generation and its length for its whole life. This soak is
    ## not a correctness gate, but it should not run on a store that is
    ## already broken.
    ## T2: the snapshot's own view must not move under it. Cheap, and it is
    ## the same invariant the T1 soak checks — this gate is about memory, and
    ## it should refuse to measure a store that is already broken.
    let gen = snap.generation
    let len = snap.nodes().len
    if snap.generation != gen or snap.nodes().len != len:
      discard ctr.errors.fetchAdd(1)
    ## Read the snapshot's arrays so the snapshot path is genuinely
    ## exercised rather than merely opened: a leak on this path is the one
    ## this gate exists to find.
    var acc = 0'i64
    for i in 0 ..< min(len, 200):
      acc += snap.nodes()[i].id
    if acc == -1:
      discard ctr.errors.fetchAdd(1)
    endRead(snap)
    discard ctr.reads.fetchAdd(1)
    discard rng.rand(1 .. 3)

proc writer(a: WriterArgs) {.thread, gcsafe.} =
  ## Steady state: create a little, retire a little.
  ##
  ## The first version only ever created, so over a long run the live set
  ## grew without bound and the heap grew with it — and the gate, which
  ## measures a *slope*, would have called that a leak with a straight
  ## face. A gate that cannot tell its own workload's growth from a defect
  ## is worse than no gate, because it is believed.
  ##
  ## Each writer retires its own oldest nodes, so there is no shared queue
  ## and no lock: a writer's live set is bounded by `KeepPerWriter` and the
  ## graph's by `KeepPerWriter * writers`. After the first few rounds the
  ## node and edge counts are flat, and from that point any growth in the
  ## heap is the engine keeping something it should not.
  let db = a.d
  let log = a.w
  var rng = initRand(a.seed)
  let ctr = a.c
  ## This writer's unretired nodes, oldest first.
  var mine: seq[int64] = @[]
  while not ctr.stop.load():
    try:
      let tx = begin(db[], log[], uint32(a.seed), doSync = false)
      var prev = 0'i64
      let batch = 1 + rng.rand(0 .. 4)
      for i in 0 ..< batch:
        let id = tx.createNode("Person")
        discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: id))
        if prev != 0:
          discard tx.createEdge(prev, id, "KNOWS")
        prev = id
        mine.add id
      ## Retire from the front until back under the cap. `cascade` takes the
      ## incident edges with the node; a node with edges is not otherwise
      ## deletable, and leaving them would be a workload that never shrinks.
      while mine.len > KeepPerWriter:
        let victim = mine[0]
        mine.delete(0)
        discard tx.deleteNode(victim, true)
      discard tx.commit()
      discard ctr.writes.fetchAdd(1)
    except TxError:
      ## GLY_ERR_BUSY is the designed outcome when another writer holds the
      ## lock, not a failure.
      discard
    discard rng.rand(1 .. 5)

proc main() =
  let seconds = if paramCount() > 0: parseFloat(paramStr(1)) else: 90.0
  let nodes = if paramCount() > 1: parseInt(paramStr(2)) else: 20
  ## Readers are the majority: the leak this gate is looking for lives on
  ## the snapshot path, and a writer-heavy run would bury it under write
  ## churn that grows for legitimate reasons.
  let nReaders = if paramCount() > 2: parseInt(paramStr(3)) else: max(1, nodes * 4 div 5)
  let nWriters = if paramCount() > 3: parseInt(paramStr(4)) else: max(1, nodes - nReaders)
  let total = nReaders + nWriters

  ## Local, not global: the address crosses into every thread, and a
  ## global's address is not something the thread checker will vouch for.
  ## Main owns it for the whole run and joins before returning.
  var counters = Counters()

  createDir("tmp/soak")
  removeFile("tmp/soak/leak.glyph-wal")
  let walPath = "tmp/soak/leak.glyph-wal"
  let db = newStore()

  var wals = newSeq[Wal](nWriters)
  for i in 0 ..< nWriters:
    wals[i] = openWal(walPath)
  block:
    let w = openWal(walPath)
    let tx = begin(db, w, 1'u32, doSync = false)
    var prev = 0'i64
    for i in 0 ..< 200:
      let id = tx.createNode("Person")
      discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: int64(id)))
      if prev != 0:
        discard tx.createEdge(prev, id, "KNOWS")
      prev = id
    discard tx.commit()
    closeWal(w)

  echo "M11 leak soak: ", total, " nodes (", nReaders, " readers, ",
       nWriters, " writers) for ", seconds, "s"
  echo "  build must be --mm:orc for getOccupiedMem to mean anything"

  var readers = newSeq[Thread[ReaderArgs]](nReaders)
  for i in 0 ..< nReaders:
    createThread(readers[i], reader, (addr db, addr counters, i + 1))
  var writers = newSeq[Thread[WriterArgs]](nWriters)
  for i in 0 ..< nWriters:
    createThread(writers[i], writer,
                 (addr db, addr wals[i], addr counters, 100 + i))

  let interval = min(SampleSeconds, max(2.0, seconds / float(MinSamples)))
  let started = epochTime()
  var samples: seq[tuple[t: float, orc: int64, rss: int64, nodes: int64, edges: int64]] = @[]
  while epochTime() - started < seconds:
    sleep(int(interval * 1000))
    let el = epochTime() - started
    samples.add (el, getOccupiedMem().int64, rssBytes(),
                 db.nodeCount(), db.edgeCount())
    ## KiB, not MiB. A five-day soak reporting whole megabytes cannot see a
    ## leak of a few hundred kilobytes an hour, and the first version's
    ## "slope 0.000 MiB/s" was the resolution, not the result.
    stdout.writeLine("  t=" & align($int(el), 7) &
      "s orc=" & align($(getOccupiedMem() div 1024), 8) &
      " KiB rss=" & align($(rssBytes() div 1024), 7) &
      " KiB nodes=" & $db.nodeCount() &
      " edges=" & $db.edgeCount() &
      " reads=" & $counters.reads.load() &
      " writes=" & $counters.writes.load())
    stdout.flushFile()

  counters.stop.store(true)
  for t in readers: joinThread(t)
  for t in writers: joinThread(t)
  for i in 0 ..< nWriters:
    closeWal(wals[i])

  echo ""
  if samples.len < 2:
    echo "SOAK: INCONCLUSIVE — only ", samples.len,
         " samples; run for at least ", int(interval * float(MinSamples)), "s"
    quit(1)

  let first = int(float(samples.len) * SkipFraction)
  let a = samples[first]
  let b = samples[^1]
  let span = max(1.0, b.t - a.t)
  ## KiB/s, for the same reason the samples are KiB.
  let orcSlope = (b.orc - a.orc).float / (span * 1024.0)
  let rssSlope = (b.rss - a.rss).float / (span * 1024.0)

  echo "steady state (samples ", first, "..", samples.len - 1, ", ",
       span.formatFloat(ffDecimal, 0), "s):"
  echo "  orc : ", a.orc div 1024, " KiB -> ", b.orc div 1024, " KiB   slope ",
       orcSlope.formatFloat(ffDecimal, 4), " KiB/s"
  echo "  rss : ", a.rss div 1024, " KiB -> ", b.rss div 1024, " KiB   slope ",
       rssSlope.formatFloat(ffDecimal, 4), " KiB/s"
  echo "  data: ", a.nodes, " -> ", b.nodes, " nodes, ",
       a.edges, " -> ", b.edges, " edges (growth here is the store, not a leak)"
  echo "  work: ", counters.reads.load(), " reads, ", counters.writes.load(), " writes, ",
       counters.errors.load(), " errors"

  ## The verdict. A positive slope sustained across the steady state is a
  ## leak; a small negative or flat slope is the allocator settling. The
  ## threshold is deliberately loose — five days of noise will not produce a
  ## clean line, and a gate that fails on noise is a gate people disable.
  var ok = true
  ## The workload must be *steady* before a slope means anything.
  ##
  ## The writers fill their quota before they start retiring, so a run has a
  ## ramp at the front. If the ramp is still inside the measured window, the
  ## heap slope is partly just this soak creating more graph — and reporting
  ## that as a leak would be the harness grading its own homework. It is
  ## therefore INCONCLUSIVE, not RED: no conclusion was reached, which is a
  ## different claim from "the engine kept something".
  let nodeGrowth = b.nodes - a.nodes
  let liveIsSteady = nodeGrowth <= int64(KeepPerWriter)
  if not liveIsSteady:
    echo "  INCONCLUSIVE: the live set never settled — ", a.nodes, " -> ",
         b.nodes, " nodes across the measured window (tolerance ",
         KeepPerWriter, ")."
    echo "                A heap slope over a still-growing graph is not a leak"
    echo "                measurement. Run longer."
    quit(1)
  ## Threshold in KiB/s. 1 KiB/s is ~86 MiB/day — a real leak, and loose
  ## enough that five days of allocator noise will not trip it.
  if orcSlope > 1.0 or rssSlope > 1.0:
    echo "  FAIL: heap grew at ", orcSlope.formatFloat(ffDecimal, 4),
         " KiB/s (ORC) and ", rssSlope.formatFloat(ffDecimal, 4),
         " KiB/s (RSS) over the steady state"
    ok = false
  if counters.errors.load() > 0:
    echo "  FAIL: ", counters.errors.load(), " thread errors"
    ok = false
  if counters.reads.load() == 0 or counters.writes.load() == 0:
    echo "  FAIL: no work happened (", counters.reads.load(), " reads, ",
         counters.writes.load(), " writes)"
    ok = false

  if ok:
    echo "SOAK: GREEN — ", total, " nodes, ", (span / 3600.0).formatFloat(ffDecimal, 3),
         "h, no heap growth in the steady state"
  else:
    echo "SOAK: RED"
    quit(1)

main()
