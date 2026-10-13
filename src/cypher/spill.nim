## glyphes — spilled sort runs (M5.6).
##
## `ORDER BY` is a barrier: every row must be compared against every other
## before the first one is handed out, so the operator buffers. For 10^7 rows
## that buffer is not a tuning problem, it is the process — a row is a seq
## of (name, Value) pairs and the sum of ten million of them is measured in
## gigabytes. So the sort spills: sort a run in memory, write it out, start
## again, and k-way merge the runs at the end.
##
## What is written is the *whole row*, not the sort keys, because the sort
## sits above the projection and everything downstream — `SKIP`, `LIMIT`,
## the caller's columns — reads the row's other slots. A run of keys that
## had to be joined back would mean a second pass over the input or a second
## copy of it in memory, which is the thing being avoided.

import ../store/prop
import ./ctx
import ./errors
import ../abi

type
  RunWriter* = ref object
    ## One spilled run, open for appending. The count is in the header
    ## rather than here because a run's length is what the merge needs, and
    ## deriving it from the file would mean seeking backwards.
    file*: File

  RunReader* = ref object
    ## One run, open for reading. `eof` is a real flag rather than a
    ## try-parse: the last row of a run and a truncated run look identical
    ## to `readRow`, and the difference between "finished" and "corrupt" is
    ## the difference between a clean query and a wrong one.
    file: File
    count*: int64
    remaining*: int64
    path*: string

const
  ## One byte of type tag per value, then the payload. The tags are the
  ## `ValueKind` ordinals, written as one byte — a spilled row of ten
  ## million is on disk once, and halving it would mean a second encoding
  ## to keep in step with the first.
  SpillMagic* = "glyspill1"

proc writeUvarint(f: File, v: uint64) =
  ## LEB128: seven bits per byte, low first, high bit set on every byte but
  ## the last. A row's slot count and its string lengths are almost always
  ## small, and a fixed 8 bytes each would triple the file.
  var n = v
  while n >= 0x80'u64:
    f.write(char((n and 0x7F'u64) or 0x80'u64))
    n = n shr 7
  f.write(char(n and 0x7F'u64))

proc readUvarint(f: File, v: var uint64) =
  var n = 0'u64
  var shift = 0
  while true:
    let c = f.readChar()
    n = n or ((uint64(ord(c) and 0x7F) shl shift))
    if ord(c) < 0x80:
      break
    shift += 7
    if shift > 63:
      cypherFail(int32(glyErrSql), "a spilled run is corrupt: length varint too long")
  v = n

proc readBytes(f: File, n: int, path: string): string =
  ## Exactly `n` bytes or an error. `readStr` would do, but this file is
  ## the boundary where a truncated run must stop rather than return a short
  ## string that decodes into the next row's bytes.
  if n <= 0:
    return ""
  result = newString(n)
  if f.readBuffer(addr result[0], n) != n:
    cypherFail(int32(glyErrSql), "spilled run " & path & " ended mid-value")

proc writeU64(f: File, v: uint64) =
  ## Eight little-endian bytes by hand: `File` has no integer readers, and
  ## this runs once per scalar of a 10^7-row spill.
  var buf: array[8, char]
  for i in 0 .. 7:
    buf[i] = char((v shr (8 * i)) and 0xFF'u64)
  discard f.writeBuffer(addr buf[0], 8)

proc readU64(f: File): uint64 =
  var buf: array[8, char]
  if f.readBuffer(addr buf[0], 8) != 8:
    cypherFail(int32(glyErrSql), "a spilled run ended in the middle of a number")
  result = 0'u64
  for i in 0 .. 7:
    result = result or (uint64(ord(buf[i])) shl (8 * i))

proc writeValue(f: File, v: Value) =
  f.write(char(ord(v.kind)))
  case v.kind
  of vkNull:
    discard
  of vkBool:
    f.write(char(if v.b: 1 else: 0))
  of vkInt:
    writeUvarint(f, cast[uint64](v.i))
  of vkFloat:
    ## The bit pattern, not the text: `formatFloat` is locale- and
    ## round-trip-sensitive, and a sort key that comes back one ulp
    ## different has silently reordered equal keys.
    writeU64(f, cast[uint64](v.f))
  of vkString, vkBytes:
    writeUvarint(f, uint64(v.s.len))
    f.write(v.s)
  of vkVector:
    writeUvarint(f, uint64(v.dims.len))
    for d in v.dims:
      writeU64(f, cast[uint64](d))
  of vkList:
    writeUvarint(f, uint64(v.items.len))
    for item in v.items:
      writeValue(f, item)
  of vkMap:
    writeUvarint(f, uint64(v.pairs.len))
    for (key, item) in v.pairs:
      writeUvarint(f, uint64(key.len))
      f.write(key)
      writeValue(f, item)
  of vkNode, vkEdge:
    writeUvarint(f, cast[uint64](v.id))
  of vkPath:
    writeUvarint(f, uint64(v.path.nodes.len))
    for id in v.path.nodes:
      writeUvarint(f, cast[uint64](id))
    writeUvarint(f, uint64(v.path.edges.len))
    for id in v.path.edges:
      writeUvarint(f, cast[uint64](id))
    writeUvarint(f, uint64(v.path.dirs.len))
    for d in v.path.dirs:
      f.write(char(d))

proc readValue(f: File, v: var Value, path: string) =
  let tag = ord(f.readChar())
  if tag > ord(high(ValueKind)):
    cypherFail(int32(glyErrSql), "a spilled run is corrupt: unknown value tag " & $tag)
  v = Value(kind: ValueKind(tag))
  case v.kind
  of vkNull:
    discard
  of vkBool:
    v.b = ord(f.readChar()) != 0
  of vkInt:
    var n = 0'u64
    readUvarint(f, n)
    v.i = cast[int64](n)
  of vkFloat:
    v.f = cast[float64](readU64(f))
  of vkString, vkBytes:
    var n = 0'u64
    readUvarint(f, n)
    v.s = readBytes(f, int(n), path)
  of vkVector:
    var n = 0'u64
    readUvarint(f, n)
    v.dims = newSeq[float32](int(n))
    for i in 0 ..< v.dims.len:
      v.dims[i] = cast[float32](readU64(f))
  of vkList:
    var n = 0'u64
    readUvarint(f, n)
    v.items = newSeq[Value](int(n))
    for i in 0 ..< v.items.len:
      readValue(f, v.items[i], path)
  of vkMap:
    var n = 0'u64
    readUvarint(f, n)
    v.pairs = newSeq[(string, Value)](int(n))
    for i in 0 ..< v.pairs.len:
      var k = 0'u64
      readUvarint(f, k)
      v.pairs[i][0] = readBytes(f, int(k), path)
      readValue(f, v.pairs[i][1], path)
  of vkNode, vkEdge:
    var n = 0'u64
    readUvarint(f, n)
    v.id = cast[int64](n)
  of vkPath:
    var n = 0'u64
    readUvarint(f, n)
    v.path.nodes = newSeq[int64](int(n))
    for i in 0 ..< v.path.nodes.len:
      var id = 0'u64
      readUvarint(f, id)
      v.path.nodes[i] = cast[int64](id)
    readUvarint(f, n)
    v.path.edges = newSeq[int64](int(n))
    for i in 0 ..< v.path.edges.len:
      var id = 0'u64
      readUvarint(f, id)
      v.path.edges[i] = cast[int64](id)
    readUvarint(f, n)
    v.path.dirs = newSeq[uint8](int(n))
    for i in 0 ..< v.path.dirs.len:
      v.path.dirs[i] = uint8(ord(f.readChar()))

proc writeRow*(f: File, row: Row) =
  writeUvarint(f, uint64(row.slots.len))
  for (name, value) in row.slots:
    writeUvarint(f, uint64(name.len))
    f.write(name)
    writeValue(f, value)

proc readRow*(f: File, row: var Row, path: string): (bool, bool) =
  ## `(read, ok)` — false `read` at the end of a run. The count is checked rather than
  ## inferred, so a short read is corruption and the end of the data is
  ## not; the alternative is a query that answers with the rows it managed
  ## to read and no error at all.
  if f.getFilePos() >= f.getFileSize():
    return (false, true)
  var n = 0'u64
  readUvarint(f, n)
  var slots = newSeq[(string, Value)](int(n))
  for i in 0 ..< slots.len:
    var k = 0'u64
    readUvarint(f, k)
    slots[i][0] = readBytes(f, int(k), path)
    readValue(f, slots[i][1], path)
  row.slots = slots
  (true, true)

proc openRunWriter*(path: string, rows: int64): RunWriter =
  result = RunWriter()
  if not open(result.file, path, fmWrite):
    cypherFail(int32(glyErrSql), "cannot spill a sort run to " & path)
  ## The row count goes in the header, not at the end: the merge needs to
  ## know when a run is finished, and the end of a file is also what a
  ## truncated run looks like.
  result.file.write(SpillMagic)
  writeUvarint(result.file, cast[uint64](rows))

proc closeRun*(run: RunWriter) =
  if not run.file.isNil:
    run.file.close()

proc openRunReader*(path: string): RunReader =
  result = RunReader(path: path)
  if not open(result.file, path, fmRead):
    cypherFail(int32(glyErrSql), "cannot read the spilled sort run " & path)
  ## The file must be at least the header. A zero-length file is what a
  ## crash between create and write leaves behind, and reading it as "no
  ## rows" would answer the query with nothing.
  if result.file.getFileSize() < int64(SpillMagic.len + 1):
    cypherFail(int32(glyErrSql), "spilled sort run " & path & " is empty")
  let magic = readBytes(result.file, SpillMagic.len, path)
  if magic != SpillMagic:
    cypherFail(int32(glyErrSql),
         "spilled sort run " & path & " is corrupt: another format (" & magic & ")")
  var n = 0'u64
  readUvarint(result.file, n)
  result.count = cast[int64](n)
  result.remaining = result.count

proc nextRow*(run: RunReader, row: var Row): bool =
  if run.remaining <= 0:
    return false
  let (read, ok) = readRow(run.file, row, run.path)
  if not ok:
    cypherFail(int32(glyErrSql), "spilled sort run " & run.path & " is truncated")
  if not read:
    ## Fewer rows than the header promised. Refused rather than answered
    ## with the rows that survived: a sort that silently loses rows is a
    ## wrong answer wearing a correct row count.
    cypherFail(int32(glyErrSql),
         "spilled sort run " & run.path & " ended after " & $run.count & " rows")
  dec run.remaining
  true

proc closeRun*(run: RunReader) =
  if not run.file.isNil:
    run.file.close()