## glyphes — M1: the store.
##
## Two kinds of test here, and the distinction matters:
##
##   * Layout assertions check sizeof/offsetOf against docs/STORAGE.md.
##     They read the specification's numbers, not the implementation's,
##     because TESTING.md Q3 exists precisely so a layout change fails a
##     test rather than passing one.
##
##   * Behaviour tests exercise the store through its public API, with
##     the invariant check (STORAGE.md S1-S10) as the oracle after every
##     mutating suite.

import std/unittest
import std/random
import std/tables
import std/strutils
import std/sequtils
import std/os
import ../../src/store/arena
import ../../src/store/ids
import ../../src/txn/txn
import ../../src/store/dict
import ../../src/store/prop
import ../../src/store/node
import ../../src/store/edge
import ../../src/store/label
import ../../src/store/store

suite "record layouts (STORAGE.md §2)":
  test "NodeRec is 48 bytes with the tabulated offsets":
    check sizeof(NodeRec) == 48
    check cast[uint](offsetOf(NodeRec, id)) == 0
    check cast[uint](offsetOf(NodeRec, outHead)) == 8
    check cast[uint](offsetOf(NodeRec, inHead)) == 16
    check cast[uint](offsetOf(NodeRec, label)) == 24
    check cast[uint](offsetOf(NodeRec, propSlots)) == 28
    check cast[uint](offsetOf(NodeRec, outCount)) == 32
    check cast[uint](offsetOf(NodeRec, inCount)) == 36
    check cast[uint](offsetOf(NodeRec, propCount)) == 40
    check cast[uint](offsetOf(NodeRec, flags)) == 42
    check cast[uint](offsetOf(NodeRec, slotCapacity)) == 44

  test "EdgeRec is 56 bytes with the tabulated offsets":
    check sizeof(EdgeRec) == 56
    check cast[uint](offsetOf(EdgeRec, id)) == 0
    check cast[uint](offsetOf(EdgeRec, src)) == 8
    check cast[uint](offsetOf(EdgeRec, dst)) == 16
    check cast[uint](offsetOf(EdgeRec, nextOut)) == 24
    check cast[uint](offsetOf(EdgeRec, nextIn)) == 32
    check cast[uint](offsetOf(EdgeRec, etype)) == 40
    check cast[uint](offsetOf(EdgeRec, props)) == 44
    check cast[uint](offsetOf(EdgeRec, propCount)) == 48
    check cast[uint](offsetOf(EdgeRec, flags)) == 50
    check cast[uint](offsetOf(EdgeRec, slotCapacity)) == 52

  test "PropSlot is 16 bytes with the tabulated offsets":
    # Corrected from 24 at M1. 4+1+1+2+8 is 16, and payload's 8-byte
    # alignment lands exactly there, so there is no padding at all.
    check sizeof(PropSlot) == 16
    check cast[uint](offsetOf(PropSlot, key)) == 0
    check cast[uint](offsetOf(PropSlot, vtype)) == 4
    check cast[uint](offsetOf(PropSlot, sflags)) == 5
    check cast[uint](offsetOf(PropSlot, aux)) == 6
    check cast[uint](offsetOf(PropSlot, payload)) == 8

suite "id allocation (STORAGE.md S2)":
  test "ids start at 1":
    var a: IdAllocator
    initIds a
    check a.alloc() == 1
    check a.alloc() == 2
    check a.alloc() == 3

  test "released ids are not reused until compaction":
    var a: IdAllocator
    initIds a
    discard a.alloc()
    let b = a.alloc()
    a.release b
    let c = a.alloc()
    # STORAGE.md S2: ids are stable for an object's lifetime and are not
    # recycled within a generation, so a host holding a Node across a
    # delete keeps referring to the right thing.
    check c != b
    check c == 3

  test "compaction renumbers and empties the free list":
    var a: IdAllocator
    initIds a
    for i in 1 .. 10: discard a.alloc()
    a.release 3
    a.release 7
    check a.liveCount() == 8
    a.reclaim 4                       # 4 records survived compaction
    check a.liveCount() == 4
    check a.alloc() == 5

suite "arena (STORAGE.md §3)":
  test "offset 0 is never handed out":
    # 0 is the "no arena reference" sentinel in every record field, so
    # the arena starts handing out at 8.
    var a: Arena
    initArena a
    check a.alloc(1) >= ArenaFirstOffset

  test "allocations are 8-aligned and non-overlapping":
    var a: Arena
    initArena a
    var offsets: seq[int32]
    for i in 1 .. 50:
      offsets.add a.alloc(3)
    for o in offsets:
      check o.int mod 8 == 0
    var seen = initOrderedTable[int32, int]()
    for o in offsets:
      check not seen.hasKey(o)
      seen[o] = 0

  test "copyIn round-trips":
    var a: Arena
    initArena a
    let off = a.copyIn("hello glyphes")
    check a.read(off, 13) == "hello glyphes"

  test "ptrAt bounds-checks against the bump, not per allocation":
    ## A bump allocator knows only its high-water mark, so it *cannot*
    ## tell that reading 5 bytes from a 4-byte allocation overruns that
    ## allocation. It can only refuse to read past anything ever written.
    ## Asserting the weaker, true guarantee rather than the stronger one
    ## nobody can provide — this is why overflow values are
    ## length-prefixed (arena.putBlob) and why the snapshot has a body
    ## CRC.
    var a: Arena
    initArena a
    let off = a.alloc(4)
    check a.ptrAt(off, 4) != nil
    check a.ptrAt(off, 8) != nil          # rounded up to the 8-byte grain
    check a.ptrAt(0, 1) == nil            # the reserved hole
    check a.ptrAt(-1, 1) == nil
    check a.ptrAt(off + 100000, 1) == nil # past the bump

  test "an empty string allocates nothing and says so with 0":
    ## 0 is the "no arena reference" sentinel, which is a better answer
    ## for an empty request than a distinct negative code.
    var a: Arena
    initArena a
    check a.copyIn("") == 0
    check a.alloc(0) == 0
    check a.alloc(-1) == -1

suite "dictionary (STORAGE.md §4)":
  test "interning is idempotent and codes start at 1":
    var d: Dictionary
    initDict d
    let a = d.intern("Person")
    let b = d.intern("Person")
    check a == b
    check a == 1
    check d.intern("KNOWS") == 2
    check d.count() == 2

  test "code 0 is never assigned":
    var d: Dictionary
    initDict d
    check d.lookup("nope") == 0
    check d.intern("Person") != 0

  test "the table grows and stays correct":
    var d: Dictionary
    initDict d
    var codes = initTable[string, int32]()
    for i in 0 ..< 2000:
      let name = "label_" & $i
      let code = d.intern name
      check codes.getOrDefault(name, 0'i32) == 0 or codes[name] == code
      codes[name] = code
    check d.count() == 2000
    for name, code in codes:
      check d.lookup(name) == code
      check d.nameOf(code) == name

  test "probing survives a collision storm":
    # 2000 distinct 6-char keys in a 16-slot table is ~125x oversubscribed
    # before growth; if the load factor or the probe sequence were wrong,
    # lookups would hang or miss here.
    var d: Dictionary
    initDict d
    for i in 0 ..< 5000:
      discard d.intern("k" & chr(65 + (i mod 26)) & $i)
    check d.count() == 5000

suite "property values":
  template roundTrip(v: Value) =
    ## Encode, store, read back. The interesting cases are the ones that
    ## cross the 8-byte inline threshold, because that is where a layout
    ## bug hides. Asserts the kind round-trips and that the slot is the
    ## only one; `expectInline` separately checks which storage path a
    ## value took, because a long string and a short one must land
    ## differently and the fact that they do is the point of S4.
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, v)
    var got: Value
    check a.getProp(pv, 1, got)
    check got.kind == v.kind
    check a.readSlots(pv).len == 1
    check (a.getProp(pv, 99, got)) == false

  proc isInline(a: Arena, pv: PropView): bool =
    (a.readSlots(pv)[0].sflags and SlotInline) != 0

  test "inline scalars":
    roundTrip Value(kind: vkBool, b: true)
    roundTrip Value(kind: vkBool, b: false)
    roundTrip Value(kind: vkInt, i: 0)
    roundTrip Value(kind: vkInt, i: -9223372036854775807)
    roundTrip Value(kind: vkFloat, f: 3.14159265358979)

  test "strings straddle the inline threshold":
    roundTrip Value(kind: vkString, s: "")
    roundTrip Value(kind: vkString, s: "a")
    roundTrip Value(kind: vkString, s: "12345678")     # exactly inline
    roundTrip Value(kind: vkString, s: "123456789")    # one over

    # S4: <= 8 bytes is inline, 9+ is arena-resident. Asserted on both
    # sides of the boundary, because an off-by-one here is invisible
    # until a snapshot is written.
    block:
      var a: Arena
      initArena a
      var pv: PropView
      discard a.setProp(pv, 1, Value(kind: vkString, s: "12345678"))
      check a.isInline(pv)
    block:
      var a: Arena
      initArena a
      var pv: PropView
      discard a.setProp(pv, 1, Value(kind: vkString, s: "123456789"))
      check not a.isInline(pv)

  test "bytes and null bytes survive":
    roundTrip Value(kind: vkBytes, s: "\x00\x01\x02\xff")
    roundTrip Value(kind: vkString, s: "héllo · ☃")

  test "vectors":
    roundTrip Value(kind: vkVector, dims: @[0.5'f32, -0.25'f32, 1.0'f32])
    roundTrip Value(kind: vkVector, dims: @[])

  test "nested lists and maps":
    roundTrip Value(kind: vkList, items: @[
      Value(kind: vkInt, i: 1),
      Value(kind: vkString, s: "two"),
      Value(kind: vkList, items: @[Value(kind: vkBool, b: true)])
    ])
    roundTrip Value(kind: vkMap, pairs: @[
      ("a", Value(kind: vkInt, i: 7)),
      ("b", Value(kind: vkList, items: @[Value(kind: vkFloat, f: 0.5)]))
    ])

  test "containers are never inline, however small":
    # S4: a list or map is arena-resident regardless of size, because an
    # inline container would need a header and the payload is full.
    block:
      var a: Arena
      initArena a
      var pv: PropView
      discard a.setProp(pv, 1, Value(kind: vkList, items: @[Value(kind: vkInt, i: 1)]))
      check not a.isInline(pv)

  test "a 768-dim vector is never inline":
    # S4: a vector is arena-resident however small. This is the case the
    # rule exists for — the M6 embedding.
    var dims = newSeq[float32](768)
    for i in 0 ..< dims.len:
      dims[i] = float32(i) / 768.0'f32
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkVector, dims: dims))
    let slots = a.readSlots(pv)
    check (slots[0].sflags and SlotInline) == 0
    check slots[0].aux == 768

suite "property slots":
  test "set, replace, and read back many keys":
    var a: Arena
    initArena a
    var pv: PropView
    for i in 0 ..< 40:
      check a.setProp(pv, int32(i + 1), Value(kind: vkInt, i: int64(i))) == false
    var got: Value
    for i in 0 ..< 40:
      check a.getProp(pv, int32(i + 1), got)
      check got.i == int64(i)
    check pv.count == 40

  test "replacing a key returns true and keeps the count":
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkInt, i: 1))
    check a.setProp(pv, 1, Value(kind: vkInt, i: 2)) == true
    check pv.count == 1
    var got: Value
    check a.getProp(pv, 1, got)
    check got.i == 2

  test "replacing an inline value with an overflowing one and back":
    # The threshold crossing in both directions, which is where an
    # off-by-one in aux or payload would show.
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkString, s: "short"))
    discard a.setProp(pv, 1, Value(kind: vkString, s: "a much longer value here"))
    var got: Value
    check a.getProp(pv, 1, got)
    check got.s == "a much longer value here"
    discard a.setProp(pv, 1, Value(kind: vkString, s: "tiny"))
    check a.getProp(pv, 1, got)
    check got.s == "tiny"

  test "remove compacts and reports":
    var a: Arena
    initArena a
    var pv: PropView
    for i in 0 ..< 5:
      discard a.setProp(pv, int32(i + 1), Value(kind: vkInt, i: int64(i)))
    check a.removeProp(pv, 3) == true
    check a.removeProp(pv, 3) == false
    check pv.count == 4
    var got: Value
    check a.getProp(pv, 3, got) == false
    check a.getProp(pv, 4, got)
    check got.i == 3

  test "removing the last key releases the slot array":
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkInt, i: 1))
    check pv.slotsOff > 0
    discard a.removeProp(pv, 1)
    check pv.slotsOff == 0
    check pv.capacity == 0
    check pv.count == 0

  test "a null value removes rather than stores":
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkInt, i: 1))
    discard a.setProp(pv, 1, Value(kind: vkNull))
    check pv.count == 0

  test "slot capacity doubles (STORAGE.md §10, settled at M1)":
    var a: Arena
    initArena a
    var pv: PropView
    discard a.setProp(pv, 1, Value(kind: vkInt, i: 1))
    check pv.capacity == InitialSlotCapacity
    var lastCap = pv.capacity
    for i in 2 .. 40:
      discard a.setProp(pv, int32(i), Value(kind: vkInt, i: int64(i)))
      if pv.capacity != lastCap:
        check pv.capacity == lastCap * 2     # exactly doubling, no waste
        lastCap = pv.capacity

  test "property keys must be positive codes":
    var a: Arena
    initArena a
    var pv: PropView
    expect ValueError:
      discard a.setProp(pv, 0, Value(kind: vkInt, i: 1))

suite "label index (STORAGE.md §4.3)":
  # The position is the whole point: it makes removal O(1) rather than a
  # scan of the label (label.nim's header explains why that matters).
  test "add returns a position and remove is swap-remove at it":
    var li: LabelIndex
    initLabels li, 1
    # Parenthesized: `li.add 1, 10` parses as a command call with a
    # trailing tuple and then fails to compile.
    let p0 = li.add(1, 10)
    let p1 = li.add(1, 11)
    let p2 = li.add(2, 12)
    check p0 == 0 and p1 == 1 and p2 == 0
    check li.contains(1, 10)
    check li.contains(2, 12)
    check not li.contains(1, 12)
    check li.count(1) == 2
    check li.total() == 3

    var moved: int64 = 0
    check li.remove(1, p0, moved)
    check moved == 11          # the tail member shifted into the hole
    check li.contains(1, 11)
    check not li.contains(1, 10)
    check li.count(1) == 1

    # Removing the tail moves nothing.
    moved = 0
    check li.remove(1, p1 - 1, moved)
    check moved == 0

  test "remove rejects a position outside the list":
    var li: LabelIndex
    initLabels li, 1
    discard li.add(1, 10)
    var moved: int64 = 0
    check (li.remove(1, 5, moved)) == false
    check (li.remove(1, -1, moved)) == false
    check (li.remove(0, 0, moved)) == false

  test "code 0 is not a label":
    var li: LabelIndex
    initLabels li, 1
    check li.add(0, 5) == -1
    check li.total() == 0
    check not li.contains(0, 5)

  test "the index grows past its initial size":
    var li: LabelIndex
    initLabels li, 1
    discard li.add(1, 1)
    discard li.add(500, 2)
    check li.contains(500, 2)
    check li.count(500) == 1

suite "store — nodes and edges":
  test "create and read back a node":
    let s = newStore()
    let a = s.createNode("Person")
    check a == 1
    check s.nodeExists a
    check s.node(a).label != 0
    check s.labels.nameOf(s.node(a).label) == "Person"
    check s.nodeCount() == 1

  test "an unlabelled node has label code 0":
    let s = newStore()
    let a = s.createNode("")
    check s.node(a).label == 0

  test "edges connect and adjacency walks both ways":
    let s = newStore()
    let a = s.createNode("Person")
    let b = s.createNode("Person")
    let e = s.createEdge(a, b, "KNOWS")
    check e != 0
    check s.edgeExists e
    check s.outEdges(a) == @[e]
    check s.inEdges(b) == @[e]
    check s.outEdges(b).len == 0
    check s.node(a).outCount == 1
    check s.node(b).inCount == 1
    check s.edge(e).etype != 0
    check s.relTypes.nameOf(s.edge(e).etype) == "KNOWS"

  test "an edge to a missing node is refused without burning an id":
    let s = newStore()
    let a = s.createNode("Person")
    check s.createEdge(a, 999, "KNOWS") == 0
    check s.createEdge(999, a, "KNOWS") == 0
    check s.nodeIds.next == 2          # only the node consumed an id
    check s.edgeCount() == 0

  test "multiple edges chain in both directions":
    let s = newStore()
    let a = s.createNode("Person")
    var targets: seq[int64]
    for i in 0 ..< 20:
      let b = s.createNode("Person")
      targets.add b
      discard s.createEdge(a, b, "KNOWS")
    check s.outEdges(a).len == 20
    check s.node(a).outCount == 20
    for b in targets:
      check s.inEdges(b).len == 1
    # Every target's in-edge is the same src.
    for b in targets:
      let eid = s.inEdges(b)[0]
      check s.edge(eid).src == a

  test "a self-loop appears in both lists of the same node":
    let s = newStore()
    let a = s.createNode("Person")
    let e = s.createEdge(a, a, "LIKES")
    check s.outEdges(a) == @[e]
    check s.inEdges(a) == @[e]
    check s.node(a).outCount == 1
    check s.node(a).inCount == 1

  test "otherEnd resolves both directions and refuses a stranger":
    let s = newStore()
    let a = s.createNode("A")
    let b = s.createNode("B")
    let c = s.createNode("C")
    let e = s.createEdge(a, b, "R")
    check s.edge(e).otherEnd(a) == b
    check s.edge(e).otherEnd(b) == a
    check s.edge(e).otherEnd(c) == 0

  test "deleting a node without cascade refuses while edges remain":
    let s = newStore()
    let a = s.createNode("Person")
    let b = s.createNode("Person")
    discard s.createEdge(a, b, "KNOWS")
    check s.deleteNode(a, false) == false
    check s.nodeExists a
    check s.deleteNode(a, true)
    check not s.nodeExists a
    check s.edgeCount() == 0
    check s.node(b).inCount == 0

  test "deleting an edge unlinks from both lists and fixes degrees":
    let s = newStore()
    let a = s.createNode("A")
    let b = s.createNode("B")
    let c = s.createNode("C")
    let e1 = s.createEdge(a, b, "R")
    let e2 = s.createEdge(a, c, "R")
    discard s.createEdge(b, c, "R")
    check s.deleteEdge e1
    check s.outEdges(a) == @[e2]
    check s.inEdges(b).len == 0
    check s.node(a).outCount == 1
    check s.node(b).inCount == 0
    check (s.deleteEdge e1) == false     # already gone

  test "deleting a node cascades through both directions":
    let s = newStore()
    let hub = s.createNode("Hub")
    var spokes: seq[int64]
    for i in 0 ..< 10:
      let x = s.createNode("Spoke")
      spokes.add x
      discard s.createEdge(hub, x, "OUT")
      discard s.createEdge(x, hub, "IN")
    check s.deleteNode(hub, true)
    check s.edgeCount() == 0
    for x in spokes:
      check s.node(x).outCount == 0
      check s.node(x).inCount == 0
      check s.outEdges(x).len == 0
      check s.inEdges(x).len == 0

suite "store — labels and properties":
  test "label membership tracks the record":
    let s = newStore()
    let a = s.createNode("Person")
    let b = s.createNode("Person")
    let c = s.createNode("Company")
    check s.labelIndex.members(s.labels.lookup("Person")).len == 2
    check s.labelIndex.members(s.labels.lookup("Company")).len == 1
    discard s.deleteNode(a, true)
    check s.labelIndex.members(s.labels.lookup("Person")).len == 1
    check s.node(b).label == s.labels.lookup("Person")
    discard c

  test "setLabel replaces and moves membership":
    let s = newStore()
    let a = s.createNode("Person")
    check s.setLabel(a, "Company")
    let personCode = s.labels.lookup("Person")
    let companyCode = s.labels.lookup("Company")
    check s.labelIndex.count(personCode) == 0
    check s.labelIndex.count(companyCode) == 1
    check not s.setLabel(9999, "X")

  test "property round-trip through the store":
    let s = newStore()
    let a = s.createNode("Person")
    check s.setNodeProp(a, "name", Value(kind: vkString, s: "Ana"))
    check s.setNodeProp(a, "age", Value(kind: vkInt, i: 34))
    check s.setNodeProp(a, "active", Value(kind: vkBool, b: true))
    var v: Value
    check s.getNodeProp(a, "name", v)
    check v.s == "Ana"
    check s.getNodeProp(a, "age", v)
    check v.i == 34
    check s.getNodeProp(a, "active", v)
    check v.b
    check s.getNodeProp(a, "missing", v) == false

  test "blob lengths round-trip, including a zero-length blob":
    var a: Arena
    initArena a
    for n in [0, 1, 8, 127, 128, 300, 5000]:
      var payload = newSeq[uint8](n)
      for i in 0 ..< n: payload[i] = uint8(i and 0xFF)
      let off = a.putBlob(payload)
      if n == 0:
        check off == 0
        check a.getBlob(off).len == 0
      else:
        check off >= ArenaFirstOffset
        let back = a.getBlob(off)
        check back.len == n
        var same = true
        for i in 0 ..< n:
          if byte(back[i]) != payload[i]: same = false
        check same

  test "a 40-char name is arena-resident, an int is not":
    # The M1 memory fixture depends on this split (STORAGE.md §7), so it
    # is asserted rather than assumed.
    let s = newStore()
    let a = s.createNode("Person")
    discard s.setNodeProp(a, "name", Value(kind: vkString, s: "x".repeat(40)))
    discard s.setNodeProp(a, "age", Value(kind: vkInt, i: 34))
    let n = s.node(a)
    let slots = s.arena.readSlots(n.propView)
    check slots.len == 2
    var inlineCount = 0
    for slot in slots:
      if (slot.sflags and SlotInline) != 0: inc inlineCount
    check inlineCount == 1
    check s.arena.used() >= 40

  test "keys() lists every property exactly once":
    let s = newStore()
    let a = s.createNode("Person")
    for i in 0 ..< 10:
      discard s.setNodeProp(a, "p" & $i, Value(kind: vkInt, i: int64(i)))
    let keys = s.nodePropKeys(a)
    check keys.len == 10
    var seen = initOrderedTable[string, int]()
    for k in keys:
      check not seen.hasKey(k)
      seen[k] = 0

  test "edge properties":
    let s = newStore()
    let a = s.createNode("A")
    let b = s.createNode("B")
    let e = s.createEdge(a, b, "R")
    discard s.setEdgeProp(e, "since", Value(kind: vkInt, i: 2019))
    var v: Value
    check s.getEdgeProp(e, "since", v)
    check v.i == 2019
    check s.getEdgeProp(e, "until", v) == false

  test "properties on a dead node are refused":
    let s = newStore()
    let a = s.createNode("Person")
    discard s.setNodeProp(a, "x", Value(kind: vkInt, i: 1))
    discard s.deleteNode(a, false)
    check s.setNodeProp(a, "y", Value(kind: vkInt, i: 2)) == false
    var v: Value
    check s.getNodeProp(a, "x", v) == false

  test "one property-key dictionary is shared by nodes and edges":
    let s = newStore()
    let a = s.createNode("A")
    let b = s.createNode("B")
    let e = s.createEdge(a, b, "R")
    discard s.setNodeProp(a, "shared", Value(kind: vkInt, i: 1))
    discard s.setEdgeProp(e, "shared", Value(kind: vkInt, i: 2))
    check s.propKeys.count() == 1
    var v: Value
    check s.getNodeProp(a, "shared", v) and v.i == 1
    check s.getEdgeProp(e, "shared", v) and v.i == 2

suite "store — invariants (STORAGE.md S1-S10)":
  template invariantsHold(st: GraphStore) =
    ## Written with `doAssert` rather than `check`: the store's own
    ## `check` proc shadows unittest's macro of the same name inside this
    ## module, and the shadowing is resolved before the argument is typed.
    ## `doAssert` has no such collision.
    for inv in st.check():
      doAssert inv.ok, inv.code & ": " & inv.detail

  test "a fresh store satisfies every invariant":
    let s = newStore()
    invariantsHold s

  test "a populated store satisfies every invariant":
    let s = newStore()
    var ids: seq[int64]
    for i in 0 ..< 200:
      let n = s.createNode(if i mod 3 == 0: "Person" else: "Company")
      discard s.setNodeProp(n, "i", Value(kind: vkInt, i: int64(i)))
      ids.add n
    for i in 0 ..< 400:
      let a = ids[i mod ids.len]
      let b = ids[(i * 7 + 3) mod ids.len]
      discard s.createEdge(a, b, if i mod 2 == 0: "KNOWS" else: "OWNS")
    invariantsHold s

  test "a self-referential graph satisfies every invariant":
    let s = newStore()
    var ring: seq[int64]
    for i in 0 ..< 50:
      ring.add s.createNode("Ring")
    for i in 0 ..< ring.len:
      discard s.createEdge(ring[i], ring[(i + 1) mod ring.len], "NEXT")
    invariantsHold s

  test "DEGREE RECOUNT: 10^6 random edge ops leave out/in exact":
    ## M1 GATE (slow, ~60 s here). The correctness check rather than a
    ## benchmark. Scales down under `GLYPHES_FAST_TESTS`.
    ## A drift in out_count/in_count corrupts the planner's hub detection
    ## silently, which is the worst kind of bug, so the authoritative
    ## check is a brute-force walk of every adjacency list compared to the
    ## eagerly-maintained counters.
    let s = newStore()
    var rng = initRand(20261007)
    var live: seq[int64]
    var liveEdges: seq[int64] = @[]

    ## GLYPHES_FAST_TESTS shrinks the churn loop for the developer loop;
    ## the full 10^6 count is what PRD §8's gate specifies, and
    ## `nimble testGate` is what runs it. Splitting them keeps
    ## `nimble test` at ~2 s without weakening the gate, which is the
    ## point of having the gate be a separate task rather than a
    ## second-class assertion.
    let full = getEnv("GLYPHES_FAST_TESTS") == ""
    const Ops = 1_000_000
    let ops = if full: Ops else: 20_000
    for i in 0 ..< ops:
      let r = rng.rand(100)
      if r < 45 or live.len < 4:
        let n = s.createNode(if r mod 2 == 0: "N" else: "M")
        live.add n
      elif r < 85:
        let a = live[rng.rand(live.high)]
        let b = live[rng.rand(live.high)]
        let e = s.createEdge(a, b, "E")
        if e != 0:
          liveEdges.add e
      elif r < 95:
        # `liveEdges` and `live` keep stale ids rather than compacting.
        # `seq.delete` is O(n), so removing from the middle on every
        # delete made this harness quadratic in the op count (4x ops cost
        # 13x the time) — the harness, not the store, was slow. Staleness
        # is absorbed lazily: picking a dead id does nothing, and the
        # recount below skips them.
        if liveEdges.len > 0:
          let e = liveEdges[rng.rand(liveEdges.high)]
          if s.edgeExists e:
            discard s.deleteEdge e
      else:
        if live.len > 8:
          let n = live[rng.rand(live.high)]
          if s.nodeExists n:
            discard s.deleteNode(n, true)

    # The authoritative comparison, not the store's own counter.
    var mismatches = 0
    var counted = 0
    for n in live:
      if not s.nodeExists n:
        continue                              # stale id from the churn
      inc counted
      let rec = s.node(n)
      var walked = 0
      var cur = rec.outHead
      while cur != 0:
        walked += 1
        cur = s.edge(cur).nextOut
      if walked != rec.outCount.int:
        inc mismatches
      walked = 0
      cur = rec.inHead
      while cur != 0:
        walked += 1
        cur = s.edge(cur).nextIn
      if walked != rec.inCount.int:
        inc mismatches
    check mismatches == 0
    check counted > (if full: 1000 else: 20)
    invariantsHold s

  test "delete-heavy churn keeps degrees exact":
    # The same property under the opposite bias: the previous test is
    # creation-dominated, and a degree bug that only appears when lists
    # shrink would survive it.
    let s = newStore()
    var rng = initRand(99)
    var live: seq[int64]
    for i in 0 ..< 4000:
      let n = s.createNode("N")
      for j in 0 ..< 3:
        if live.len > 0:
          discard s.createEdge(n, live[rng.rand(live.high)], "E")
      live.add n
    for i in 0 ..< 2000:
      if live.len > 10:
        let k = rng.rand(live.high)
        discard s.deleteNode(live[k], true)
        live.delete(k)
    var mismatches = 0
    for n in live:
      let rec = s.node(n)
      var walked = 0
      var cur = rec.outHead
      while cur != 0:
        walked += 1
        cur = s.edge(cur).nextOut
      if walked != rec.outCount.int: inc mismatches
      walked = 0
      cur = rec.inHead
      while cur != 0:
        walked += 1
        cur = s.edge(cur).nextIn
      if walked != rec.inCount.int: inc mismatches
    check mismatches == 0
    invariantsHold s

suite "store — traversal shape":
  test "outEdges returns a copy, not the live list":
    ## A caller traversing while a write appends to the same label must
    ## not see a reallocating seq (STORAGE.md §4.3). Mutating the copy
    ## is the cheapest way to prove the copy is real.
    let s = newStore()
    let a = s.createNode("A")
    let b = s.createNode("B")
    discard s.createEdge(a, b, "R")
    var snapshot = s.outEdges(a)
    snapshot.add 999999
    check s.outEdges(a).len == 1

  test "outEdgeIds for a dead node is empty":
    let s = newStore()
    let a = s.createNode("A")
    discard s.deleteNode(a, false)
    check s.outEdges(a).len == 0
    check s.inEdges(a).len == 0
    check s.node(a).id == 0
    check s.edge(999).id == 0

when defined(glyphesCheck):
  suite "review regression: the write-path invariant pass has teeth":
    test "a corrupted adjacency is caught at the next write to that record":
      ## `-d:glyphesCheck` used to name a build that did nothing — STORAGE.md
      ## §8 and TESTING.md §3.2 both claimed a debug assertion pass and no
      ## `when defined(glyphesCheck)` existed in `src/`. The pass now walks
      ## S1/S2/S3/S4/S8 over the touched records at the end of a merge; this
      ## is the test that proves it fires rather than passing vacuously.
      ## Flag-guarded: in a release build there is no check to fire, and a
      ## test asserting one would have to be conditional anyway.
      let s = newStore()
      let a = s.createNode("P")
      let b = s.createNode("P")
      discard s.createEdge(a, b, "R")
      ## Corrupt the edge's source by hand: the chain from `a` now reaches
      ## an edge that claims to be someone else's — exactly what S2 names
      ## and what only `check()` could see, at the end of the suite.
      let eid = s.outHeadOf(a)
      check eid != 0
      s.edges[eid.int].src = 999
      let tx = begin(s, nil, 1'u32, doSync = false)
      discard tx.setNodeProp(a, "x", Value(kind: vkInt, i: 1))
      var e: StoreInvariantError
      try:
        discard tx.commit()
      except StoreInvariantError as err:
        e = err
      ## `check` does not abort the test, so the second assertion reads
      ## `e.msg` through a nil when the first fails — which crashed the
      ## whole runner the first time this test existed. One branch instead.
      if e == nil:
        check "the write-path pass did not fire on a corrupted chain" == ""
      else:
        check "S2" in e.msg

  test "a record refuses the property count that wraps its count field":
    ## `prop_count` is an `int16` in both record types. Setting the 32 769th
    ## key wrapped it negative, and the next read allocated a negative
    ## length — a RangeDefect on a legal statement. The txn budget (10M
    ## ops) is two orders of magnitude above the wrap, which is why no
    ## test reached it. One property per iteration keeps this a fraction
    ## of a second.
    let s = newStore()
    let id = s.createNode("Wide")
    ## The count field holds at most 32767, so 32767 keys must fit and
    ## the 32768th must be refused. The earlier draft of this test set
    ## 32 768 and let the loop itself die — of the field's range check.
    for k in 0 ..< 32767:
      discard s.setNodeProp(id, "k" & $k, Value(kind: vkInt, i: int64(k)))
    var tooMany = false
    try:
      discard s.setNodeProp(id, "k32767", Value(kind: vkInt, i: 32767))
    except ValueError as e:
      tooMany = "properties" in e.msg
    check tooMany
    ## The record is intact at the limit, not corrupted by the refusal.
    var v: Value
    check s.getNodeProp(id, "k0", v)
    check v.i == 0
