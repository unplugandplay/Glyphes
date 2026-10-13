## glyphes — handle registry (ABI.md §3, B4)
##
## A GlyHandle is `(generation << 40) | slot`. The generation makes a
## reused address distinguishable from the old object, so a handle held
## across a close-and-reopen cycle returns GLY_ERR_STALE instead of
## touching freed memory. That is what makes `ensure`-based cleanup in
## Ruby safe when an exception unwinds mid-transaction.
##
## 24 bits of slot and 40 bits of generation is a deliberate split: a
## database process will never hold a million live handles, and 2^40
## open/close cycles on one slot will not happen in a decade.
##
## The registry is process-global rather than per-database because
## Glyphes 0.1 has exactly one database per process (PRD pin P1). When
## that stops being true the registry moves into the database and the
## handle encoding does not change — which is why it is factored out
## here now, at M0, rather than discovered at M2.
##
## Locking uses `withLock` rather than the old `{.acquire.}`
## pragmas, which Nim 2.x removed. A handle operation is not a hot path
## — it happens at open, close, prepare and statement setup — so one
## mutex for the whole table is the right amount of machinery.

import std/locks
import ./abi

type
  HandleKind* = enum
    ## Which object type a handle names. Checked on every dereference,
    ## so passing a statement handle to glyphes_close is a status error
    ## rather than a type confusion.
    hkDatabase, hkTransaction, hkStatement

  Slot = object
    generation: uint64
    live: bool
    kind: HandleKind
    ## The Nim object. Held as a raw pointer plus an explicit GC_ref,
    ## NOT as a plain raw pointer: under ORC the `ref Database` created
    ## in glyphes_open is destroyed when that proc returns, and every
    ## later dereference would be use-after-free. GC_ref transfers
    ## ownership to the registry; release() hands it back.
    obj: pointer
    err: string                   ## handle-local error message

  Registry = object
    lock: Lock
    slots: seq[Slot]
    free: seq[int32]

var registry: Registry
var registryInit = false

const
  ## Slot index lives in the low 40 bits.
  GenerationShift* = 40
  SlotMask64* = (1'u64 shl GenerationShift) - 1
  MaxGeneration* = 1'u64 shl (64 - GenerationShift)

proc slotIndex*(h: GlyHandle): int {.inline.} =
  int(uint64(h) and SlotMask64)

proc generationOf*(h: GlyHandle): uint64 {.inline.} =
  (uint64(h) shr GenerationShift)

proc initRegistry() =
  ## Single-threaded by construction: glyphes_open is the first thing a
  ## process calls, and the GIL means two Ruby threads cannot both reach
  ## here before the library is loaded (RUBY.md §3.2). After the first
  ## call the flag is only ever read.
  if not registryInit:
    initLock(registry.lock)
    registry.slots = newSeqOfCap[Slot](64)
    registry.free = @[]
    registryInit = true

proc register*[T](kind: HandleKind, obj: ref T): GlyHandle =
  ## Takes ownership: GC_ref bumps the refcount, so the object outlives
  ## the caller's local binding. release() unrefs it.
  ##
  ## Typed rather than taking a bare `pointer` precisely so that this
  ## GC_ref cannot be forgotten at a call site -- the alternative is a
  ## registry full of dangling pointers that only crash under load.
  initRegistry()
  withLock registry.lock:
    var slot: int32
    if registry.free.len > 0:
      slot = registry.free.pop()
    else:
      if registry.slots.len > int(SlotMask64):
        raise newException(ValueError, "glyphes: handle slots exhausted")
      registry.slots.setLen(registry.slots.len + 1)
      slot = int32(registry.slots.len - 1)
      registry.slots[slot].generation = 1
    registry.slots[slot].live = true
    registry.slots[slot].kind = kind
    registry.slots[slot].obj = cast[pointer](obj)
    registry.slots[slot].err = ""
    GC_ref(obj)
    result = (registry.slots[slot].generation shl GenerationShift) or
             uint64(uint64(slot) and SlotMask64)

proc slotMatches*(h: GlyHandle, slotIdx: int): bool {.inline.} =
  slotIdx < registry.slots.len and registry.slots[slotIdx].live and
    registry.slots[slotIdx].generation == generationOf(h)

proc release*[T](h: GlyHandle): HandleKind =
  ## Frees the slot, bumps the generation so a stale copy of `h` can
  ## never validate again, and hands the object back to the collector.
  ##
  ## The unref happens *after* the slot is marked dead, so a concurrent
  ## lookup that already passed its liveness check still holds a pointer
  ## the collector has not been told about. That ordering is the whole
  ## reason this is one lock and not two.
  if h == 0:
    return
  initRegistry()
  var kind: HandleKind
  var freed = false
  withLock registry.lock:
    let slotIdx = slotIndex(h)
    if slotMatches(h, slotIdx):
      kind = registry.slots[slotIdx].kind
      freed = true
      registry.slots[slotIdx].live = false
      registry.slots[slotIdx].obj = nil
      registry.slots[slotIdx].err = ""
      inc registry.slots[slotIdx].generation
      if registry.slots[slotIdx].generation >= MaxGeneration:
        registry.slots[slotIdx].generation = 1
      registry.free.add int32(slotIdx)
  if freed:
    result = kind

proc lookup*[T](h: GlyHandle, kind: HandleKind): T =
  ## Typed lookup. Raises on stale or wrong-kind handles so every call
  ## site gets the same check for free.
  if h == 0:
    raise newException(ValueError, "glyphes: null handle")
  initRegistry()
  withLock registry.lock:
    let slotIdx = slotIndex(h)
    if not slotMatches(h, slotIdx):
      raise newException(ValueError, "glyphes: stale handle")
    if registry.slots[slotIdx].kind != kind:
      raise newException(ValueError, "glyphes: handle kind mismatch")
    result = cast[T](registry.slots[slotIdx].obj)

proc isLive*(h: GlyHandle): bool =
  ## Non-raising check, for the exported entry points that must answer
  ## with GLY_ERR_STALE rather than unwind (ABI.md B8).
  if h == 0:
    return false
  initRegistry()
  withLock registry.lock:
    result = slotMatches(h, slotIndex(h))

proc isKind*(h: GlyHandle, kind: HandleKind): bool =
  ## Non-raising kind check, for the same reason: passing a statement
  ## handle to `glyphes_tx_commit` is a caller error that must come back
  ## as a status, not as an exception from `lookup`. Cheap enough to sit
  ## next to `isLive` — a lock, one comparison.
  if h == 0:
    return false
  initRegistry()
  withLock registry.lock:
    let slotIdx = slotIndex(h)
    result = slotMatches(h, slotIdx) and registry.slots[slotIdx].kind == kind

proc setError*(h: GlyHandle, msg: string) =
  if h == 0:
    return
  initRegistry()
  withLock registry.lock:
    let slotIdx = slotIndex(h)
    if registry.slots.len > slotIdx and registry.slots[slotIdx].live:
      registry.slots[slotIdx].err = msg

proc lastError*(h: GlyHandle): string =
  if h == 0:
    return ""
  initRegistry()
  withLock registry.lock:
    let slotIdx = slotIndex(h)
    if registry.slots.len > slotIdx and registry.slots[slotIdx].live:
      result = registry.slots[slotIdx].err

proc liveHandleCount*(): int =
  ## For tests: a leaked handle is a bug that shows up as a growing
  ## count here long before it shows up as a memory leak.
  initRegistry()
  withLock registry.lock:
    for s in registry.slots:
      if s.live:
        inc result
