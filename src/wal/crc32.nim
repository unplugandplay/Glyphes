## glyphes — CRC32 (WAL.md §2)
##
## The IEEE 802.3 polynomial, reflected: 0xEDB88320. Chosen over a faster
## hash because it is a standard with published test vectors, and this
## project's crash gate depends on being able to reproduce a corrupt frame
## across machines and across years. A hash that is merely fast is not
## checkable by anyone else.
##
## Table-driven, generated once. 1 GB/s would be wasted here: the WAL is
## bounded to tens of MB between checkpoints.

import std/locks

const
  Poly = 0xEDB88320'u32

var
  table: array[256, uint32]
  tableReady = false
  tableLock: Lock

proc buildTable() =
  ## `initLock` on a `Lock` that is only ever touched here is fine; the
  ## first crc32 call can arrive on any thread.
  initLock(tableLock)
  for i in 0 ..< 256:
    var c = uint32(i)
    for k in 0 ..< 8:
      c = if (c and 1) != 0: (c shr 1) xor Poly else: c shr 1
    table[i] = c
  tableReady = true

proc initCrc32() =
  if not tableReady:
    withLock tableLock:
      if not tableReady:
        buildTable()

proc crc32*(data: openArray[uint8]; seed: uint32 = 0): uint32 {.inline.} =
  ## Non-destructive: `crc32(header[0..20] & payload)` is expressed as a
  ## second call with `seed` set, so no scratch buffer is needed and a
  ## large payload is not copied just to be checksummed.
  initCrc32()
  var c = seed xor 0xFFFFFFFF'u32
  for b in data:
    c = table[(c xor uint32(b)) and 0xFF'u32] xor (c shr 8)
  result = c xor 0xFFFFFFFF'u32

proc crc32*(s: string; seed: uint32 = 0): uint32 =
  ## An empty string has no bytes to walk. Walking zero bytes leaves the
  ## running value at `seed xor FFFFFFFF` and finalization XORs it back, so
  ## the answer is the seed unchanged. Spelled out rather than reached by
  ## a call with an empty openArray, which Nim cannot infer.
  if s.len == 0:
    return seed
  crc32(s.toOpenArrayByte(0, s.high), seed)


when isMainModule:
  ## Published test vectors, so a future change to the polynomial or the
  ## reflection is caught here rather than by an unrecoverable WAL.
  assert crc32("", 0) == 0x00000000'u32
  assert crc32("a") == 0xE8B7BE43'u32
  assert crc32("abc") == 0x352441C2'u32
  assert crc32("123456789") == 0xCBF43926'u32
  assert crc32("The quick brown fox jumps over the lazy dog") == 0x414FA339'u32
  echo "crc32: vectors ok"
