## glyphes — edge records and threaded adjacency (STORAGE.md §2.2, §5)
##
## EdgeRec is 56 bytes. `src` and `dst` are not interchangeable with
## `out`/`in`: direction is semantic (KNOWS differs from KNOWN_BY) and
## the reverse list exists for traversal speed, not for symmetry.
##
## Insert is at the head and unlink is O(1) given a predecessor. A delete
## tombstones the record and unlinks it from *both* lists immediately,
## which is what makes deletion O(1) regardless of degree — the space is
## reclaimed at the next compaction.

import ./prop

type
  EdgeRec* {.bycopy.} = object
    ## 56 bytes. Offsets asserted against docs/STORAGE.md §2.2.
    id*: int64
    src*: int64          ## node id, outgoing endpoint
    dst*: int64          ## node id, incoming endpoint
    nextOut*: int64      ## next edge id in src.outHead; 0 = end
    nextIn*: int64       ## next edge id in dst.inHead; 0 = end
    etype*: int32        ## relationship-type dictionary code; 0 = untyped
    props*: int32        ## arena offset of the slot array; 0 = none
    propCount*: int16
    flags*: uint16
    slotCapacity*: uint32

  EdgeFlag* = enum
    efTombstone = 0'u16
    efLocked    = 1'u16
    efDirty     = 2'u16
    efHasProps  = 3'u16

const
  EdgeFlagBits = [
    efTombstone: 1'u16 shl 0,
    efLocked:    1'u16 shl 1,
    efDirty:     1'u16 shl 2,
    efHasProps:  1'u16 shl 3
  ]

proc hasFlag*(e: EdgeRec, f: EdgeFlag): bool {.inline.} =
  (e.flags and EdgeFlagBits[f]) != 0

proc setFlag*(e: var EdgeRec, f: EdgeFlag) {.inline.} =
  e.flags = e.flags or EdgeFlagBits[f]

proc clearFlag*(e: var EdgeRec, f: EdgeFlag) {.inline.} =
  e.flags = e.flags and not EdgeFlagBits[f]

proc newEdge*(id, src, dst: int64, etype: int32): EdgeRec =
  EdgeRec(id: id, src: src, dst: dst, etype: etype,
          nextOut: 0, nextIn: 0, props: 0,
          propCount: 0, flags: 0, slotCapacity: 0)

proc live*(e: EdgeRec): bool {.inline.} =
  ## See NodeRec.live: id 0 means "no record", and a zeroed tail slot
  ## from array doubling must not count as a live edge.
  e.id != 0 and not e.hasFlag(efTombstone)

proc propView*(e: EdgeRec): PropView {.inline.} =
  PropView(slotsOff: e.props, count: int32(e.propCount),
           capacity: int32(e.slotCapacity))

proc setPropView*(e: var EdgeRec, pv: PropView) {.inline.} =
  e.props = pv.slotsOff
  e.propCount = int16(pv.count)
  e.slotCapacity = uint32(pv.capacity)
  if pv.count > 0:
    e.setFlag(efHasProps)
  else:
    e.clearFlag(efHasProps)

proc source*(e: EdgeRec): int64 {.inline.} = e.src
proc target*(e: EdgeRec): int64 {.inline.} = e.dst

proc otherEnd*(e: EdgeRec, nodeId: int64): int64 =
  ## The endpoint that is not `nodeId`. Returns 0 for a self-loop on a
  ## node that is not this edge's endpoint, so a caller traversing from
  ## the wrong node gets a miss rather than a wrong hop.
  if e.src == nodeId: e.dst
  elif e.dst == nodeId: e.src
  else: 0
