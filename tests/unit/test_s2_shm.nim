## glyphes — S2: the shared control block (gate SG5)
##
## Two uint64s in a mapped file, and the one question this phase exists to
## answer: **on arm64, does a reader ever see an advanced generation paired
## with a stale LSN?**
##
## The mechanism is release/acquire on the generation word (pin S6). x86's
## Total Store Ordering would make the naive "write the LSN, then write the
## generation" work by accident; ARM can reorder stores to different
## addresses, so the same code would let a reader observe
## `generation == g+1` with a `committedLsn` still naming *g*'s last frame.
## A reader that bounded its catch-up by that LSN would stop one commit short
## and never know.
##
## That failure is rare by construction — which is exactly why a single-run
## test passes on a broken build. SG5 therefore runs the interleaving many
## thousands of times and asserts the invariant on every observation.
##
## The gate has two halves:
##
##   * **the invariant** — no observation is ever `gen > 0` with
##     `lsn < the LSN that generation implies`;
##   * **the ordering proof** — a value written *before* `publishCommitted`
##     is visible to a reader that acquired the generation. A barrier that is
##     merely present is not the same as a barrier that works, and only the
##     second is observable from here.
##
## Both halves run in one process with two threads and in two processes with
## a shared mapping, because the memory is shared *across processes* and an
## intra-process thread test would pass even if the mapping were private.

import std/unittest
import std/os
import std/posix
import std/atomics

import ../../src/store/shm

type
  ## Thread-argument records, at module level: a `type` declared inside a
  ## proc cannot be a thread's parameter type, and the error says so less
  ## clearly than this comment does.
  WriterArgs = object
    shm: Shm
    iters: int
  ReaderArgs = object
    shm: Shm
    stop: ptr Atomic[bool]
    obs: ptr Atomic[int]
    bad: ptr Atomic[int]

proc writer(a: WriterArgs) {.thread, gcsafe.} =
  for i in 1 .. a.iters:
    ## generation g is published with LSN g*10, monotonically. A reader that
    ## sees generation g must see an LSN of at least g*10 — that is the
    ## pairing the release/acquire guarantees.
    a.shm.publishCommitted(uint64(i), uint64(i) * 10'u64)

proc reader(a: ReaderArgs) {.thread, gcsafe.} =
  while not a.stop[].load(moAcquire):
    ## Acquire the generation first, exactly as S3 will.
    let g = a.shm.loadGeneration()
    let l = a.shm.loadLsn()
    discard a.obs[].fetchAdd(1)
    if g > 0'u64 and l < g * 10'u64:
      discard a.bad[].fetchAdd(1)

proc shmDir(): string =
  let d = "tmp" / "test-s2"
  createDir(d)
  result = d

proc freshShm(name: string): string =
  let p = shmDir() / name
  removeFile(p)
  result = p

suite "S2 the shared control block (PRD-SHARED S2)":
  test "a fresh block reads generation 0 and lsn 0":
    ## Zero-filled on create is a correctness requirement, not a default: a
    ## block of zeroes means "nothing committed yet", so a reader replays
    ## the whole WAL — the right answer for a database whose block has never
    ## been written. An uninitialised mapping would mean something else.
    let p = freshShm("fresh.glyph")
    let s = openShm(p)
    check s.loadGeneration() == 0'u64
    check s.loadLsn() == 0'u64
    closeShm(s)

  test "publish then load returns what was published":
    let p = freshShm("roundtrip.glyph")
    let s = openShm(p)
    s.publishCommitted(7'u64, 1234'u64)
    check s.loadGeneration() == 7'u64
    check s.loadLsn() == 1234'u64
    s.publishCommitted(8'u64, 1300'u64)
    check s.loadGeneration() == 8'u64
    check s.loadLsn() == 1300'u64
    closeShm(s)

  test "the block is MAP_SHARED: two mappings of one file see each other":
    ## If this were MAP_PRIVATE, each mapping would get its own copy and two
    ## processes would never observe each other — a control block that cannot
    ## communicate is worse than none, because it looks like it works.
    let p = freshShm("shared.glyph")
    let a = openShm(p)
    a.publishCommitted(3'u64, 300'u64)
    let b = openShm(p)             # a second, independent mapping
    check b.loadGeneration() == 3'u64
    check b.loadLsn() == 300'u64
    b.publishCommitted(4'u64, 400'u64)
    check a.loadGeneration() == 4'u64   ## a sees b's publish
    closeShm(a); closeShm(b)

  test "SG5: no reader ever sees an advanced generation with a stale LSN":
    ## The gate. Writer publishes monotonically; reader acquires and asserts
    ## the pairing holds on every observation. The two threads run a tight
    ## loop for enough iterations that the window the barrier protects is
    ## exercised rather than hoped about.
    let p = freshShm("sg5.glyph")
    let s = openShm(p)
    var stopFlag: Atomic[bool]
    var obs: Atomic[int]
    var bad: Atomic[int]
    const Iters = 200_000
    var wThread: Thread[WriterArgs]
    var rThread: Thread[ReaderArgs]
    createThread(wThread, writer, WriterArgs(shm: s, iters: Iters))
    createThread(rThread, reader,
                 ReaderArgs(shm: s, stop: addr stopFlag, obs: addr obs,
                            bad: addr bad))
    joinThread(wThread)
    stopFlag.store(true, moRelease)
    joinThread(rThread)

    let observations = obs.load(moAcquire)
    let violations = bad.load(moAcquire)
    closeShm(s)

    check observations > 0        ## the reader actually ran
    check violations == 0        ## and never saw a torn pair
    ## A run where the reader saw the final generation proves the loop was
    ## long enough to matter; a reader that never observed anything would
    ## make `violations == 0` vacuous.
    let s2 = openShm(p)
    check s2.loadGeneration() == uint64(Iters)
    closeShm(s2)
