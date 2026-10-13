## glyphes — node records (STORAGE.md §2.1, §3, §5)
##
## NodeRec is 48 bytes and holds no pointers: `prop_slots` and every
## `PropSlot.payload` are arena *offsets* (S3), so the record array is
## serializable and mmap-able with no fixup pass.
##
## Adjacency is a linked list threaded through the *edges*'
## `next_out` / `next_in`, not an array of ids hanging off the node
## (STORAGE.md §5). An array-of-arrays would put a 24-byte seq header in
## every record, allocate a block per node on creation, and make a
## degree-1 node cost more than a degree-50 node.

import ./prop

type
  NodeRec* {.bycopy.} = object
    ## 48 bytes. Offsets asserted against docs/STORAGE.md §2.1 by
    ## tests/unit/test_store.nim (TESTING.md Q3).
    id*: int64
    outHead*: int64        ## first edge id out of this node; 0 = none
    inHead*: int64         ## first edge id into this node; 0 = none
    label*: int32          ## dictionary code; 0 = unlabelled
    propSlots*: int32      ## arena offset of the slot array; 0 = none
    outCount*: int32       ## maintained eagerly (S8), never recounted
    inCount*: int32
    propCount*: int16
    flags*: uint16
    slotCapacity*: uint32  ## slots allocated at propSlots; >= propCount

  NodeFlag* = enum
    ## Bit positions in `flags`, matching STORAGE.md §2.3.
    nfTombstone = 0'u16
    nfLocked    = 1'u16
    nfDirty     = 2'u16
    nfHasProps  = 3'u16

const
  NodeFlagBits = [
    nfTombstone: 1'u16 shl 0,
    nfLocked:    1'u16 shl 1,
    nfDirty:     1'u16 shl 2,
    nfHasProps:  1'u16 shl 3
  ]

proc hasFlag*(n: NodeRec, f: NodeFlag): bool {.inline.} =
  (n.flags and NodeFlagBits[f]) != 0

proc setFlag*(n: var NodeRec, f: NodeFlag) {.inline.} =
  n.flags = n.flags or NodeFlagBits[f]

proc clearFlag*(n: var NodeRec, f: NodeFlag) {.inline.} =
  n.flags = n.flags and not NodeFlagBits[f]

proc newNode*(id: int64, label: int32): NodeRec =
  NodeRec(id: id, label: label, outHead: 0, inHead: 0,
          propSlots: 0, outCount: 0, inCount: 0,
          propCount: 0, flags: 0, slotCapacity: 0)

proc live*(n: NodeRec): bool {.inline.} =
  ## `id != 0` first, not just the tombstone bit. A record array grown
  ## by doubling leaves a tail of zeroed slots; their flags are 0, so
  ## "no tombstone" would call them live and inflate every count. Id 0 is
  ## the "no record" sentinel, which is the whole reason it is reserved.
  n.id != 0 and not n.hasFlag(nfTombstone)

proc propView*(n: NodeRec): PropView {.inline.} =
  PropView(slotsOff: n.propSlots, count: int32(n.propCount),
           capacity: int32(n.slotCapacity))

proc setPropView*(n: var NodeRec, pv: PropView) {.inline.} =
  n.propSlots = pv.slotsOff
  n.propCount = int16(pv.count)
  n.slotCapacity = uint32(pv.capacity)
  if pv.count > 0:
    n.setFlag(nfHasProps)
  else:
    n.clearFlag(nfHasProps)

proc outDegree*(n: NodeRec): int32 {.inline.} = n.outCount
proc inDegree*(n: NodeRec): int32 {.inline.} = n.inCount
proc degree*(n: NodeRec): int64 {.inline.} = int64(n.outCount) + int64(n.inCount)
