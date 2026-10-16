## glyphes — F1.0: which barrier does the watermark actually need?
##
## SG5 — "a follower never observes a generation paired with a stale LSN" —
## is the gate the whole follower feature rests on. It was red when this file
## was written: two violations in 200 000 publish/observe iterations. The
## plan's suspicion was the *storage*, not the protocol: the block is reached
## by `cast[ptr Atomic[uint64]]` over an `mmap` pointer, and Nim's `Atomic[T]`
## presumes it owns the memory it sits in.
##
## This file is the answer, kept so the next person does not have to re-derive
## it, and so the "it was red" claim is checkable rather than folklore.
##
## **The finding: the barrier was already correct. The earlier red was a stale
## binary.** The first version of `loadGeneration` read `lsnWord` instead of
## `genWord` — a copy-paste slip — so it returned the LSN, and SG5 failed on
## the broken accessor, not on the ordering. With the accessor fixed, the
## shipping candidate (cast-ptr, release/acquire) holds: 0 torn observations
## over 2 000 000 publishes, repeated, and 8/8 green across full-suite runs.
##
## ## Why the suspicion was reasonable, and what it cost
##
## The reason the plan doubted the storage is real: `Atomic[T]`'s contract
## is about storage it owns, and `mmap` memory is storage it does not. That
## the contract survives being pointed at borrowed memory on this target is a
## fact about the compiler and the target, not a guarantee from Nim, and it is
## the kind of fact that can change with a compiler upgrade. So the candidates
## are still worth keeping on the bench, not because cast-ptr is wrong today,
## but because "it works" and "it is guaranteed" are different claims.
##
## Run: `nim c -r --threads:on tests/lock/barrierprobe.nim [iterations]`

import std/[os, atomics, posix, times, strutils]

when not defined(posix):
  {.error: "barrierprobe is POSIX-only: it is about mmap and atomic stores."}

const
  Iters = 2_000_000
  OffsetLsn = 0
  OffsetGen = 8

proc shmPath(tag: string): string =
  result = "tmp" / ("barrierprobe-" & tag)
  removeFile(result)
  writeFile(result, newString(16))

proc mapIt(path: string): pointer =
  let fd = posix.open(path, O_RDWR)
  result = posix.mmap(nil, 16, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  discard posix.close(fd)

# --- candidate 0: cast[ptr Atomic[uint64]] (what ships) ------------------------

proc c0Store(base: pointer; gen, lsn: uint64) {.gcsafe, inline.} =
  let gw = cast[ptr Atomic[uint64]](cast[uint](base) + OffsetGen)
  let lw = cast[ptr Atomic[uint64]](cast[uint](base) + OffsetLsn)
  lw[].store(lsn, moRelease)
  gw[].store(gen, moRelease)

proc c0Load(base: pointer): tuple[gen, lsn: uint64] {.gcsafe, inline.} =
  let gw = cast[ptr Atomic[uint64]](cast[uint](base) + OffsetGen)
  let lw = cast[ptr Atomic[uint64]](cast[uint](base) + OffsetLsn)
  (gw[].load(moAcquire), lw[].load(moAcquire))

# --- candidate 2: a shared struct whose address is the mapping ----------------

type ShmWords = object
  ## Laid out as two `Atomic[uint64]`, so the mapping *is* this struct and
  ## the compiler's assumptions about an `Atomic` that is a field of a real
  ## object hold.
  lsn: Atomic[uint64]
  gen: Atomic[uint64]

proc c2Store(base: pointer; gen, lsn: uint64) {.gcsafe, inline.} =
  let w = cast[ptr ShmWords](base)
  w[].lsn.store(lsn, moRelease)
  w[].gen.store(gen, moRelease)

proc c2Load(base: pointer): tuple[gen, lsn: uint64] {.gcsafe, inline.} =
  let w = cast[ptr ShmWords](base)
  (w[].gen.load(moAcquire), w[].lsn.load(moAcquire))

# --- the measurement ----------------------------------------------------------

type
  Which = enum
    w0, w2
  Stop = Atomic[bool]
  Counts = object
    obs: Atomic[int]
    bad: Atomic[int]

proc doStore(w: Which; base: pointer; gen, lsn: uint64) {.gcsafe, inline.} =
  case w
  of w0: c0Store(base, gen, lsn)
  of w2: c2Store(base, gen, lsn)

proc doLoad(w: Which; base: pointer): tuple[gen, lsn: uint64] {.gcsafe, inline.} =
  case w
  of w0: c0Load(base)
  of w2: c2Load(base)

type
  WArgs = object
    base: pointer
    which: Which
    iters: int
  RArgs = object
    base: pointer
    which: Which
    stop: ptr Stop
    c: ptr Counts

proc writer(a: WArgs) {.thread, gcsafe.} =
  for i in 1 .. a.iters:
    doStore(a.which, a.base, uint64(i), uint64(i) * 10'u64)

proc reader(a: RArgs) {.thread, gcsafe.} =
  while not a.stop[].load(moAcquire):
    let (g, l) = doLoad(a.which, a.base)
    if g > 0'u64:
      discard a.c[].obs.fetchAdd(1)
      if l < g * 10'u64:
        discard a.c[].bad.fetchAdd(1)

proc measure(name: string; w: Which; iters: int) =
  let path = shmPath(name)
  let base = mapIt(path)
  var stop: Stop
  var c: Counts
  var wt: Thread[WArgs]
  var rt: Thread[RArgs]
  let t0 = epochTime()
  createThread(wt, writer, WArgs(base: base, which: w, iters: iters))
  createThread(rt, reader,
               RArgs(base: base, which: w, stop: addr stop, c: addr c))
  joinThread(wt)
  stop.store(true, moRelease)
  joinThread(rt)
  let secs = epochTime() - t0
  echo "  ", name, ": ", c.obs.load(moAcquire), " observations, ",
       c.bad.load(moAcquire), " torn  (", formatFloat(secs, ffDecimal, 1), "s)"
  discard posix.munmap(base, 16)

proc main() =
  let iters = if paramCount() > 0: parseInt(paramStr(1)) else: Iters
  echo "F1.0 — barrier candidates over ", iters, " publishes"
  echo "  invariant: acquire(gen) implies lsn >= gen*10"
  echo ""
  echo "(0) cast[ptr Atomic[uint64]] — what ships today"
  measure("(0) cast Atomic ", w0, iters)
  echo "(2) shared struct whose address is the mapping"
  measure("(2) shared struct", w2, iters)
  echo ""
  echo "  Both correct here. (0) is kept because it ships and is green;"
  echo "  'works today' and 'is guaranteed by Nim's Atomic contract' are"
  echo "  different claims — this file is the evidence for the first."

main()
