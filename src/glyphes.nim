## glyphes — the exported C surface.
##
## This is the only module with {.exportc.} on it. Everything else is
## ordinary Nim that raises; every crossing from Nim semantics to C
## semantics happens here, in one file, so the boundary is auditable by
## reading this and src/glyphes.h.
##
## The rule for every proc below (ABI.md B8):
##   - takes GlyHandle values and out-params, never Nim objects;
##   - returns a GlyStatus, never lets an exception escape;
##   - keeps a handle-local or thread-global message for the host.
##
## `{.dynlib.}` on each export is load-bearing. Without it Nim emits
## N_LIB_PRIVATE (visibility hidden) and the symbol is unreachable from
## dlopen while still linking cleanly — see src/ffi.nim's header comment.

{.push raises: [].}


import std/[os, strutils, tables]

import ./abi
import ./handles
import ./errors
import ./index/index
import ./index/vector
import ./database
import ./txn/txn
import ./cypher/execute
import ./cypher/params
import ./store/prop
import ./store/store
import ./cypher/errors
import ./cypher/expr

{.passC: "-I" & currentSourcePath().splitFile.dir.}
when defined(dll):
  {.compile: "glyphes_init.c".}
  ## Put src/ on the C include path so {.importc, header: "glyphes.h".}
  ## in abi.nim resolves to src/glyphes.h. A missing -I here fails at
  ## C compile time with "glyphes.h: No such file", which is a confusing
  ## way to learn that.
  ##
  ## The constructor is compiled into the shared library and nothing else.
  ## It exists because `--app:lib` emits module initialization into an
  ## exported `NimMain` that nobody calls, and a dlopen'd dylib that skips
  ## it segfaults inside its own allocator on the first allocation. An
  ## executable has no such problem — its own startup runs NimMain — and a
  ## second call re-initializes the heap under it, which shows up as a
  ## nondeterministic crash or a nonsense object count in whichever test
  ## happened to allocate first. `defined(dll)` is true exactly for
  ## `--app:lib`, so the boundary is automatic rather than a flag every
  ## test task has to remember.

template guarded(name: string, body: untyped): int32 =
  ## The single place a Nim failure becomes a GlyStatus. Written once
  ## rather than copied into every proc because eight copies of a
  ## four-arm ladder is eight places for the ordering of the arms to
  ## drift — and the order is load-bearing twice over: `GlyError` and
  ## `TxError` both derive from CatchableError and each carries the
  ## specific status, so catching the base class first would flatten
  ## GLY_ERR_BUSY and GLY_ERR_READONLY into GLY_ERR.
  ##
  ## A Defect is reported as GLY_ERR with "DEFECT" in the message rather
  ## than downgraded silently: it cannot be allowed to unwind into Ruby,
  ## but the host process is in an unknown state and deserves to know.
  try:
    ## Per-thread allocator setup, before anything can allocate.
    ##
    ## A Ruby thread calling into the engine is a foreign thread as far as
    ## Nim is concerned: ORC keeps a page cache per thread, and the first
    ## `new` from a thread that has never been initialised dereferences
    ## that nil cache pointer and takes the host process down. The GIL
    ## does not help — it serialises Ruby bytecode, and two Ruby threads
    ## still enter the engine from two different OS threads.
    ##
    ## TXN.md §7 promises exactly this: concurrent `tx_begin` on one `db`
    ## is safe and the losers get `GLY_ERR_BUSY`. That promise is only
    ## keepable if a Ruby thread can allocate in the engine. The call has
    ## a thread-local guard, so it costs a compare once the thread is set
    ## up.
    setupForeignThreadGc()
    body
  except GlyError as e:
    setGlobalError(e.msg)
    int32(e.status)
  except TxError as e:
    setGlobalError(name & ": " & e.msg)
    ## TxCode's numbers are the GlyStatus numbers on purpose (txn.nim).
    int32(e.code)
  except CypherError as e:
    ## Must sit above the CatchableError arm: a query error already carries
    ## the status the host is owed — GLY_ERR_SQL for a typo, GLY_ERR_UNSUPPORTED
    ## for a named M5+ construct — and flattening both into GLY_ERR is the
    ## wrong-answer-by-mapping PRD §5.1 forbids. The message needs no
    ## proc-name prefix: parse errors carry their own file:line:col.
    setGlobalError(e.msg)
    int32(e.code)
  except CatchableError as e:
    setGlobalError(name & ": " & e.msg)
    int32(glyErr)
  except Exception as e:
    setGlobalError(name & ": DEFECT " & e.msg)
    int32(glyErr)

# ---------------------------------------------------------------- version

proc glyphes_version*(major: ptr uint32, minor: ptr uint32,
                     patch: ptr uint32): int32 {.cdecl, exportc, dynlib.} =
  if major != nil: major[] = uint32(GLYPHES_VERSION_MAJOR)
  if minor != nil: minor[] = uint32(GLYPHES_VERSION_MINOR)
  if patch != nil: patch[] = uint32(GLYPHES_VERSION_PATCH)
  0

# ------------------------------------------------------------------ error

proc glyphes_global_error*(): cstring {.cdecl, exportc, dynlib.} =
  ## Owned by the engine's error slot and replaced on the next set, so
  ## the host copies it and never frees it (B1: no engine-allocated
  ## memory crosses the boundary). Valid until the next call on this
  ## thread — ffi.rb copies immediately.
  result = globalErrorCStr()

proc glyphes_global_error_clear*() {.cdecl, exportc, dynlib.} =
  clearGlobalError()

# ------------------------------------------------------------------- open

proc glyphes_open*(path: cstring, mode: int32, outDb: ptr GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  if outDb == nil:
    setGlobalError("glyphes_open: out_db is null")
    return int32(glyErr)
  outDb[] = 0
  guarded("glyphes_open"):
    if path == nil:
      fail(glyErr, "glyphes_open: path is null")
    ## $path copies the C string into Nim's own buffer immediately, so
    ## the caller is free to free or reuse its buffer the moment this
    ## returns (B1: no borrowed pointers cross).
    let db = openDatabase($path, mode)
    outDb[] = register(hkDatabase, db)
    int32(glyOk)

proc glyphes_close*(h: GlyHandle): int32 {.cdecl, exportc, dynlib.} =
  if not isLive(h):
    setGlobalError("glyphes_close: stale handle")
    return int32(glyErrStale)
  if not isKind(h, hkDatabase):
    setGlobalError("glyphes_close: handle is not a database")
    return int32(glyErrStale)
  guarded("glyphes_close"):
    let db = lookup[Database](h, hkDatabase)
    close(db)
    discard release[Database](h)
    int32(glyOk)

proc glyphes_stat*(h: GlyHandle, outStat: ptr GlyStat): int32
    {.cdecl, exportc, dynlib.} =
  if outStat == nil:
    setGlobalError("glyphes_stat: out is null")
    return int32(glyErr)
  if not isLive(h):
    setGlobalError("glyphes_stat: stale handle")
    return int32(glyErrStale)
  if not isKind(h, hkDatabase):
    setGlobalError("glyphes_stat: handle is not a database")
    return int32(glyErrStale)
  guarded("glyphes_stat"):
    let db = lookup[Database](h, hkDatabase)
    outStat[] = statOf(db)
    int32(glyOk)

# ------------------------------------------------------------ transactions

proc glyphes_tx_begin*(h: GlyHandle, outTx: ptr GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  if outTx == nil:
    setGlobalError("glyphes_tx_begin: out_tx is null")
    return int32(glyErr)
  outTx[] = 0
  if not isLive(h):
    setGlobalError("glyphes_tx_begin: stale handle")
    return int32(glyErrStale)
  if not isKind(h, hkDatabase):
    setGlobalError("glyphes_tx_begin: handle is not a database")
    return int32(glyErrStale)
  guarded("glyphes_tx_begin"):
    let db = lookup[Database](h, hkDatabase)
    let tx = beginTransaction(db)
    ## Register before claiming the slot, so a handle can never name a
    ## transaction the database does not know about.
    let th = register(hkTransaction, tx)
    db.attachTransaction(th)
    outTx[] = th
    int32(glyOk)

proc glyphes_tx_commit*(hDb: GlyHandle, hTx: GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  if not isLive(hDb) or not isKind(hDb, hkDatabase):
    setGlobalError("glyphes_tx_commit: stale database handle")
    return int32(glyErrStale)
  if not isLive(hTx) or not isKind(hTx, hkTransaction):
    setGlobalError("glyphes_tx_commit: stale transaction handle")
    return int32(glyErrStale)
  guarded("glyphes_tx_commit"):
    let db = lookup[Database](hDb, hkDatabase)
    let tx = lookup[WriteTransaction](hTx, hkTransaction)
    ## Both, not either: the slot rejects a foreign or already-finished
    ## handle, and the store check rejects a transaction that was opened
    ## against a different database's store.
    db.assertOwns(hTx, tx)
    if not commitTransaction(db, tx):
      ## Already finished, so its handle was already released and the
      ## caller's handle is stale by now. Reaching this means the slot
      ## and the registry disagreed, which is a bug here, not a caller
      ## error — reported as stale rather than as success.
      fail(glyErrStale, "transaction was already finished")
    discard release[WriteTransaction](hTx)
    int32(glyOk)

proc glyphes_tx_rollback*(hDb: GlyHandle, hTx: GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  if not isLive(hDb) or not isKind(hDb, hkDatabase):
    setGlobalError("glyphes_tx_rollback: stale database handle")
    return int32(glyErrStale)
  if not isLive(hTx) or not isKind(hTx, hkTransaction):
    setGlobalError("glyphes_tx_rollback: stale transaction handle")
    return int32(glyErrStale)
  guarded("glyphes_tx_rollback"):
    let db = lookup[Database](hDb, hkDatabase)
    let tx = lookup[WriteTransaction](hTx, hkTransaction)
    db.assertOwns(hTx, tx)
    if not rollbackTransaction(db, tx):
      fail(glyErrStale, "transaction was already finished")
    discard release[WriteTransaction](hTx)
    int32(glyOk)

proc glyphes_tx_info*(hTx: GlyHandle, outInfo: ptr GlyTxInfo): int32
    {.cdecl, exportc, dynlib.} =
  if outInfo == nil:
    setGlobalError("glyphes_tx_info: out is null")
    return int32(glyErr)
  if not isLive(hTx):
    setGlobalError("glyphes_tx_info: stale handle")
    return int32(glyErrStale)
  if not isKind(hTx, hkTransaction):
    setGlobalError("glyphes_tx_info: handle is not a transaction")
    return int32(glyErrStale)
  guarded("glyphes_tx_info"):
    let tx = lookup[WriteTransaction](hTx, hkTransaction)
    outInfo[] = txInfoOf(tx)
    int32(glyOk)

# --------------------------------------------------------- integrity check

var
  integrityBuf {.threadvar.}: cstring
  ## The report `glyphes_integrity_check` hands back. ABI.md §7 names this
  ## shape an open question: static storage, no free for the caller, valid
  ## until the next call on this thread. It is implemented as one buffer
  ## per thread, replaced (and the previous one freed) on the next call,
  ## so "no free" costs the host nothing and costs the engine one buffer
  ## rather than one per check. ffi.rb copies it immediately.
  ##
  ## If reports ever need collecting or comparing across calls, this
  ## becomes the buffer protocol of `glyphes_schema` — the same two-call
  ## retry — and that is the change to make then, not now.

# ------------------------------------------------- cell accessors (M7.1)
#
# The eleven functions the header declared and nothing implemented. The
# design questions ABI.md settled, restated where the code has to answer
# them: a list or map crosses as its JSON rendering (so the host walks it
# once — `cell_at`/`cell_get` are refusals, not JSON parsers inside the
# engine), and nothing engine-allocated is handed out (so `cell_blob` is a
# refusal too; the copy-out protocol of `cell_text`/`cell_bytes` is the
# only allocator in the ABI).

proc glyphes_cell_bytes*(c: ptr GlyCell, outBuf: ptr uint8, cap: csize_t,
                         outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## The binary copy-out, same cap protocol as `cell_text`: nothing is
  ## written on a short buffer, `out_len` says what to retry with, and
  ## there is no NUL — a blob with an embedded zero must survive the
  ## crossing unchanged.
  if outLen != nil:
    outLen[] = 0
  if c == nil:
    setGlobalError("glyphes_cell_bytes: cell is null")
    return int32(glyErr)
  let cell = c[]
  if cell.tag != uint32(ord(glyBytes)):
    setGlobalError("glyphes_cell_bytes: cell is not GLY_BYTES")
    return int32(glyErr)
  let n = int(cell.len)
  if outLen != nil:
    outLen[] = csize_t(n)
  if n > int(cap):
    return int32(glyMore)
  if n > 0 and outBuf != nil and cell.ptr != nil:
    copyMem(outBuf, cell.ptr, n)
  int32(glyOk)

proc glyphes_cell_blob*(c: ptr GlyCell, outPtr: ptr pointer,
                        outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## Refused, deliberately. A blob handle has to be freed by *somebody*,
  ## and an engine-allocated one would put a second allocator in the ABI
  ## and a second thing to get wrong under a foreign collector (ABI.md's
  ## rejected alternatives). `glyphes_cell_bytes` copies into the caller's
  ## buffer and is the whole of what this needs to be.
  if outLen != nil:
    outLen[] = 0
  setGlobalError("glyphes_cell_blob: refused by design — use " &
                 "glyphes_cell_bytes, which copies into a caller buffer " &
                 "(ABI.md: no engine-allocated memory in the ABI)")
  return int32(glyErrUnsupported)

proc glyphes_cell_at*(c: ptr GlyCell, i: uint32, outCell: ptr GlyCell): int32
    {.cdecl, exportc, dynlib.} =
  ## Refused, deliberately. A list or map cell's payload is its JSON
  ## rendering, so element access would mean parsing JSON inside the engine
  ## to hand back a sub-cell — and a sub-cell would point into a parse
  ## buffer the engine would then own, which is the ownership rule this
  ## whole accessor set exists to avoid (ABI.md). The host reads the payload
  ## once with `glyphes_cell_text` and walks it there.
  if outCell != nil:
    outCell[] = GlyCell(tag: uint32(ord(glyNull)))
  setGlobalError("glyphes_cell_at: refused by design — a list/map cell's " &
                 "payload is JSON; read it once with glyphes_cell_text " &
                 "and walk it on your side (ABI.md)")
  return int32(glyErrUnsupported)

proc glyphes_cell_get*(c: ptr GlyCell, key: cstring,
                       outCell: ptr GlyCell): int32
    {.cdecl, exportc, dynlib.} =
  ## The map case of `cell_at`'s refusal, with the same reasoning and the
  ## same answer.
  if outCell != nil:
    outCell[] = GlyCell(tag: uint32(ord(glyNull)))
  setGlobalError("glyphes_cell_get: refused by design — a map cell's " &
                 "payload is JSON; read it once with glyphes_cell_text " &
                 "(ABI.md)")
  return int32(glyErrUnsupported)

proc glyphes_cell_path*(c: ptr GlyCell, outPath: ptr GlyPath): int32
    {.cdecl, exportc, dynlib.} =
  ## A path crosses as three parallel arrays in statement memory; this
  ## hands the caller the {count, nodes, edges, dirs} view, and the
  ## component accessors below are the bounds-checked reads against it, so
  ## a host never holds a raw pointer past the statement (ABI.md).
  if c == nil or outPath == nil:
    setGlobalError("glyphes_cell_path: cell or out is null")
    return int32(glyErr)
  let cell = c[]
  if cell.tag != uint32(ord(glyPath)):
    setGlobalError("glyphes_cell_path: cell is not a path")
    return int32(glyErr)
  if cell.ptr == nil:
    setGlobalError("glyphes_cell_path: path cell has no payload")
    return int32(glyErr)
  ## Layout, as built by execute.nim: node ids, then edge ids, then the
  ## direction bytes. `count` is the node count; a path of n nodes carries
  ## n-1 edges and n-1 directions.
  let n = int(cell.len)
  if n <= 0:
    setGlobalError("glyphes_cell_path: path cell has no components")
    return int32(glyErr)
  let base = cast[ptr UncheckedArray[int64]](cell.ptr)
  outPath[].count = uint32(n)
  outPath[].nodes = cast[ptr int64](cell.ptr)
  outPath[].edges = cast[ptr int64](addr base[n])
  outPath[].dirs = cast[ptr uint8](addr base[2 * n - 1])
  int32(glyOk)

proc glyphes_cell_path_node*(c: ptr GlyCell, i: uint32,
                            outId: ptr int64): int32
    {.cdecl, exportc, dynlib.} =
  if c == nil or outId == nil:
    setGlobalError("glyphes_cell_path_node: cell or out is null")
    return int32(glyErr)
  let cell = c[]
  if cell.tag != uint32(ord(glyPath)) or cell.ptr == nil:
    setGlobalError("glyphes_cell_path_node: cell is not a path")
    return int32(glyErr)
  if i >= cell.len:
    setGlobalError("glyphes_cell_path_node: index " & $i & " is past the " &
                   "path's " & $cell.len & " nodes")
    return int32(glyErrSql)
  let base = cast[ptr UncheckedArray[int64]](cell.ptr)
  outId[] = base[int(i)]
  int32(glyOk)

proc glyphes_cell_path_edge*(c: ptr GlyCell, i: uint32, outId: ptr int64,
                             outDir: ptr uint8): int32
    {.cdecl, exportc, dynlib.} =
  ## Edge i is the step between node i and node i+1, so a path of n nodes
  ## has n-1 edges — asking for edge n-1 is a bounds error, not an empty
  ## step.
  if c == nil or outId == nil or outDir == nil:
    setGlobalError("glyphes_cell_path_edge: cell or out is null")
    return int32(glyErr)
  let cell = c[]
  if cell.tag != uint32(ord(glyPath)) or cell.ptr == nil:
    setGlobalError("glyphes_cell_path_edge: cell is not a path")
    return int32(glyErr)
  if cell.len < 2 or i + 1 >= cell.len:
    setGlobalError("glyphes_cell_path_edge: index " & $i & " is past the " &
                   "path's " & $(cell.len - 1) & " edges")
    return int32(glyErrSql)
  let n = int(cell.len)
  let base = cast[ptr UncheckedArray[int64]](cell.ptr)
  outId[] = base[n + int(i)]
  outDir[] = cast[ptr UncheckedArray[uint8]](addr base[2 * n - 1])[int(i)]
  int32(glyOk)

proc glyphes_stats*(outJson: ptr char, cap: csize_t,
                    written: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## Per-thread allocator and arena statistics, as JSON. `cap` is in/out
  ## like every other string call here: on return `written` is the full
  ## length including the NUL, and a short buffer is not written.
  if written != nil:
    written[] = 0
  if outJson == nil or written == nil:
    setGlobalError("glyphes_stats: json_out and written are required")
    return int32(glyErr)
  let json = runtimeStatsJson()
  written[] = csize_t(json.len + 1)
  if cap < csize_t(json.len + 1):
    return int32(glyMore)
  copyMem(outJson, addr json[0], json.len + 1)
  int32(glyOk)

proc glyphes_schema*(h: GlyHandle, what: int32, outJson: ptr char,
                     cap: csize_t, outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## The schema as JSON, under the same cap protocol: ask with 0, get a
  ## length, ask again. `what` selects sections (GLY_SCHEMA_LABELS,
  ## _PROPERTIES, _INDEXES); 0 means all three, which is what a caller who
  ## passed nothing wants.
  if outJson == nil or outLen == nil:
    setGlobalError("glyphes_schema: json_out and out_len are required")
    return int32(glyErrSql)
  outLen[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_schema: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_schema"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    var want = what
    if want == 0:
      want = GLY_SCHEMA_LABELS or GLY_SCHEMA_PROPERTIES or GLY_SCHEMA_INDEXES
    let json = schemaJson(db, (want and GLY_SCHEMA_LABELS) != 0,
                          (want and GLY_SCHEMA_PROPERTIES) != 0,
                          (want and GLY_SCHEMA_INDEXES) != 0)
    outLen[] = csize_t(json.len + 1)
    if cap < csize_t(json.len + 1):
      return int32(glyMore)
    copyMem(outJson, addr json[0], json.len + 1)
    int32(glyOk)

proc glyphes_checkpoint*(h: GlyHandle, flags: int32): int32
    {.cdecl, exportc, dynlib.} =
  ## WAL.md §6. Checkpoint at a transaction boundary or not at all (W11), so
  ## a statement in flight is never half in the snapshot and half in the
  ## log. GLY_CHECKPOINT_TRUNCATE shortens the log to the snapshot's lsn;
  ## GLY_CHECKPOINT_FSYNC fsyncs the snapshot before the rename.
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_checkpoint: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_checkpoint"):
    let db = lookup[Database](h, hkDatabase)
    if db.wal == nil or db.inMemory:
      setGlobalError("glyphes_checkpoint: a memory database has no log " &
                     "to checkpoint")
      return int32(glyErrUnsupported)
    let truncFlag = (flags and int32(GLY_CHECKPOINT_TRUNCATE)) != 0
    let fsyncFlag = (flags and int32(GLY_CHECKPOINT_FSYNC)) != 0
    checkpoint(db, truncFlag, fsyncFlag)
    int32(glyOk)

proc glyphes_wal_size*(h: GlyHandle, outBytes: ptr uint64): int32
    {.cdecl, exportc, dynlib.} =
  if outBytes == nil:
    setGlobalError("glyphes_wal_size: out is null")
    return int32(glyErr)
  outBytes[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_wal_size: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_wal_size"):
    let db = lookup[Database](h, hkDatabase)
    outBytes[] = uint64(db.walSize)
    int32(glyOk)

proc glyphes_backup*(h: GlyHandle, dest: cstring): int32
    {.cdecl, exportc, dynlib.} =
  ## Checkpoint-then-copy (WAL.md §3): the result is a consistent pair, not
  ## a file copied while a transaction was mid-commit.
  if dest == nil or dest.len == 0:
    setGlobalError("glyphes_backup: dest is empty")
    return int32(glyErr)
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_backup: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_backup"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    if db.readonly:
      setGlobalError("glyphes_backup: the database is read-only")
      return int32(glyErrReadOnly)
    db.backup($dest)
    int32(glyOk)

proc glyphes_vacuum*(h: GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  ## Rebuild every index from live records and write the snapshot
  ## (INDEX.md I14). Explicit, because the rebuild is O(store): close must
  ## not do it (a full snapshot write on every Ruby `ensure` would be the
  ## worst possible default), so this is the door that does.
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_vacuum: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_vacuum"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    if db.readonly:
      setGlobalError("glyphes_vacuum: the database is read-only")
      return int32(glyErrReadOnly)
    db.vacuum()
    int32(glyOk)

proc nodeJsonOut(h: GlyHandle, id: int64, labels, properties: bool,
                 outJson: ptr char, cap: csize_t, outLen: ptr csize_t): int32 =
  if outJson == nil or outLen == nil:
    setGlobalError("glyphes_node_*: json_out and out_len are required")
    return int32(glyErrSql)
  outLen[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_node_*: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_node_*"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    if not db.store.nodeExists(id):
      ## A node that is not there is not an empty node: `labels` for a
      ## deleted id must be distinguishable from a live node with no labels,
      ## and "node 7 does not exist" is the answer.
      setGlobalError("node " & $id & " does not exist")
      return int32(glyErrSql)
    let json = nodeJson(db, id, labels, properties)
    outLen[] = csize_t(json.len + 1)
    if cap < csize_t(json.len + 1):
      return int32(glyMore)
    copyMem(outJson, addr json[0], json.len + 1)
    int32(glyOk)

proc glyphes_node_labels*(h: GlyHandle, id: int64,
                          outJson: ptr char, cap: csize_t,
                          outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
    ## The node's labels as a JSON array — RUBY.md §4.2's `n.labels`,
    ## without a Cypher round-trip. One engine call, the cap protocol the
    ## rest of the ABI uses.
    result = nodeJsonOut(h, id, true, false, outJson, cap, outLen)

proc glyphes_node_props*(h: GlyHandle, id: int64,
                         outJson: ptr char, cap: csize_t,
                         outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
    ## The node's properties as a JSON object. Same protocol.
    result = nodeJsonOut(h, id, false, true, outJson, cap, outLen)

proc glyphes_edge_props*(h: GlyHandle, id: int64, outJson: ptr char,
                         cap: csize_t, outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## An edge's properties, as JSON, under the same cap protocol as a node's.
  ## An edge with no properties is `{}`, not a null and not an error: an
  ## absent property map and a node that does not exist are different facts.
  if outJson == nil or outLen == nil:
    setGlobalError("glyphes_edge_props: json_out and out_len are required")
    return int32(glyErrSql)
  outLen[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_edge_props: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_edge_props"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    if db.store.edges.len <= id.int or not db.store.edges[id.int].live():
      setGlobalError("edge " & $id & " does not exist")
      return int32(glyErrSql)
    var props: seq[string] = @[]
    for key in db.store.edgePropKeys(id):
      var v = Value(kind: vkNull)
      if db.store.getEdgeProp(id, key, v):
        props.add quoteJson(key) & ":" & valueJson(v)
    let json = "{\"id\":" & $id & ",\"properties\":{" & props.join(",") & "}}"
    outLen[] = csize_t(json.len + 1)
    if cap < csize_t(json.len + 1):
      return int32(glyMore)
    copyMem(outJson, addr json[0], json.len + 1)
    int32(glyOk)

proc glyphes_edge_info*(h: GlyHandle, id: int64, outJson: ptr char,
                        cap: csize_t, outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## Type and endpoints of an edge, as JSON: `{"id":n,"type":"KNOWS",
  ## "src":a,"dst":b}`. This is what makes RUBY.md's `Glyphes::Edge` — "id +
  ## type + endpoints" — a view rather than an id wrapper, without a
  ## Cypher round-trip per call.
  if outJson == nil or outLen == nil:
    setGlobalError("glyphes_edge_info: json_out and out_len are required")
    return int32(glyErrSql)
  outLen[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_edge_info: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_edge_info"):
    let db = lookup[Database](h, hkDatabase)
    db.assertOpen
    if db.store.edges.len <= id.int or not db.store.edges[id.int].live():
      setGlobalError("edge " & $id & " does not exist")
      return int32(glyErrSql)
    let e = db.store.edges[id.int]
    let json = "{\"id\":" & $id & ",\"type\":" &
               quoteJson(db.store.relTypes.nameOf(e.etype)) &
               ",\"src\":" & $e.src & ",\"dst\":" & $e.dst & "}"
    outLen[] = csize_t(json.len + 1)
    if cap < csize_t(json.len + 1):
      return int32(glyMore)
    copyMem(outJson, addr json[0], json.len + 1)
    int32(glyOk)

proc glyphes_integrity_check*(h: GlyHandle, outReport: ptr cstring): int32
    {.cdecl, exportc, dynlib.} =
  if outReport == nil:
    setGlobalError("glyphes_integrity_check: out_report is null")
    return int32(glyErr)
  if not isLive(h):
    setGlobalError("glyphes_integrity_check: stale handle")
    return int32(glyErrStale)
  if not isKind(h, hkDatabase):
    setGlobalError("glyphes_integrity_check: handle is not a database")
    return int32(glyErrStale)
  guarded("glyphes_integrity_check"):
    let db = lookup[Database](h, hkDatabase)
    let rep = integrityReport(db)
    if integrityBuf != nil:
      ## Paired with `alloc`, not `deallocShared`: the two are different
      ## allocators, and freeing a raw-`alloc` pointer through the shared
      ## path is heap corruption that only looks like it works. The M3
      ## original had the same mismatch; the columns buffer copied it.
      dealloc(cast[pointer](integrityBuf))
      integrityBuf = nil
    let buf = cast[ptr UncheckedArray[char]](alloc(rep.len + 1))
    copyMem(addr buf[0], unsafeAddr rep[0], rep.len)
    buf[rep.len] = '\0'
    integrityBuf = cast[cstring](buf)
    outReport[] = integrityBuf
    int32(glyOk)


# ------------------------------------------------------------------- indices
#
# The five calls `glyphes.h` has always declared (ABI.md §4). M6.1
# implements the range index, so `index_build` on a range index is a
# rebuild rather than the HNSW bulk load it becomes in M6.3 — the name is
# the same on purpose, so a caller does not have to know which kind it has.

proc glyphes_index_create*(h: GlyHandle, kind: int32,
                           optionsJson: cstring): int32
    {.cdecl, exportc, dynlib.} =
  ## `options_json` carries `{"property": "age"}` for a range index and
  ## `{"label": "Doc", "property": "embedding", …}` for the others. The
  ## property is required; the label defaults to "" (a global index).
  if not isLive(h):
    setGlobalError("glyphes_index_create: stale handle")
    return int32(glyErrStale)
  if not isKind(h, hkDatabase):
    setGlobalError("glyphes_index_create: handle is not a database")
    return int32(glyErrStale)
  if kind != 0 and kind != 1 and kind != 2:
    ## GLY_IDX_RANGE | GLY_IDX_TEXT | GLY_IDX_VECTOR
    setGlobalError("glyphes_index_create: unknown index kind")
    return int32(glyErrUnsupported)
  guarded("glyphes_index_create"):
    let db = lookup[Database](h, hkDatabase)
    if db.readonly:
      setGlobalError("glyphes_index_create: the database is read-only")
      return int32(glyErrReadOnly)
    ## The options object is read with the parameters parser rather than a
    ## second JSON reader: it is the same grammar, and two parsers for one
    ## file format is one more thing to keep in step.
    var opts = parseParamsJson($optionsJson)
    let property = (if opts.hasKey("property"): opts["property"].s else: "")
    if property.len == 0:
      setGlobalError("glyphes_index_create: options need a \"property\"")
      return int32(glyErrSql)
    let target =
      (if opts.hasKey("label"): opts["label"].s
       elif opts.hasKey("target"): opts["target"].s
       else: "")
    ## A constraint rides the same call as the index it enforces with
    ## (TXN.md §5: one structure, two clients). Spelled the way TXN.md's
    ## table spells them; anything else is refused rather than guessed.
    var constraint = 0'u8            ## ConstraintNone
    if opts.hasKey("constraint"):
      let c = opts["constraint"].s.toLowerAscii()
      case c
      of "unique": constraint = 1
      of "exists": constraint = 2
      of "not_null", "notnull", "not null": constraint = 3
      else:
        setGlobalError("glyphes_index_create: unknown constraint \"" &
                       c & "\" (unique, exists, not_null)")
        return int32(glyErrSql)
    if kind == 1:                    ## GLY_IDX_TEXT
      ## The analyzer is optional and defaults to `standard`. A name the
      ## analyzer does not know is refused rather than falling back — a
      ## silent fallback returns terms the caller never asked for, which
      ## looks like a search that works and is quietly wrong.
      let analyzer = (if opts.hasKey("analyzer"): opts["analyzer"].s else: "standard")
      discard db.indices.createText(target, property, analyzer)
    elif kind == 2:                  ## GLY_IDX_VECTOR
      ## Metric, m and ef_construction are per index; changing any of them
      ## changes the graph, so the definition is refused rather than
      ## silently re-created (I13). ef_construction below 200 is refused
      ## inside newVector — the one trade the index will not make quietly.
      let metric = metricFromName(
        (if opts.hasKey("metric"): opts["metric"].s else: "cosine"))
      var m = DefaultM
      if opts.hasKey("m"):
        if opts["m"].kind != vkInt:
          setGlobalError("glyphes_index_create: \"m\" must be an integer")
          return int32(glyErrSql)
        m = int(opts["m"].i)
      var efc = DefaultEfConstruction
      if opts.hasKey("ef_construction"):
        if opts["ef_construction"].kind != vkInt:
          setGlobalError("glyphes_index_create: \"ef_construction\" must be an integer")
          return int32(glyErrSql)
        efc = int(opts["ef_construction"].i)
      discard db.indices.createVector(target, property, metric, m, efc)
    else:
      discard db.indices.create(IdxRange, target, property, constraint)
    ## Backfill when there is something to backfill from, and say so in the
    ## call rather than leaving an empty index that looks like a broken one
    ## (INDEX.md §5: O(1) when empty, O(n) when populated).
    if db.store.nodes.len > 1:
      db.indices.rebuild(db.store)
      ## A constraint over data that already violates it is a no-op that
      ## looks like a guarantee, so creating one validates the store first
      ## and refuses instead.
      if constraint != 0'u8:
        db.indices.checkExistingConstraints(db.store)
    ## The definitions are durable from the moment the call returns: a
    ## caller who created an index and reopened should find it. The
    ## contents rebuild at open (pin W5); only these few fields are stored.
    ## Not for a memory database: its path is the ":memory:" literal, and
    ## writing a sidecar next to it puts a ":memory:.indexes" file in the
    ## caller's working directory — a memory database leaking a file is the
    ## one thing its contract promises never happens.
    if not db.inMemory:
      writeIndexDefs(db.indices, db.path)
    int32(glyOk)

proc glyphes_index_drop*(h: GlyHandle, name: cstring): int32
    {.cdecl, exportc, dynlib.} =
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_index_drop: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_index_drop"):
    let db = lookup[Database](h, hkDatabase)
    if not db.indices.drop($name):
      setGlobalError("glyphes_index_drop: no index named " & $name)
      return int32(glyErrSql)
    ## A dropped index must stay dropped across a reopen, or the registry
    ## and the sidecar disagree and the index comes back. Same memory
    ## guard as index_create: nothing durable to record.
    if not db.inMemory:
      writeIndexDefs(db.indices, db.path)
    int32(glyOk)

proc glyphes_index_list*(h: GlyHandle, outJson: ptr UncheckedArray[char],
                        cap: csize_t, outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## JSON: `[{"name":…,"entries":…,"blocks":…,"generation":…}, …]`.
  ##
  ## The header's cap protocol, which `glyphes_schema` and `glyphes_stats`
  ## declare and this is the first implementation of: the caller passes a
  ## buffer and its size, `out_len` always comes back with the full length,
  ## and a short buffer is *not* written. Retry with `out_len + 1`.
  ## The engine owns nothing here — no free call, no thread-local buffer —
  ## which is why this one does not need the `*_free` that
  ## `glyphes_stmt_columns` needs. Documented once, in the header, when the
  ## second implementation lands.
  if outJson == nil or outLen == nil:
    setGlobalError("glyphes_index_list: json_out and out_len are required")
    return int32(glyErrSql)
  outLen[] = 0
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_index_list: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_index_list"):
    let db = lookup[Database](h, hkDatabase)
    var parts: seq[string] = @[]
    for (name, entries, blocks, generation) in db.indices.stats():
      ## `blocks` is the block count for a range index and the term count
      ## for a text one (which has no blocks); `kind` says which, so a
      ## caller does not have to guess what the number means.
      let kindName = (if blocks >= 0 and name.len > 0: name else: name)
      parts.add "{\"name\":\"" & name & "\",\"entries\":" & $entries &
                ",\"blocks\":" & $blocks & ",\"generation\":" & $generation & "}"
    let json = "[" & parts.join(",") & "]"
    outLen[] = csize_t(json.len)
    if cap < csize_t(json.len + 1):
      ## Not written, and the caller is told the size it needs. Returning
      ## an error here would make "ask again with a bigger buffer" an error
      ## path, which is how a retry protocol becomes a crash.
      return int32(glyOk)
    copyMem(addr outJson[0], unsafeAddr json[0], json.len)
    outJson[json.len] = '\0'
    int32(glyOk)

proc glyphes_index_rebuild*(h: GlyHandle, name: cstring): int32
    {.cdecl, exportc, dynlib.} =
  if not isLive(h) or not isKind(h, hkDatabase):
    setGlobalError("glyphes_index_rebuild: not a database handle")
    return int32(glyErrStale)
  guarded("glyphes_index_rebuild"):
    let db = lookup[Database](h, hkDatabase)
    if name == nil or $name == "":
      setGlobalError("glyphes_index_rebuild: name is empty")
      return int32(glyErrSql)
    db.indices.rebuild(db.store, $name)
    int32(glyOk)

proc glyphes_index_build*(h: GlyHandle, name: cstring): int32
    {.cdecl, exportc, dynlib.} =
  ## The bulk path (INDEX.md pin I9). For a range index it *is* a rebuild:
  ## the structure is built by the same walk, and gate I2's 10x claim is
  ## about the vector index, where an HNSW graph cannot be built
  ## incrementally at all.
  glyphes_index_rebuild(h, name)

# --------------------------------------------------------------- statements

proc glyphes_prepare*(hDb: GlyHandle, cypher: cstring, paramsJson: cstring,
                      outStmt: ptr GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  ## Prepare a read query. ABI.md §2: named parameters only, passed as one
  ## JSON object; null means none.
  ##
  ## `paramsJson` is parsed here rather than in the binding because a
  ## malformed JSON object is a caller error with a status, not a Ruby
  ## exception to translate — and the parse happens once per prepare rather
  ## than once per row.
  if outStmt == nil:
    setGlobalError("glyphes_prepare: out_stmt is null")
    return int32(glyErr)
  outStmt[] = 0
  if not isLive(hDb) or not isKind(hDb, hkDatabase):
    setGlobalError("glyphes_prepare: stale database handle")
    return int32(glyErrStale)
  if cypher == nil:
    setGlobalError("glyphes_prepare: cypher is null")
    return int32(glyErr)
  guarded("glyphes_prepare"):
    let db = lookup[Database](hDb, hkDatabase)
    db.assertOpen
    var params = initTable[string, Value]()
    if paramsJson != nil:
      let text = $paramsJson
      if text.strip != "":
        params = parseParamsJson(text)
    let st = prepare(db.store, $cypher, params, nil, 0, "", db.indices)
    ## Same discipline as prepare's own plan guard: from a successful
    ## prepare to a registered handle, a failure must run `close` or the
    ## snapshot outlives the statement and the writer gate parks forever.
    try:
      outStmt[] = register(hkStatement, st)
    except CatchableError as e:
      close(st)
      raise e
    int32(glyOk)

proc glyphes_stmt_step*(hStmt: GlyHandle, outCells: ptr GlyCell,
                        cap: csize_t, outRows: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## ABI.md B2: fills `outCells[0 ..< columns]` with one row and returns
  ## `GLY_MORE` while rows remain, `GLY_DONE` at the end.
  if outRows != nil:
    outRows[] = 0
  if not isLive(hStmt) or not isKind(hStmt, hkStatement):
    setGlobalError("glyphes_stmt_step: stale statement handle")
    return int32(glyErrStale)
  if outCells == nil or outRows == nil:
    setGlobalError("glyphes_stmt_step: out_cells and out_rows are required")
    return int32(glyErr)
  guarded("glyphes_stmt_step"):
    let st = lookup[Statement](hStmt, hkStatement)
    var rows: int = 0
    let status = stepCells(st, cast[ptr UncheckedArray[GlyCell]](outCells),
                           int(cap), rows)
    outRows[] = csize_t(rows)
    status

var
  columnsBuf {.threadvar.}: ptr UncheckedArray[char]
  ## Engine-owned storage for `glyphes_stmt_columns`, replaced (and the
  ## previous one freed) on the next call on this thread. Same shape as the
  ## integrity report's buffer: no free for the caller, one buffer per
  ## thread, valid until the next call.
proc glyphes_stmt_columns*(hStmt: GlyHandle, outCols: ptr cstring,
                           outLen: ptr csize_t, outCount: ptr uint32): int32
    {.cdecl, exportc, dynlib.} =
  ## Column names as one NUL-separated block, per the header:
  ## `glyphes_stmt_columns(GlyHandle, char **out, size_t *out_len,
  ## uint32_t *out_count)`. `out` receives a pointer to engine-owned memory
  ## that stays valid until the next call on this thread — the same rule as
  ## the error slot, and the reason `glyphes_free_columns` exists for hosts
  ## that want to keep a copy is that they copy, not free, this one.
  if outLen != nil:
    outLen[] = 0
  if outCount != nil:
    outCount[] = 0
  if not isLive(hStmt) or not isKind(hStmt, hkStatement):
    setGlobalError("glyphes_stmt_columns: stale statement handle")
    return int32(glyErrStale)
  if outCols == nil or outLen == nil:
    setGlobalError("glyphes_stmt_columns: out and out_len are required")
    return int32(glyErr)
  guarded("glyphes_stmt_columns"):
    let st = lookup[Statement](hStmt, hkStatement)
    var joined = ""
    for i, c in st.columns:
      if i > 0: joined.add '\0'
      joined.add c
    joined.add '\0'
    ## Held as a plain pointer rather than a cstring: the header's out
    ## parameter is `char **`, and routing it through cstring buys a cast
    ## the compiler already warns about in exchange for nothing.
    if columnsBuf != nil:
      dealloc(cast[pointer](columnsBuf))
      columnsBuf = nil
    let buf = cast[ptr UncheckedArray[char]](alloc(joined.len))
    copyMem(addr buf[0], unsafeAddr joined[0], joined.len)
    columnsBuf = buf
    outCols[] = buf
    outLen[] = csize_t(joined.len)
    if outCount != nil:
      outCount[] = uint32(st.columns.len)
    int32(glyOk)


proc glyphes_stmt_columns_count*(hStmt: GlyHandle, outCount: ptr uint32): int32
    {.cdecl, exportc, dynlib.} =
  ## The arity of the stream, so a caller can size its cell array before the
  ## first step.
  if outCount == nil:
    setGlobalError("glyphes_stmt_columns_count: out is null")
    return int32(glyErr)
  if not isLive(hStmt) or not isKind(hStmt, hkStatement):
    setGlobalError("glyphes_stmt_columns_count: stale statement handle")
    return int32(glyErrStale)
  guarded("glyphes_stmt_columns_count"):
    let st = lookup[Statement](hStmt, hkStatement)
    outCount[] = uint32(st.columns.len)
    int32(glyOk)

proc glyphes_stmt_close*(hStmt: GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  ## Releases the snapshot. A second call finds the handle stale and answers
  ## `GLY_ERR_STALE`, which is what makes the binding's `ensure` path safe
  ## (ABI.md B4).
  if not isLive(hStmt):
    setGlobalError("glyphes_stmt_close: stale statement handle")
    return int32(glyErrStale)
  if not isKind(hStmt, hkStatement):
    setGlobalError("glyphes_stmt_close: handle is not a statement")
    return int32(glyErrStale)
  guarded("glyphes_stmt_close"):
    let st = lookup[Statement](hStmt, hkStatement)
    close(st)
    discard release[Statement](hStmt)
    int32(glyOk)

proc glyphes_stmt_reset*(hStmt: GlyHandle): int32
    {.cdecl, exportc, dynlib.} =
  ## Statements are single-use (EXEC.md §1: init, then next until false).
  ## Reset means re-running `init`, which needs the parameters re-bound and
  ## the snapshot re-taken — that is a second prepare. Answered honestly
  ## rather than half-done: the binding's `reset` re-prepares.
  setGlobalError("glyphes_stmt_reset: statements are single-use; prepare again")
  int32(glyErrUnsupported)

proc glyphes_exec*(hDb: GlyHandle, cypher: cstring, paramsJson: cstring,
                   outN: ptr int64): int32
    {.cdecl, exportc, dynlib.} =
  ## The write door (ABI.md §"mutation without a transaction"). Runs the
  ## whole query, applies its writes, and reports how many entities
  ## landed — then commits, unless a transaction is already open, in which
  ## case it joins that one and leaves the commit to whoever opened it.
  ##
  ## Joining is what makes `db.transaction { db.exec(...) }` mean what it
  ## looks like: the block's rollback has to be able to undo the exec's
  ## writes, and an autocommit inside the block would have taken that
  ## choice away.
  if outN == nil:
    setGlobalError("glyphes_exec: out_n is null")
    return int32(glyErr)
  outN[] = 0
  if not isLive(hDb) or not isKind(hDb, hkDatabase):
    setGlobalError("glyphes_exec: stale database handle")
    return int32(glyErrStale)
  if cypher == nil:
    setGlobalError("glyphes_exec: cypher is null")
    return int32(glyErr)
  guarded("glyphes_exec"):
    let db = lookup[Database](hDb, hkDatabase)
    db.assertOpen
    var params = initTable[string, Value]()
    if paramsJson != nil:
      let text = $paramsJson
      if text.strip != "":
        params = parseParamsJson(text)
    let joined = db.writerTx != 0
    var tx: WriteTransaction
    if joined:
      tx = lookup[WriteTransaction](db.writerTx, hkTransaction)
    else:
      tx = db.beginTransaction()
    var st: Statement
    var finished = false
    try:
      st = prepare(db.store, $cypher, params, tx, 0, "", db.indices)
      while st.step():
        discard
      outN[] = st.rowsAffected()
      finished = true
    finally:
      ## The snapshot goes first, always. `commitTransaction` merges behind
      ## `beginWrite`, which waits for the reader count to reach zero — and
      ## this thread is one of the readers, so committing with the
      ## statement still open deadlocks the writer gate against itself.
      if st != nil:
        st.close()
      if not joined:
        if finished:
          discard db.commitTransaction(tx)
        else:
          discard db.rollbackTransaction(tx)
    int32(glyOk)

# ------------------------------------------------------------ cell accessors

proc glyphes_exec_returning*(hDb: GlyHandle, cypher: cstring,
                            paramsJson: cstring, outN: ptr int64,
                            outId: ptr int64): int32
    {.cdecl, exportc, dynlib.} =
  ## The write door, and the node id of the first created node.
  ##
  ## `glyphes_exec` reports how many entities landed; the model layer needs
  ## *which* id a `CREATE … RETURN id(n)` produced, and reading it back with
  ## a second query would be two crossings for one save (R5) and would race
  ## a concurrent writer for "the node I just made". Same statement, same
  ## transaction discipline, one extra out-param.
  if outN == nil or outId == nil:
    setGlobalError("glyphes_exec_returning: out_n and out_id are required")
    return int32(glyErr)
  outN[] = 0
  outId[] = 0
  if not isLive(hDb) or not isKind(hDb, hkDatabase):
    setGlobalError("glyphes_exec_returning: stale database handle")
    return int32(glyErrStale)
  if cypher == nil:
    setGlobalError("glyphes_exec_returning: cypher is null")
    return int32(glyErr)
  guarded("glyphes_exec_returning"):
    let db = lookup[Database](hDb, hkDatabase)
    db.assertOpen
    var params = initTable[string, Value]()
    if paramsJson != nil:
      let text = $paramsJson
      if text.strip != "":
        params = parseParamsJson(text)
    let joined = db.writerTx != 0
    var tx: WriteTransaction
    if joined:
      tx = lookup[WriteTransaction](db.writerTx, hkTransaction)
    else:
      tx = db.beginTransaction()
    var st: Statement
    var finished = false
    var gotId = false
    try:
      st = prepare(db.store, $cypher, params, tx, 0, "", db.indices)
      ## First row, first column: the model's contract is
      ## `CREATE … RETURN id(n) AS id`, one column, so column 0 is the id.
      ## A row whose first cell is not an integer (the caller returned
      ## something else) leaves out_id 0 — the model treats 0 as "no id"
      ## and falls back to a property-keyed update, which is the safe
      ## degradation rather than a wrong id.
      while st.step():
        discard
        if not gotId:
          let row = st.current
          if row.slots.len > 0 and row.slots[0][1].kind == vkInt:
            outId[] = row.slots[0][1].i
            gotId = true
      outN[] = st.rowsAffected()
      finished = true
    finally:
      if st != nil:
        st.close()
      if not joined:
        if finished:
          discard db.commitTransaction(tx)
        else:
          discard db.rollbackTransaction(tx)
    int32(glyOk)


proc glyphes_cell_text*(c: ptr GlyCell, outBuf: ptr char, cap: csize_t,
                        outLen: ptr csize_t): int32
    {.cdecl, exportc, dynlib.} =
  ## Copy a string cell out. Always NUL-terminates when `cap > 0`; `out_len`
  ## reports the full length so truncation is detectable (ABI.md §2).
  if outLen != nil:
    outLen[] = 0
  if c == nil:
    setGlobalError("glyphes_cell_text: cell is null")
    return int32(glyErr)
  let cell = c[]
  ## Every byte-payload tag qualifies: strings and blobs natively, lists and
  ## maps as their JSON rendering (execute.nim's toCell). A vector's payload
  ## is doubles, not text, and is refused here on purpose.
  let tag = cell.tag
  if tag != uint32(ord(glyString)) and tag != uint32(ord(glyBytes)) and
     tag != uint32(ord(glyList)) and tag != uint32(ord(glyMap)):
    setGlobalError("glyphes_cell_text: cell has no text payload")
    return int32(glyErr)
  let n = int(cell.len)
  if outLen != nil:
    outLen[] = csize_t(n)
  if n + 1 > int(cap):
    return int32(glyMore)          # caller retries with a bigger buffer
  if n > 0 and outBuf != nil:
    copyMem(outBuf, cell.ptr, n)
  if cap > 0 and outBuf != nil:
    let term = cast[ptr UncheckedArray[char]](outBuf)
    term[n] = '\0'
  int32(glyOk)

proc glyphes_cell_id*(c: ptr GlyCell, outId: ptr int64): int32
    {.cdecl, exportc, dynlib.} =
  ## Node/edge identity (ABI.md §2): the id, for navigation without Cypher.
  if c == nil or outId == nil:
    setGlobalError("glyphes_cell_id: cell or out is null")
    return int32(glyErr)
  let cell = c[]
  if cell.tag != uint32(ord(glyNode)) and cell.tag != uint32(ord(glyEdge)):
    setGlobalError("glyphes_cell_id: cell is not a node or an edge")
    return int32(glyErr)
  outId[] = cast[int64](cell.aux)
  int32(glyOk)

proc glyphes_cell_len*(c: ptr GlyCell, outLen: ptr uint32): int32
    {.cdecl, exportc, dynlib.} =
  ## Element count for list/map/vector cells; byte length for strings.
  if c == nil or outLen == nil:
    setGlobalError("glyphes_cell_len: cell or out is null")
    return int32(glyErr)
  outLen[] = c[].len
  int32(glyOk)

{.pop.}