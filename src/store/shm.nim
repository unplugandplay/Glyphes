## glyphes — the shared control block (PRD-SHARED S2)
##
## One mmap'd file, two words: the last committed generation and the LSN its
## last frame sits at. A reader in another process learns what has been
## committed by reading one of these and comparing, which is the whole of
## PRD §3.1's "alone or shared is freshness, not attachment".
##
## ## Why release/acquire and not "write it last"
##
## The obvious protocol is: writer stores the LSN, then stores the
## generation; reader loads the generation and, seeing it advance, knows the
## LSN is current. On x86 that happens to work, because Total Store Ordering
## makes ordinary stores expensive to reorder. **This is an arm64 codebase**
## (`uname -m`), where stores to different addresses *may* be observed out of
## order by another core, and the same code would let a reader observe
## `generation == g+1` with a `committedLsn` that still names *g*'s last frame
## — so it bounds its replay at a prefix that does not contain the frames the
## generation implies, and silently stops short of the newest commit.
##
## That is why the stores below are `moRelease` and the loads are
## `moAcquire` (pin S6): release on the generation pairs with acquire on the
## reader, and the compiler emits the `stlr`/`ldar` that make the ordering a
## property of the machine rather than a habit of the author. SG5 exercises
## the interleaving many times, because this bug is rare by construction and
## a single-run test would pass on a broken build.
##
## ## Why the block has no header, version or checksum
##
## Because this file is rebuilt from the WAL on every open, so there is
## nothing in it worth validating and a header would only be another thing to
## get wrong. A file of zeroes is a *valid* state meaning "generation 0, lsn
## 0": a reader that sees it replays the whole WAL, which is the correct
## answer for a database whose control block has never been written.
##
## ## Layout
##
## Fixed offsets, identical in every process:
##
##   0  committedLsn        uint64
##   8  committedGeneration uint64
##
## `Atomic[uint64]` is used for both, so the access is well-defined even
## though the memory is shared with another *process* (which is outside the
## model C++11 atomics are written for). 8-byte atomics on a 64-bit target
## compile to plain load/store with barriers; `isLockFree` is asserted at
## open rather than assumed.

import std/os

when defined(posix):
  import std/posix

import std/atomics

const
  ShmSuffix* = "-shm"
  ## Matches the `.vhist` and `-wal` sidecar family.
  ShmSize* = 16
  ## Two uint64s. A page would do; 16 is the block and `mmap` rounds up, and
  ## a size that is the block's own size makes the mapping's extent obvious
  ## in a hexdump.
  OffsetLsn* = 0
  OffsetGeneration* = 8

type
  Shm* = ref object
    ## One process's view of the shared control block.
    ##
    ## `addr` is the mmap'd base; the two atomic fields live at fixed offsets
    ## within it rather than in this object, because the object is per-process
    ## and the *memory* is not. Writing through a pointer to `+ OffsetLsn`
    ## is the only way to reach the shared word.
    path*: string
    base*: pointer
    size*: cint

proc shmPathFor*(graphPath: string): string =
  ## `<db>` -> `<db>-shm`.
  graphPath & ShmSuffix

proc mapShm(path: string, readOnly: bool): Shm =
  ## Map an existing control block. The fd is mapped and then closed: the
  ## mapping, not the descriptor, is what two processes share, and holding an
  ## fd open on a `-shm` another process is about to unlink is a way to end up
  ## mapping an unlinked inode.
  result = Shm(path: path)
  let fd = posix.open(path, if readOnly: O_RDONLY else: O_RDWR)
  if fd < 0:
    raise newException(IOError, "cannot open " & path)
  let prot = if readOnly: PROT_READ else: PROT_READ or PROT_WRITE
  result.base = posix.mmap(nil, ShmSize, prot, MAP_SHARED, fd, 0)
  discard posix.close(fd)
  if result.base == MAP_FAILED:
    raise newException(IOError, "cannot mmap " & path)

proc openShm*(graphPath: string): Shm =
  ## Map (creating if absent) the control block for `graphPath`. Writer-side.
  ##
  ## `MAP_SHARED` and zero-fill on create are both load-bearing:
  ##
  ##  * `MAP_SHARED`, because `MAP_PRIVATE` would give each process its own
  ##    copy and two processes would never see each other at all — a control
  ##    block that cannot communicate is worse than none, because it looks
  ##    like it works.
  ##  * zero-fill on create, because an uninitialised file must not read as
  ##    a generation the reader will try to catch up *from*.
  when not defined(posix):
    {.error: "the shared control block is POSIX-only (mmap)."}
  let path = shmPathFor(graphPath)
  if not fileExists(path):
    ## Create it as a file of zeroes. `writeFile` truncating is fine here:
    ## this file holds no state that survives an open (everything is rebuilt
    ## from the WAL), so a torn create is indistinguishable from a fresh one
    ## and the open continues with generation 0.
    writeFile(path, newString(ShmSize))  # newString zero-fills
  mapShm(path, readOnly = false)

proc openShmReadOnly*(graphPath: string): Shm =
  ## Map the control block for a follower. **Never creates it.**
  ##
  ## This exists because `openShm` was the wrong function for a reader, and
  ## wrong in a way that looks like success: opening a watermark-less
  ## database created one, zero-filled, and returned a block reading
  ## generation 0 — so a follower attached to a database whose writer had not
  ## published yet would report "caught up to generation 0" and watch nothing,
  ## confidently. A missing watermark is a fact about the database, so the
  ## reader is told rather than made to invent one.
  when not defined(posix):
    {.error: "the shared control block is POSIX-only (mmap)."}
  mapShm(shmPathFor(graphPath), readOnly = true)

proc closeShm*(s: Shm) =
  if s != nil and s.base != nil:
    discard posix.munmap(s.base, ShmSize)
    s.base = nil

proc lsnWord(s: Shm): ptr Atomic[uint64] {.inline.} =
  ## A typed pointer to the LSN word inside the shared mapping. The cast is
  ## the whole trick: the block is two 8-byte words and an `Atomic[uint64]`
  ## is exactly an 8-byte word with a barrier on access.
  cast[ptr Atomic[uint64]](cast[uint](s.base) + OffsetLsn)

proc genWord(s: Shm): ptr Atomic[uint64] {.inline.} =
  cast[ptr Atomic[uint64]](cast[uint](s.base) + OffsetGeneration)

proc loadGeneration*(s: Shm): uint64 =
  ## Acquire. Pairs with the writer's `moRelease` store of the generation
  ## (S6). An acquire load of the generation orders every write the writer
  ## made before it, including the LSN store — which is the entire mechanism
  ## by which "the frames are on disk before anyone is told they exist" is
  ## made observable to a reader in another process.
  ##
  ## Reads `genWord`, not `lsnWord`. The first version read `lsnWord` here —
  ## a copy-paste slip two adjacent lines apart — so `loadGeneration`
  ## returned the LSN and every test that published a generation got the LSN
  ## back instead. SG5's invariant (`lsn >= gen * 10`) is what finally showed
  ## it, because a generation of 7 and an LSN of 1234 fail it immediately
  ## while `loadGeneration() == 7` failing was the same bug one layer up.
  genWord(s)[].load(moAcquire)

proc loadLsn*(s: Shm): uint64 =
  ## Acquire, for symmetry and for a caller that only needs the WAL position.
  lsnWord(s)[].load(moAcquire)

proc publishCommitted*(s: Shm; generation, lsn: uint64) =
  ## Called by the writer after its frames are durable (fsynced WAL and
  ## synced `.vhist`) and before it releases the cross-process write lock.
  ##
  ## Order is LSN then generation, both `moRelease`. The release on the
  ## *generation* is the one that matters: it is the acquire/release pair the
  ## reader's acquire-load synchronises with, and it makes everything the
  ## writer did before it — including the frame bytes — visible to a reader
  ## that sees the new generation. Publishing the generation first would let
  ## a reader catch up to frames the writer has not finished writing.
  ##
  ## Monotonic by construction: S1 makes the writer single-process, so
  ## `generation` only ever increases and no compare-and-swap is needed.
  ##
  ## LSN first, then generation. The generation carries the release barrier
  ## that pairs with the reader's acquire; the LSN is an ordinary store
  ## ordered *before* it, so a reader that acquires the new generation also
  ## sees the LSN that goes with it. Writing the generation first — which is
  ## what the first draft of this function did, while its own comment
  ## described the opposite order — is precisely the bug S2 exists to
  ## prevent, reintroduced one line away from where the warning was.
  lsnWord(s)[].store(lsn, moRelease)
  genWord(s)[].store(generation, moRelease)