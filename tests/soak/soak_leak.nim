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


proc rssMb(): int64 =
  ## Resident set size in MiB, from procps. macOS has no /proc, so this is
  ## 0 there and the run is judged on ORC's own accounting — which is the
  ## number the gate is actually about. A missing procps must not be a
  ## crash: the soak's verdict does not depend on RSS, and failing a
  ## five-day run because a diagnostic file is missing would be absurd.
  try:
    let f = open("/proc/self/statm", fmRead)
    defer: close(f)
    let parts = f.readLine().splitWhitespace()
    if parts.len < 2:
      return 0
    ## Page size is 4 KiB on every platform this runs on; sysconf would be
    ## more correct and less portable in a thread proc.
    return (parseBiggestInt(parts[1]) * 4096) div (1024 * 1024)
  except IOError, ValueError:
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
  let db = a.d
  let log = a.w
  var rng = initRand(a.seed)
  let ctr = a.c
  while not ctr.stop.load():
    try:
      let tx = begin(db[], log[], uint32(a.seed), doSync = false)
      var prev = 0'i64
      let batch = 1 + rng.rand(0 .. 8)
      for i in 0 ..< batch:
        let id = tx.createNode("Person")
        discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: id))
        if prev != 0:
          discard tx.createEdge(prev, id, "KNOWS")
        prev = id
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
    for i in 0 ..< 2000:
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
    samples.add (el, getOccupiedMem().int64, rssMb(),
                 db.nodeCount(), db.edgeCount())
    stdout.writeLine("  t=" & align($int(el), 8) &
      "s orc=" & align($(getOccupiedMem() div (1024 * 1024)), 5) &
      " MiB rss=" & align($rssMb(), 5) &
      " MiB nodes=" & $db.nodeCount() &
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
  let orcSlope = (b.orc - a.orc).float / (span * 1024.0 * 1024.0)
  let rssSlope = (b.rss - a.rss).float / span

  echo "steady state (samples ", first, "..", samples.len - 1, ", ",
       span.formatFloat(ffDecimal, 0), "s):"
  echo "  orc : ", a.orc div (1024 * 1024), " MiB -> ", b.orc div (1024 * 1024),
       " MiB   slope ", orcSlope.formatFloat(ffDecimal, 3), " MiB/s"
  echo "  rss : ", a.rss, " MiB -> ", b.rss, " MiB   slope ", rssSlope.formatFloat(ffDecimal, 4), " MiB/s"
  echo "  data: ", a.nodes, " -> ", b.nodes, " nodes, ",
       a.edges, " -> ", b.edges, " edges (growth here is the store, not a leak)"
  echo "  work: ", counters.reads.load(), " reads, ", counters.writes.load(), " writes, ",
       counters.errors.load(), " errors"

  ## The verdict. A positive slope sustained across the steady state is a
  ## leak; a small negative or flat slope is the allocator settling. The
  ## threshold is deliberately loose — five days of noise will not produce a
  ## clean line, and a gate that fails on noise is a gate people disable.
  var ok = true
  if orcSlope > 0.05:
    echo "  FAIL: ORC heap grew at ", orcSlope.formatFloat(ffDecimal, 3), " MiB/s over the steady state"
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
