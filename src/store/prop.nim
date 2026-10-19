## glyphes — properties: PropSlot, the value model, and the arena codec
## (STORAGE.md §2.4, §3, S4, S5)
##
## A property lookup is a linear scan over `prop_count` slots (S5). For
## fewer than 16 properties the whole slot array is one or two cache
## lines and a scan beats a hash lookup's pointer chase; node property
## counts above 16 are rare enough that the linear case does not matter.
##
## Values are inline when they fit in the 8-byte `payload` (S4): bool,
## int, float, and any string or bytes of 8 bytes or fewer. Vectors are
## never inline — a 768-dim f32 vector is 3 KB.
##
## Everything else goes to the arena as a tagged blob. The tag byte is a
## `GlyType` ordinal, so there is one value vocabulary across the store,
## the ABI, and the snapshot rather than three that must agree.

import ./arena

type
  GlyType* = distinct uint8
  ## Mirrors GlyType in glyphes.h. Only the property-legal subset is
  ## accepted; node/edge/path are not storable as property values in 0.1.
  ## `distinct` so a GlyType cannot be passed where a raw tag byte is
  ## expected without an explicit conversion.

  ValueKind* = enum
    ## The value model. A Nim variant object rather than a tagged union so
    ## the store stays ordinary Nim that raises; the ABI boundary converts
    ## to GlyCell separately.
    ##
    ## The first nine are the *property* value model (STORAGE.md §2.4).
    ## The last three arrived at M4 and are the query layer's reference
    ## kinds: a row can bind a node, an edge or a path, and giving the
    ## query layer a second value type would mean a conversion at every
    ## literal, every expression result and every property read. They are
    ## rejected by `setProp` and by the blob codec, so a node can never
    ## become a property and never reaches the snapshot — which is why
    ## adding them changed no stored bytes and no pin.
    vkNull, vkBool, vkInt, vkFloat, vkString, vkBytes,
    vkVector, vkList, vkMap,
    vkNode, vkEdge, vkPath

  Value* = object
    case kind*: ValueKind
    of vkNull: discard
    of vkBool: b*: bool
    of vkInt: i*: int64
    of vkFloat: f*: float64
    of vkString, vkBytes: s*: string
    of vkVector: dims*: seq[float32]
    of vkList: items*: seq[Value]
    of vkMap: pairs*: seq[(string, Value)]
    of vkNode, vkEdge: id*: int64
    of vkPath: path*: PathVal

  PathVal* = object
    ## A GLY_PATH payload (CYPHER.md §2.6): node ids, edge ids and one
    ## direction byte per edge. Three parallel arrays because that is what
    ## `GlyPath` in the header is, and a single array of pairs would be a
    ## second layout to convert at the boundary.
    ## `dirs[i]` is 0 for src→dst and 1 for dst→src; `edges.len` is
    ## `nodes.len - 1`.
    nodes*: seq[int64]
    edges*: seq[int64]
    dirs*: seq[uint8]

  PropSlot* {.bycopy.} = object
    ## 16 bytes. Every offset below is asserted against docs/STORAGE.md
    ## §2.4 by tests/unit/test_store.nim (TESTING.md Q3).
    key*: int32         ## property-key dictionary code; 0 = invalid
    vtype*: GlyType
    sflags*: uint8      ## bit 0 null, bit 1 dirty, bit 2 inline
    aux*: uint16        ## element count, or dims for a vector
    payload*: uint64    ## inline value bits, or an arena byte offset

  PropView* = object
    ## The three record fields that address a property array. NodeRec and
    ## EdgeRec each hold one inline; passing it by value is what lets
    ## set/remove grow the array without either record type depending on
    ## the other's layout.
    slotsOff*: int32   ## arena offset of the slot array; 0 = none
    count*: int32      ## slots in use
    capacity*: int32   ## slots allocated; >= count

proc `==`(a, b: GlyType): bool {.borrow, inline.}
  ## `borrow` over uint8, so `distinct` gets equality without inventing
  ## a second notion of equality. Without this every `slot.vtype ==
  ## glyString` in the file is a compile error rather than a tag compare.

const
  glyNull* = GlyType(0'u8)
  glyBool* = GlyType(1'u8)
  glyInt* = GlyType(2'u8)
  glyFloat* = GlyType(3'u8)
  glyString* = GlyType(4'u8)
  glyBytes* = GlyType(5'u8)
  glyVector* = GlyType(6'u8)
  glyNode* = GlyType(7'u8)
  glyEdge* = GlyType(8'u8)
  glyPath* = GlyType(9'u8)
  glyList* = GlyType(10'u8)
  glyMap* = GlyType(11'u8)

const
  SlotNull* = 1'u8
  SlotDirty* = 2'u8
  ## How many times a reader re-reads a slot it caught mid-update before
  ## reading it anyway. The writer clears the bit within the same call and
  ## without blocking, so a healthy store never exhausts this; the bound
  ## exists so that a corrupted store produces a possibly-odd value rather
  ## than a query that never returns.
  SlotReadRetries* = 16
  SlotInline* = 4'u8

  InlinePayload* = 8

  ## First allocation for a record's slot array.
  ##
  ## 2, not 4. Measured at M1: with a starting capacity of 4, every
  ## record with a *single* property still allocated 64 bytes of slot
  ## array, and on the M1 fixture (10^6 nodes, 4*10^6 edges, one property
  ## each) that was 320 MB of the 620 MB budget spent on padding. Most
  ## records in a real graph carry one or two properties, so 2 makes the
  ## common case exact and pays one doubling for the uncommon one.
  InitialSlotCapacity* = 2

proc propType*(k: ValueKind): GlyType {.inline.} =
  case k
  of vkNull: glyNull
  of vkBool: glyBool
  of vkInt: glyInt
  of vkFloat: glyFloat
  of vkString: glyString
  of vkBytes: glyBytes
  of vkVector: glyVector
  of vkList: glyList
  of vkMap: glyMap
  of vkNode: glyNode
  of vkEdge: glyEdge
  of vkPath: glyPath

proc typeName(t: GlyType): string {.inline.} =
  case t
  of glyNull: "null"
  of glyBool: "boolean"
  of glyInt: "integer"
  of glyFloat: "float"
  of glyString: "string"
  of glyBytes: "bytes"
  of glyVector: "vector"
  of glyNode: "node"
  of glyEdge: "edge"
  of glyPath: "path"
  of glyList: "list"
  of glyMap: "map"
  else: "unknown"

# ------------------------------------------------------------------ blob

type
  Blob = object
    buf: seq[uint8]

proc rawTag(t: GlyType): uint8 {.inline.} = uint8(t)

proc putByte(b: var Blob, v: uint8) {.gcsafe.} =
  b.buf.add v

proc putBytes(b: var Blob, src: openArray[uint8]) {.gcsafe.} =
  for x in src: b.buf.add x

proc putStr(b: var Blob, s: string) {.gcsafe.} =
  for ch in s: b.buf.add byte(ch)

proc putUvarint(b: var Blob, v: uint64) {.gcsafe.} =
  ## LEB128. Counts and lengths only, never negative values — a negative
  ## length is a bug we want to fail on, not encode.
  var x = v
  while x >= 0x80'u64:
    b.buf.add uint8((x and 0x7F'u64) or 0x80'u64)
    x = x shr 7
  b.buf.add uint8(x)

proc putF32(b: var Blob, v: float32) {.gcsafe.} =
  let bits = cast[uint32](v)
  b.putByte(uint8(bits and 0xFF'u32))
  b.putByte(uint8((bits shr 8) and 0xFF'u32))
  b.putByte(uint8((bits shr 16) and 0xFF'u32))
  b.putByte(uint8((bits shr 24) and 0xFF'u32))

proc putF64(b: var Blob, v: float64) {.gcsafe.} =
  let bits = cast[uint64](v)
  for i in 0 ..< 8:
    b.putByte(uint8((bits shr (i * 8)) and 0xFF'u64))

proc putI64(b: var Blob, v: int64) {.gcsafe.} = b.putF64(cast[float64](v))

proc storable*(k: ValueKind): bool {.inline.} =
  ## The property value model's boundary. A node, an edge or a path is a
  ## reference into a generation, and a property is a byte blob in a
  ## snapshot: storing one would produce a file that cannot be reopened.
  k notin {vkNode, vkEdge, vkPath}

proc encode*(b: var Blob, v: Value) {.gcsafe.} =
  ## Recursive. Depth is bounded by the host's data, so a self-referential
  ## structure cannot be built (Nim values are trees, not graphs), which is
  ## why there is no depth limit here.
  if not storable(v.kind):
    raise newException(ValueError,
      "glyphes: " & $v.kind & " cannot be stored as a property")
  b.putByte(rawTag(propType(v.kind)))
  case v.kind
  of vkNode, vkEdge, vkPath:
    ## Unreachable — `storable` above refuses first. Present so the case is
    ## total: a future variant cannot be added without the compiler
    ## pointing at the codec rather than past it.
    discard
  of vkNull: discard
  of vkBool: b.putByte(if v.b: 1'u8 else: 0'u8)
  of vkInt: b.putI64(v.i)
  of vkFloat: b.putF64(v.f)
  of vkString, vkBytes:
    b.putUvarint(uint64(v.s.len))
    if v.s.len > 0: b.putStr(v.s)
  of vkVector:
    b.putUvarint(uint64(v.dims.len))
    for f in v.dims: b.putF32(f)
  of vkList:
    b.putUvarint(uint64(v.items.len))
    for item in v.items: b.encode(item)
  of vkMap:
    b.putUvarint(uint64(v.pairs.len))
    for (k, val) in v.pairs:
      b.putUvarint(uint64(k.len))
      if k.len > 0: b.putStr(k)
      b.encode(val)

type
  Reader = object
    buf: string
    pos: int

proc fail(msg: string) {.noreturn.} =
  ## A malformed blob is a corrupt snapshot or a bug in this codec, and
  ## both deserve a named error rather than a truncated value.
  raise newException(ValueError, "glyphes: corrupt property blob: " & msg)

proc need(r: Reader, n: int) {.gcsafe.} =
  if r.pos + n > r.buf.len:
    fail("truncated, wanted " & $n & " at " & $r.pos)

proc getByte(r: var Reader): uint8 {.gcsafe.} =
  r.need(1)
  result = byte(r.buf[r.pos])
  inc r.pos

proc getTag(r: var Reader): GlyType {.gcsafe.} =
  GlyType(r.getByte())

proc getBytes(r: var Reader, n: int): string {.gcsafe.} =
  r.need(n)
  if n == 0:
    return ""
  result = r.buf[r.pos ..< r.pos + n]
  r.pos += n

proc getUvarint(r: var Reader): uint64 {.gcsafe.} =
  result = 0'u64
  var shift = 0
  while true:
    let b = r.getByte()
    result = result or (uint64(b and 0x7F'u8) shl shift)
    if (b and 0x80'u8) == 0:
      break
    shift += 7
    if shift > 63:
      fail("uvarint too long")

proc getF32(r: var Reader): float32 {.gcsafe.} =
  r.need(4)
  var bits = 0'u32
  for i in 0 ..< 4:
    bits = bits or (uint32(byte(r.buf[r.pos + i])) shl (i * 8))
  r.pos += 4
  result = cast[float32](bits)

proc getF64(r: var Reader): float64 {.gcsafe.} =
  r.need(8)
  var bits = 0'u64
  for i in 0 ..< 8:
    bits = bits or (uint64(byte(r.buf[r.pos + i])) shl (i * 8))
  r.pos += 8
  result = cast[float64](bits)

proc decode(r: var Reader): Value {.gcsafe.} =
  let tag = r.getTag()
  ## The tag is matched as a GlyType so the case labels are the named
  ## constants rather than bare ordinals — a reordering of GlyType would
  ## then fail to compile here instead of silently decoding the wrong
  ## type. Two bytes (7, 8, 9) are node/edge/path, which cannot be stored
  ## as a property value, so they are named as failures rather than
  ## falling through to the unknown-tag branch.
  case tag
  of glyNull:
    Value(kind: vkNull)
  of glyBool:
    Value(kind: vkBool, b: r.getByte() != 0'u8)
  of glyInt:
    Value(kind: vkInt, i: cast[int64](r.getF64()))
  of glyFloat:
    Value(kind: vkFloat, f: r.getF64())
  of glyString, glyBytes:
    let n = int(r.getUvarint())
    let raw = r.getBytes(n)
    if tag == glyString: Value(kind: vkString, s: raw)
    else: Value(kind: vkBytes, s: raw)
  of glyVector:
    let n = int(r.getUvarint())
    var dims = newSeq[float32](n)
    for i in 0 ..< n: dims[i] = r.getF32()
    Value(kind: vkVector, dims: dims)
  of glyList:
    let n = int(r.getUvarint())
    var items = newSeq[Value](n)
    for i in 0 ..< n: items[i] = r.decode()
    Value(kind: vkList, items: items)
  of glyMap:
    let n = int(r.getUvarint())
    var pairs = newSeq[(string, Value)](n)
    for i in 0 ..< n:
      let klen = int(r.getUvarint())
      let k = r.getBytes(klen)
      pairs[i] = (k, r.decode())
    Value(kind: vkMap, pairs: pairs)
  of glyNode, glyEdge, glyPath:
    fail("node/edge/path cannot be a stored property value")
  else:
    fail("unknown type tag " & $int(rawTag(tag)))

# ----------------------------------------------------------------- inline

proc encodeValue*(v: Value): string {.gcsafe.} =
  ## The arena encoding as a standalone string, for the WAL. Replay
  ## re-encodes through this same pure function, so a value written
  ## through a transaction and replayed from the log produces identical
  ## bytes — which is the property the recovery tests assert rather than
  ## assume.
  var b = Blob(buf: @[])
  b.encode(v)
  ## Blob.buf is a seq[uint8] and an arena blob is a byte string; the
  ## conversion is explicit because conflating the two is how a length
  ## prefix quietly ends up inside a value.
  result = newString(b.buf.len)
  for i, x in b.buf:
    result[i] = char(x)

proc decodeValue*(blob: string): Value {.gcsafe.} =
  var r = Reader(buf: blob, pos: 0)
  r.decode()

proc fitsInline*(v: Value): bool {.gcsafe.} =
  ## S4: scalar, and fits the 8-byte payload. Vectors are never inline,
  ## and neither are containers — a list or map is arena-resident no
  ## matter how small, because an inline container would need its own
  ## header and the payload is already full.
  case v.kind
  of vkNull, vkBool, vkInt, vkFloat: true
  of vkString, vkBytes: v.s.len <= InlinePayload
  else: false

proc elementCount*(v: Value): uint16 {.inline.} =
  ## What goes in `aux`: bytes for str/bytes, dims for a vector, member
  ## count for list/map. Inline scalars carry 0.
  case v.kind
  of vkString, vkBytes: uint16(v.s.len)
  of vkVector: uint16(v.dims.len)
  of vkList: uint16(v.items.len)
  of vkMap: uint16(v.pairs.len)
  else: 0

proc packInline*(slot: var PropSlot, v: Value) {.gcsafe.} =
  slot.sflags = SlotInline
  slot.vtype = propType(v.kind)
  case v.kind
  of vkNull:
    slot.payload = 0
    slot.sflags = SlotNull
    slot.aux = 0
  of vkBool:
    slot.payload = if v.b: 1'u64 else: 0'u64
    slot.aux = 0
  of vkInt:
    slot.payload = cast[uint64](v.i)
    slot.aux = 0
  of vkFloat:
    slot.payload = cast[uint64](v.f)
    slot.aux = 0
  of vkString, vkBytes:
    ## Left-aligned: the length is in aux, so short strings pack into the
    ## payload with no terminator and no header.
    slot.payload = 0
    if v.s.len > 0:
      copyMem(addr slot.payload, unsafeAddr v.s[0], v.s.len)
    slot.aux = uint16(v.s.len)
  else:
    discard

proc unpackInline*(slot: PropSlot): Value {.gcsafe.} =
  ## The aux-payload length relationship is asserted rather than assumed:
  ## an inline string claims its length in aux, and a corrupt aux here
  ## would read past the payload word.
  case slot.vtype
  of glyNull: Value(kind: vkNull)
  of glyBool: Value(kind: vkBool, b: slot.payload != 0'u64)
  of glyInt: Value(kind: vkInt, i: cast[int64](slot.payload))
  of glyFloat: Value(kind: vkFloat, f: cast[float64](slot.payload))
  of glyString, glyBytes:
    let n = int(slot.aux)
    if n > InlinePayload:
      fail("inline length " & $n & " exceeds payload")
    var raw: string
    if n == 0:
      raw = ""
    else:
      raw = newString(n)
      copyMem(addr raw[0], addr slot.payload, n)
    if slot.vtype == glyString: Value(kind: vkString, s: raw)
    else: Value(kind: vkBytes, s: raw)
  else:
    Value(kind: vkNull)

# ------------------------------------------------------------- slot array

proc slotOffset(pv: PropView, i: int32): int32 {.inline.} =
  pv.slotsOff + i * int32(sizeof(PropSlot))

proc findSlot(a: Arena, pv: PropView, key: int32): int32 {.gcsafe.} =
  ## Linear scan (S5). -1 when absent.
  if pv.slotsOff <= 0 or pv.count == 0:
    return -1
  for i in 0 ..< pv.count.int:
    let off = slotOffset(pv, int32(i))
    let p = a.ptrAt(off, sizeof(PropSlot))
    if p == nil:
      return -1                ## corrupt; stop rather than scan past
    var slot: PropSlot
    copyMem(addr slot, p, sizeof(PropSlot))
    if slot.key == key and (slot.sflags and SlotNull) == 0:
      return int32(i)
  -1

proc getProp*(a: Arena, pv: PropView, key: int32, value: var Value): bool {.gcsafe.} =
  let i = findSlot(a, pv, key)
  if i < 0:
    return false
  ## Seqlock read (TXN.md §4). The one writer rewrites a slot in place, so
  ## a reader could otherwise copy 16 bytes across two writes and decode a
  ## half-updated slot — a value whose `aux` came from one commit and whose
  ## payload came from the next. The writer sets `SlotDirty` before the
  ## payload and clears it after, so a reader that catches it mid-write
  ## retries. Bounded: the writer clears the bit before returning.
  var slot: PropSlot
  var attempts = 0
  while attempts < SlotReadRetries:
    copyMem(addr slot, a.ptrAt(slotOffset(pv, i), sizeof(PropSlot)),
            sizeof(PropSlot))
    if (slot.sflags and SlotDirty) == 0:
      break
    inc attempts
  if (slot.sflags and SlotInline) != 0:
    value = unpackInline(slot)
  else:
    let blob = a.getBlob(int32(slot.payload))
    var r = Reader(buf: blob, pos: 0)
    value = r.decode()
  true

proc readSlots*(a: Arena, pv: PropView): seq[PropSlot] {.gcsafe.} =
  ## For tests, for `properties()`, and for compaction. Not on a hot path.
  result = newSeq[PropSlot](pv.count)
  if pv.slotsOff <= 0:
    return
  for i in 0 ..< pv.count.int:
    let p = a.ptrAt(slotOffset(pv, int32(i)), sizeof(PropSlot))
    if p != nil:
      copyMem(addr result[i], p, sizeof(PropSlot))

proc writeSlots(a: var Arena, pv: PropView, slots: openArray[PropSlot],
                start: int32 = 0) {.gcsafe.} =
  ## `start` matters: appending a property writes one slot at index
  ## prop_count, and a version of this that always wrote at index 0 made
  ## every property after the first unreachable. Appending through the
  ## slice's own indices is exactly the bug.
  for i, slot in slots:
    let off = slotOffset(pv, start + int32(i))
    copyMem(a.ptrAt(off, sizeof(PropSlot)), unsafeAddr slot, sizeof(PropSlot))

proc copySlots*(a: var Arena, pv: PropView): PropView {.gcsafe.} =
  ## A private copy of the slot array `pv` addresses: same count and
  ## capacity, new block. A transaction stages a record's properties through
  ## the copy so its writes never touch the array committed readers are
  ## decoding — rollback then drops the delta and the base block is
  ## untouched (TXN.md §3's argument, which an in-place rewrite silently
  ## broke), and no reader can resolve the new block until the commit merge
  ## installs its view. The old block is arena garbage, the documented S9
  ## trade.
  result = pv
  if pv.slotsOff <= 0 or pv.count <= 0:
    return
  let off = a.alloc(pv.capacity * int32(sizeof(PropSlot)))
  if off <= 0:
    raise newException(ValueError, "glyphes: arena exhausted staging property slots")
  result.slotsOff = off
  writeSlots(a, result, a.readSlots(pv))

proc decodeInlineValue*(slot: PropSlot): Value {.gcsafe.} =
  ## Replay's entry point for an inline value: the log carries the raw
  ## 8-byte word, and this turns it back into a Value. Public because
  ## recovery must not reach into prop.nim's private unpacker.
  unpackInline(slot)

proc ensureCapacity(a: var Arena, pv: var PropView, needed: int32) {.gcsafe.} =
  ## Amortized doubling (STORAGE.md §10, settled at M1). The old array
  ## is left to `vacuum` like any other arena garbage; writes stay O(1)
  ## amortized and never pay an allocation per property set.
  if needed <= pv.capacity:
    return
  var newCap = pv.capacity
  if newCap < InitialSlotCapacity:
    newCap = InitialSlotCapacity
  while newCap < needed:
    newCap = newCap * 2
  let off = a.alloc(newCap * int32(sizeof(PropSlot)))
  if off <= 0:
    raise newException(ValueError, "glyphes: arena exhausted growing property slots")
  if pv.slotsOff > 0 and pv.count > 0:
    let p = a.ptrAt(pv.slotsOff, pv.count * int32(sizeof(PropSlot)))
    if p != nil:
      copyMem(a.ptrAt(off, pv.count * int32(sizeof(PropSlot))), p,
              pv.count.int * sizeof(PropSlot))
  pv.slotsOff = off
  pv.capacity = newCap

proc removeProp*(a: var Arena, pv: var PropView, key: int32): bool {.gcsafe.}

proc setProp*(a: var Arena, pv: var PropView, key: int32, v: Value): bool {.gcsafe.} =
  ## Returns true if the key already existed (i.e. this replaced a value).
  if key <= 0:
    raise newException(ValueError, "glyphes: property key code must be positive")

  # A null value removes the property rather than storing a null, which is
  # what Cypher's REMOVE means and what keeps `keys(n)` honest.
  if v.kind == vkNull:
    return removeProp(a, pv, key)

  var slots = readSlots(a, pv)
  for i in 0 ..< slots.len:
    if slots[i].key == key and (slots[i].sflags and SlotNull) == 0:
      var slot = slots[i]
      slot.sflags = slot.sflags and not SlotNull.byte
      if fitsInline(v):
        slot.payload = 0
        packInline(slot, v)
        slots[i] = slot
        writeSlots(a, pv, slots)
      else:
        # The previous blob, if any, is arena garbage. That is the
        # documented trade (STORAGE.md S9): a repeated SET of an
        # overflowing property leaks the old bytes until `vacuum`, which
        # is cheaper than a free list on a bump allocator.
        var blob = Blob(buf: @[])
        blob.encode(v)
        slot.vtype = propType(v.kind)
        slot.aux = elementCount(v)
        slot.payload = 0
        slot.payload = uint64(a.putBlob(blob.buf))
        slot.sflags = SlotDirty
        slots[i] = slot
        writeSlots(a, pv, slots)
        # Seqlock publish (TXN.md §4): the payload is in place, so clear
        # the bit and let any reader that was waiting proceed. This
        # second write is the cost of letting a reader retry rather than
        # decode a slot mid-update.
        slot.sflags = slot.sflags and not SlotDirty.byte
        slots[i] = slot
        writeSlots(a, pv, slots)
      return true

  # New key.
  a.ensureCapacity(pv, pv.count + 1)
  var slot = PropSlot(key: key, vtype: propType(v.kind), sflags: SlotDirty,
                      aux: 0, payload: 0)
  if fitsInline(v):
    packInline(slot, v)
  else:
    var blob = Blob(buf: @[])
    blob.encode(v)
    slot.payload = uint64(a.putBlob(blob.buf))
    slot.aux = elementCount(v)
  ## Append at the end, not at index 0. See writeSlots' `start`.
  a.writeSlots(pv, [slot], pv.count)
  # Seqlock publish, as above.
  slot.sflags = slot.sflags and not SlotDirty.byte
  a.writeSlots(pv, [slot], pv.count)
  pv.count += 1
  false

proc removeProp*(a: var Arena, pv: var PropView, key: int32): bool {.gcsafe.} =
  ## Compacts the array rather than tombstoning a slot: `prop_count` is
  ## small and `findSlot` treats 0 as absent, so a hole would work but
  ## would make `keys(n)` and the capacity check more subtle for no gain.
  var slots = readSlots(a, pv)
  var found = false
  var w = 0
  for slot in slots:
    if slot.key == key and (slot.sflags and SlotNull) == 0 and not found:
      found = true
      continue
    slots[w] = slot
    inc w
  if not found:
    return false
  slots.setLen(w)
  pv.count = int32(w)
  if w == 0:
    # Release the array so a node with no properties costs no arena.
    pv.slotsOff = 0
    pv.capacity = 0
    return true
  a.writeSlots(pv, slots)
  true

proc clearProps*(a: var Arena, pv: var PropView) {.gcsafe.} =
  pv.slotsOff = 0
  pv.capacity = 0
  pv.count = 0

proc propCount*(pv: PropView): int {.inline.} = pv.count.int
