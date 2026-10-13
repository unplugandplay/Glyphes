## glyphes — the Nim mirror of src/glyphes.h (ABI.md)
##
## Types come from the header with {.importc.} rather than being declared
## here, so the C compiler's view of GlyCell/GlyPath/GlyStat is the
## header's and not a Nim guess. The pure constants (status names, open
## modes) are duplicated because they are enums and flags, and Nim needs
## them to be Nim values.
##
## This module declares. src/glyphes.nim implements and exports.

{.push raises: [].}

import std/os
import std/strformat

## Put this module's own directory on the C include path, so
## {.importc, header: "glyphes.h".} resolves when the module is compiled
## as part of the test runner rather than as part of the library. The
## library build adds the same flag from src/glyphes.nim; a module that
## only works under one of the two builds is a module that breaks the
## first time someone compiles it a third way.
{.passC: "-I" & currentSourcePath().splitFile.dir.}

type
  GlyStatus* {.importc: "GlyStatus", header: "glyphes.h".} = cint
  ## Nim's `uint` is uintptr_t on every target glyphes supports.
  GlyHandle* {.importc: "GlyHandle", header: "glyphes.h".} = uint

  GlyType* {.importc: "GlyType", header: "glyphes.h".} = uint32
    ## Value tags. Kept in the same order as the C enum; ffi.rb asserts
    ## the ordinals agree.

  GlyCell* {.importc: "GlyCell", header: "glyphes.h", bycopy.} = object
    ## 24 bytes on LP64. See ABI.md §1.
    tag* {.importc: "tag".}: uint32
    len* {.importc: "len".}: uint32
    `ptr`* {.importc: "ptr".}: pointer
    aux* {.importc: "aux".}: uint64

  GlyPath* {.importc: "GlyPath", header: "glyphes.h", bycopy.} = object
    ## Borrowed view of a GLY_PATH cell's arena memory.
    count* {.importc: "count".}: uint32
    nodes* {.importc: "nodes".}: ptr int64
    edges* {.importc: "edges".}: ptr int64
    dirs* {.importc: "dirs".}: ptr uint8

  GlyStat* {.importc: "GlyStat", header: "glyphes.h", bycopy.} = object
    nodes* {.importc: "nodes".}: uint64
    edges* {.importc: "edges".}: uint64
    labels* {.importc: "labels".}: uint64
    relTypes* {.importc: "rel_types".}: uint64
    properties* {.importc: "properties".}: uint64
    bytesResident* {.importc: "bytes_resident".}: uint64
    walBytes* {.importc: "wal_bytes".}: uint64
    generation* {.importc: "generation".}: uint64

  GlyTxInfo* {.importc: "GlyTxInfo", header: "glyphes.h", bycopy.} = object
    id* {.importc: "id".}: uint64
    nodesWritten* {.importc: "nodes_written".}: uint64
    edgesWritten* {.importc: "edges_written".}: uint64
    propertiesWritten* {.importc: "properties_written".}: uint64
    walBytes* {.importc: "wal_bytes".}: uint64

const
  glyOk* = GlyStatus(0)
  glyMore* = GlyStatus(1)               ## batch full, more rows remain
  glyDone* = GlyStatus(2)               ## row stream exhausted
  glyErr* = GlyStatus(-1)
  glyErrClosed* = GlyStatus(-2)
  glyErrStale* = GlyStatus(-3)
  glyErrSql* = GlyStatus(-4)
  glyErrConstraint* = GlyStatus(-5)
  glyErrIo* = GlyStatus(-6)
  glyErrReadOnly* = GlyStatus(-7)
  glyErrBusy* = GlyStatus(-8)
  glyErrLimit* = GlyStatus(-9)
  glyErrNoMem* = GlyStatus(-10)
  glyErrUnsupported* = GlyStatus(-11)
  ## The file is damaged: a frame or a snapshot region failed its CRC, or
  ## a magic did not match. This is deliberately *not* the torn tail, which
  ## is a frame that was never finished and is correct to drop. A finished
  ## frame whose content does not match its checksum is damage, and a
  ## database that opened it anyway would serve truncated data with no
  ## error anywhere — so this is a named error and the file is left alone
  ## for the operator to inspect.
  glyErrCorrupt* = GlyStatus(-12)

const
  GLY_OPEN_READONLY* = 1 shl 0
  ## Header enums, mirrored here so the flag checks are one place. The
  ## C side keeps them in `glyphes.h`; a constant duplicated in two files
  ## is a constant that will drift, so every use goes through this block.
  GLY_SCHEMA_LABELS* = 1 shl 2
  GLY_SCHEMA_PROPERTIES* = 1 shl 3
  GLY_SCHEMA_INDEXES* = 1 shl 4
  GLY_CHECKPOINT_TRUNCATE* = 1 shl 0
  GLY_CHECKPOINT_FSYNC* = 1 shl 1
  GLY_OPEN_CREATE* = 1 shl 1
  GLY_OPEN_MEMORY* = 1 shl 2
  GLY_OPEN_SNAPSHOT* = 1 shl 3

const
  GLYPHES_VERSION_MAJOR* = 0
  GLYPHES_VERSION_MINOR* = 1
  GLYPHES_VERSION_PATCH* = 0

proc statusCode*(s: GlyStatus): int {.inline.} = int(s)
proc statusIsOk*(s: GlyStatus): bool {.inline.} = s == glyOk
proc statusIsError*(s: GlyStatus): bool {.inline.} = int(s) < 0

proc statusName*(s: GlyStatus): string =
  ## Name exactly as the C enum spells it, so an error message can be
  ## grepped against the header, the Nim source, and the Ruby binding.
  case int(s)
  of 0: "GLY_OK"
  of 1: "GLY_MORE"
  of 2: "GLY_DONE"
  of -1: "GLY_ERR"
  of -2: "GLY_ERR_CLOSED"
  of -3: "GLY_ERR_STALE"
  of -4: "GLY_ERR_SQL"
  of -5: "GLY_ERR_CONSTRAINT"
  of -6: "GLY_ERR_IO"
  of -7: "GLY_ERR_READONLY"
  of -8: "GLY_ERR_BUSY"
  of -9: "GLY_ERR_LIMIT"
  of -10: "GLY_ERR_NOMEM"
  of -11: "GLY_ERR_UNSUPPORTED"
  else: &"GLY_ERR_UNKNOWN({int(s)})"

{.pop.}
