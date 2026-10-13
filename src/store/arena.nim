## glyphes — the property arena (STORAGE.md §3)
##
## One append-only byte arena per store. Records hold *offsets*, never
## pointers (STORAGE.md S3), so a record array is serializable and
## mmap-able with no fixup pass, and an id from a snapshot is valid in
## the new process without translation.
##
## Offset 0 is reserved as "no arena reference". The arena therefore
## starts handing out offsets at 8, leaving the first 8 bytes as a hole.
## Every record field that holds an offset uses 0 for none, and a hole
## is cheaper than a branch on every access.

import std/strutils

type
  Arena* = object
    bytes*: seq[uint8]
    bump*: int

const
  ArenaFirstOffset* = 8    ## the hole that makes 0 mean "none"
  ArenaAlign* = 8

proc initArena*(a: var Arena, capacity: int = 0) {.gcsafe.} =
  ## `capacity` is a hint, not a promise: it is a floor for the first
  ## allocation, so a bulk importer sizes the arena once instead of
  ## watching it double 20 times on the way to a gigabyte.
  a.bytes = newSeqOfCap[uint8](max(capacity, ArenaFirstOffset * 4))
  a.bump = ArenaFirstOffset

proc alloc*(a: var Arena, n: int): int32 {.gcsafe.} =
  ## Bump-allocate `n` bytes, 8-aligned.
  ##
  ## Returns 0 for an empty request, which is the "no arena reference"
  ## sentinel and therefore the right answer rather than a distinct code;
  ## and -1 for a negative size, which is a caller bug. Never returns 0
  ## for a real allocation (see ArenaFirstOffset).
  ##
  ## Freed by nothing until `vacuum` (STORAGE.md S9): an overwritten
  ## property's old bytes stay until compaction. That is the standard
  ## copy-on-write storage trade — writes are O(1) and allocation-free,
  ## and the cost is reclaimed in one pass at checkpoint.
  if n < 0:
    return -1
  if n == 0:
    return 0
  let size = ((n + ArenaAlign - 1) div ArenaAlign) * ArenaAlign
  if a.bump + size > a.bytes.len:
    let want = a.bytes.len
    let grown = max(a.bump + size, if want == 0: 1024 else: want * 2)
    a.bytes.setLen(grown)
  result = int32(a.bump)
  a.bump += size

proc copyIn*(a: var Arena, src: openArray[uint8]): int32 {.gcsafe.} =
  result = a.alloc(src.len)
  if result <= 0: return
  copyMem(addr a.bytes[result.int], unsafeAddr src[0], src.len)

proc copyIn*(a: var Arena, src: string): int32 {.gcsafe.} =
  copyIn(a, src.toOpenArrayByte(0, src.high))

proc ptrAt*(a: Arena, offset: int32, n: int): ptr uint8 {.inline.} =
  ## Bounds-checked view. Named ptrAt rather than `addr` because `addr`
  ## is a Nim keyword and `a.addr(...)` tokenizes as the keyword.
  ##
  ## `n` is the *requested* length, and a short read
  ## returns nil rather than a pointer into the next allocation, which
  ## is the failure mode a corrupt snapshot would otherwise produce.
  if offset <= 0:
    return nil
  let o = offset.int
  if o + n > a.bump:
    return nil
  ## Unchecked by design: `ptrAt` has already bounds-checked against
  ## `bump`, and a second bounds check here would be on the read path of
  ## every property access.
  result = cast[ptr uint8](unsafeAddr a.bytes[o])

proc read*(a: Arena, offset: int32, n: int): string {.gcsafe.} =
  let p = a.ptrAt(offset, n)
  if p == nil or n == 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], p, n)

proc slice*(a: Arena, offset: int32, start, n: int): string {.gcsafe.} =
  ## A sub-range of an arena blob. The tag byte is read separately by
  ## prop.nim, so this is how a string inside a list is reached.
  let p = a.ptrAt(offset + int32(start), n)
  if p == nil or n == 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], p, n)

# ------------------------------------------------------------------ blobs

proc putBlob*(a: var Arena, data: openArray[uint8]): int32 {.gcsafe.} =
  ## A length-prefixed byte string. The prefix is what makes a blob
  ## readable: a bump allocator knows only its own high-water mark, so
  ## without a length there is no way to tell where one blob ends and the
  ## next begins. (This was a real M1 bug — reads ran to the end of the
  ## arena and every overflow value came back empty.)
  ##
  ## An empty blob stores nothing and returns 0. A 1-byte prefix holding
  ## zero would be readable but pointless, and 0 is the sentinel every
  ## caller already handles.
  if data.len == 0:
    return 0
  var lenByte: array[10, uint8]
  var n = data.len
  var i = 0
  var v = uint64(n)
  while v >= 0x80'u64:
    lenByte[i] = uint8((v and 0x7F'u64) or 0x80'u64)
    inc i
    v = v shr 7
  lenByte[i] = uint8(v)
  inc i

  let off = a.alloc(i + n)
  if off <= 0:
    return off
  copyMem(addr a.bytes[off.int], addr lenByte[0], i)
  if n > 0:
    copyMem(addr a.bytes[off.int + i], unsafeAddr data[0], n)
  result = off

proc blobLen(a: Arena, offset: int32): int {.inline.} =
  ## Read the varint prefix without trusting it: a length that runs past
  ## `bump` means a corrupt snapshot, and the caller must get nil rather
  ## than a huge allocation.
  if offset <= 0:
    return -1
  var pos = offset.int
  var shift = 0
  result = 0
  while pos < a.bump:
    let b = int(a.bytes[pos])
    result = result or ((b and 0x7F) shl shift)
    inc pos
    if (b and 0x80) == 0:
      if pos + result > a.bump:
        return -1
      return
    shift += 7
    if shift > 63:
      return -1

proc getBlob*(a: Arena, offset: int32): string {.gcsafe.} =
  let n = a.blobLen(offset)
  if n <= 0:
    return ""
  var lenSize = 1
  var v = n
  while v >= 0x80:
    inc lenSize
    v = v shr 7
  result = a.read(offset + int32(lenSize), n)

proc used*(a: Arena): int {.inline.} = a.bump - ArenaFirstOffset
proc capacity*(a: Arena): int {.inline.} = a.bytes.len
