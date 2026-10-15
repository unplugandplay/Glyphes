## glyphes — the database handle object.
##
## Owns the three long-lived things a database is: the store (M1), the
## write-ahead log (M2), and the write-transaction slot (M3). `glyphes_open`
## builds them, `glyphes_close` flushes them; nothing else in the tree
## constructs a store.
##
## Before M3 this object was a shell: it carried the counters `glyphes_stat`
## reported and nothing else, and the M1/M2/M3 modules were exercised only by
## the Nim tests. Every M3 entry point below is the first time the engine is
## reachable from the host process, which is why the wiring lives here rather
## than being spread across the exported procs in src/glyphes.nim.
##
## One database per process (PRD pin P1), so the writer claim is a field here
## and a field on the store (txn.nim `begin`), not a per-handle structure.

when defined(posix):
  import posix
elif defined(windows):
  import winlean
import std/os
import std/posix

import std/tables
import std/strformat
import std/strutils
import ./abi
import ./errors
import ./handles
import ./store/store
import ./store/prop
import ./store/revision
import ./store/vhist
import ./index/index
import ./cypher/expr
import ./wal/wal
import ./wal/snapshot
import ./wal/recover
import ./txn/txn

type
  Database* = ref object
    path*: string
    snapGen*: uint64      ## generation a node view last read at; views re-read,
                         ## but a view must not mix two generations
    mode*: int32
    readonly*: bool
    inMemory*: bool
    closed*: bool
    store*: GraphStore
    ## The index registry (M6.1). Owned here rather than by the store: an
    ## index is not in the file format (INDEX.md pin I2), so the format has
    ## no business knowing the index code exists.
    indices*: Indexes
    wal*: Wal               ## nil for a memory database or a read-only one
    recovery*: Recovery     ## what the last open had to do; reported by
                            ## integrity_check, which is the caller that
                            ## needs to know a torn tail was truncated
    ## Handle of the live write transaction, 0 when none. TXN.md §1 allows
    ## exactly one, so a slot rather than a set. glyphes_tx_commit checks
    ## it: a transaction handle that does not name this database's live
    ## transaction is stale, whatever the registry still says about it.
    writerTx*: GlyHandle
    nextTxId*: uint32

const
  MemoryPath* = ":memory:"


var openDbs*: seq[Database]      ## every live handle. `glyphes_stats` takes
## no handle — the header's signature is handle-free — so the only honest
## thing it can report is what the process holds, and a counter that does
## not exist is worse than one that does: a host would trust it.

proc isValidMode(mode: int32): bool =
  ## Reject unknown bits rather than ignoring them: a typo'd constant in
  ## ffi.rb should fail at open, not silently produce a read-write
  ## database when the caller meant read-only.
  const known = GLY_OPEN_READONLY or GLY_OPEN_CREATE or GLY_OPEN_MEMORY or
                GLY_OPEN_SNAPSHOT
  mode >= 0 and (mode and (not known)) == 0

proc replayHistory(store: GraphStore, path: string) =
  ## Rebuild `store.history` from the `.vhist` sidecar (PRD §4.1, V1.2).
  ##
  ## Replayed in the same open/seal sequence the live writer uses, so the
  ## in-memory history a reopen produces is byte-identical in shape to the one
  ## a running process holds — a history whose in-memory and on-disk forms
  ## diverged would make a diff mean different things before and after a
  ## restart, which is the failure a user cannot detect.
  ##
  ## A file that does not exist is "no history", not an error: history is
  ## additive and its loss costs the history and not the data (the same
  ## reasoning index.nim:657 gives for the `.indexes` sidecar). A file that
  ## exists and cannot be read is a refusal — the caller asked for durability
  ## and quietly continuing with an empty history would be the opposite.
  store.vhistPath = path
  store.vhistFile = openVhist(path)
  let replay = replayVhist(path, store.generation)

  for fr in replay.frames:
    let dec = decodeCommitPayload(fr.payload)
    let cid = store.history.openCommit("", dec.parents, dec.lsn)
    ## Every node the commit's `changed` names gets a revision folded from the
    ## frame's per-node rows. `changed` is authoritative (vhist.nim), so a
    ## node with no row records an empty live revision — the same state a
    ## commit that touched a node and left it identical would have.
    for id in dec.changed:
      let rev = dec.revisions.getOrDefault(id,
                Revision(commit: cid, live: true))
      store.history.noteRevision(cid, id, rev.props, rev.live, rev.removed)
    store.history.sealCommit(cid)
  store.histGeneration =
    if replay.frames.len > 0: replay.frames[^1].generation else: store.generation

  ## Cut the untrusted tail so a discarded frame is discarded once rather than
  ## re-examined — and declined — at every open.
  if replay.truncated:
    truncateVhist(path, replay.goodBytes)

proc openDatabase*(path: string, mode: int32): Database =
  ## `mode` must not ask for read-only and create at once; that pair has
  ## no coherent meaning.
  if not isValidMode(mode):
    fail(glyErr, fmt"unknown open mode bits {mode}")
  if path.len == 0:
    fail(glyErr, "empty database path")

  let memory = path == MemoryPath
  let wantCreate = (mode and GLY_OPEN_CREATE) != 0
  let snapshotOnly = (mode and GLY_OPEN_SNAPSHOT) != 0
  let readOnly = (mode and GLY_OPEN_READONLY) != 0

  if memory and readOnly:
    fail(glyErr, "a memory database cannot be read-only")

  if not memory:
    ## A database exists if either half of it does. The snapshot file is
    ## only written at a checkpoint (WAL.md §7), so a database whose
    ## commits have not reached the 64 MB auto-checkpoint threshold has a
    ## log and no `.glyph` file — and refusing to reopen that would make
    ## every write unreachable the moment the process closed.
    let snapshotExists = fileExists(path)
    let walExists = fileExists(path & "-wal")
    let parent = parentDir(path)
    if not snapshotExists and parent.len > 0 and parent != "." and not dirExists(parent):
      fail(glyErrIo, fmt"directory does not exist: {parent}")
    if not snapshotExists and not walExists and not wantCreate and not snapshotOnly:
      fail(glyErrIo, fmt"database does not exist: {path}")
    if snapshotExists and readOnly and access(cstring(path), 4) != 0:
      ## R_OK is 4 on POSIX. Deliberately not a permissions-bit test:
      ## those miss ACLs and, more to the point, ACLs and mount options
      ## are exactly the case where "open it read-only and see" is the
      ## honest check. A failure here still reports a precise error.
      fail(glyErrIo, fmt"database is not readable: {path}")

  new(result)
  result.path = path
  result.mode = mode
  result.readonly = readOnly
  result.inMemory = memory
  result.nextTxId = 1
  ## Store first, then recover into it: `recover` refuses a store that
  ## already holds records, so the order is load-bearing rather than
  ## stylistic.
  result.store = newStore()
  if not memory:
    try:
      ## WAL.md §5, in order: snapshot if there is one, then every frame
      ## above its LSN. A torn tail is truncated inside `recover` and
      ## reported in the result rather than raised, because a truncated
      ## tail is the ordinary `kill -9` case and not an open failure.
      result.recovery = recover(path, result.store)
    except ValueError as e:
      ## Bad magic, wrong format version, header CRC mismatch: the file
      ## is not a graph. GLY_ERR_IO, with the reason, because silently
      ## starting an empty store next to an unreadable file is how a
      ## database gets destroyed by the program that was supposed to read
      ## it.
      fail(glyErrIo, fmt"{path}: {e.msg}")
    except IOError as e:
      fail(glyErrIo, fmt"{path}: {e.msg}")

  ## The version history is replayed from its own sidecar, bounded by the
  ## graph's generation (PRD §4.1, V1.2). Done after `recover` so the bound is
  ## the generation the graph actually reached. A frame above it is a commit
  ## the graph never accepted — the crash-between-append-and-COMMIT case — and
  ## is dropped along with everything after it. A memory database has no
  ## sidecar and no history.
  if not memory and not readOnly:
    try:
      replayHistory(result.store, path)
    except IOError as e:
      fail(glyErrIo, fmt"{path}: {e.msg}")

  ## STORAGE.md / TXN.md §2: monotonic from 1. Zero is reserved so a
  ## zeroed GlyStat never reads as a valid generation. `recover` has
  ## already moved it forward if the file was ahead of 1.
  if result.store.generation == 0:
    result.store.generation = 1
  openDbs.add result

  ## An empty registry on open, then a rebuild for anything that was
  ## created. Index state is never in the WAL (INDEX.md pin I2), so a
  ## reopened database starts with no index contents and refills from live
  ## records — bounded by store size rather than by log length, and
  ## reproducible across versions. The definitions themselves come from
  ## `IndexDefs` (below), which is where a future `CREATE INDEX ON` write
  ## will land.
  result.indices = newIndexes()
  ## WAL.md §5 step 5, now implemented: the definitions come back from the
  ## sidecar and the *contents* are rebuilt from live records, because
  ## index state is never in the WAL (pin W5).
  for def in IndexDefs(result.store, path):
    discard result.indices.recreate(def)
  if result.indices.list().len > 0:
    result.indices.rebuild(result.store)

  ## The log is opened last, after recovery, so replay never races a
  ## writer. A memory database has none: nothing to recover from and
  ## nothing to recover to, and a `-wal` file beside ":memory:" would be
  ## a bug that survives until someone runs out of /tmp.
  if not memory and not snapshotOnly:
    try:
      result.wal = openWal(path & "-wal", readOnly)
    except IOError as e:
      fail(glyErrIo, fmt"{path}-wal: {e.msg}")

proc close*(db: Database) =
  ## An open write transaction is rolled back rather than committed or
  ## refused. Refusing would make `ensure`-based cleanup in Ruby fail on
  ## the exception path, which is the one path that must work; committing
  ## would write a half-finished transaction on the way out. WAL.md §3:
  ## a rollback marker goes in the log so recovery can see the
  ## transaction ended rather than died.
  if db.closed:
    fail(glyErrClosed, "database already closed")
  if db.writerTx != 0:
    let tx = lookup[WriteTransaction](db.writerTx, hkTransaction)
    discard tx.rollback()
    discard release[WriteTransaction](db.writerTx)
    db.writerTx = 0
  if db.wal != nil:
    ## Sync, do not checkpoint. A clean shutdown leaves a log to replay
    ## rather than a snapshot to read, which costs open time and saves
    ## close time; `glyphes_checkpoint` (WAL.md §6 auto-checkpoint) is not
    ## exported yet, and pretending close does it would mean writing a
    ## full snapshot on every Ruby `ensure` — the worst possible default
    ## for a per-request handle.
    db.wal.sync()
    closeWal(db.wal)
    db.wal = nil
  ## Close the history sidecar with the log. Every commit already synced it,
  ## so nothing is lost by not syncing here — but the handle has to be closed
  ## or its last buffered bytes never land, and a reader that reopens the file
  ## while this handle is still open sees a file that is short by whatever the
  ## stdio buffer is holding.
  if db.store != nil and db.store.vhistFile != nil:
    closeVhist(db.store.vhistFile)
    db.store.vhistFile = nil
  db.store = nil
  db.closed = true
  ## Out of the process-wide registry, or a closed handle's arena would
  ## keep being counted by `glyphes_stats` for the life of the process.
  for i, d in openDbs:
    if d.path == db.path and not d.closed:
      openDbs.delete(i)
      break

proc checkpoint*(db: Database, truncate = false, fsync = true) =
  ## WAL.md §6. Write the snapshot, then optionally shorten the log to the
  ## snapshot's LSN and fsync.
  ##
  ## The order is the whole contract: snapshot first, log second. A crash
  ## between the two leaves a snapshot with a log that still contains the
  ## frames it covers — recovery skips them by LSN and the data is right. The
  ## other order loses every commit after the truncation point with nothing
  ## to replay them from, which is the one outcome a WAL exists to prevent.
  ##
  ## The writer gate is taken for the duration: a checkpoint that raced a
  ## commit could write a snapshot older than the log position it then
  ## truncates to, and that window is a silent loss of the commits in
  ## between.
  if db.wal == nil or db.inMemory:
    return
  db.store.beginWrite()
  try:
    db.wal.sync()
    ## INDEX.md I14: compaction is where a vector index past its tombstone
    ## threshold is rebuilt, and not per delete — a delete must not pay
    ## for a rebuild, and a rebuild that happens on the twentieth deletion
    ## pays for a problem that may never occur. Checked here, once, where
    ## a full pass over the store is already happening.
    for name in db.indices.indexesNeedingRebuild():
      db.indices.rebuild(db.store, name)
    writeSnapshot(db.store, db.path, db.wal.highestLsn)
    writeIndexDefs(db.indices, db.path)
    if fsync:
      ## The rename in writeSnapshot is atomic; the fsync is what makes the
      ## *data* behind that name durable. Without it a crash can leave a
      ## name pointing at bytes that never reached the disk.
      let f = open(db.path, fmReadWriteExisting)
      discard posix.fdatasync(f.getFileHandle)
      close(f)
    if truncate:
      ## Drop every log frame the snapshot now contains, so recovery starts
      ## after them instead of replaying them on top. A checkpoint always
      ## snapshots at the log's current tip (WAL.md §6), so *every* frame
      ## in the log is covered and the correct cut is to zero. The first
      ## version asked `scanLsn` for the last frame's byte offset and cut
      ## there — which is the end of the whole log, so the flag silently
      ## did nothing and `wal_size` never fell.
      db.wal.truncateTo(0)
  finally:
    db.store.endWrite()

proc backup*(db: Database, dest: string) =
  ## WAL.md §3: a backup is a checkpoint-then-copy, so the result is a
  ## consistent pair (snapshot + log) rather than a file copied while a
  ## transaction was mid-commit.
  ##
  ## The copy goes through the writer gate for the same reason the
  ## checkpoint does, and the source file is the snapshot this database
  ## just wrote — not the log — because the snapshot is the state the log
  ## replays *on top of*.
  if db.wal == nil or db.inMemory:
    fail(glyErrUnsupported, "a memory database has nothing to back up")
  db.checkpoint(truncate = false, fsync = true)
  db.store.beginWrite()
  try:
    copyFile(db.path, dest)
    if fileExists(db.path & "-wal"):
      copyFile(db.path & "-wal", dest & "-wal")
    ## The definitions travel with the data. A backup that carried the
    ## snapshot and the log but not the sidecar would restore a database
    ## whose indexes did not exist — the data all there, the indexes gone,
    ## and every query that used one silently slower. The checkpoint above
    ## has just written the sidecar, so what is copied here is current.
    let sidecar = db.path & IndexSidecarSuffix
    if fileExists(sidecar):
      copyFile(sidecar, dest & IndexSidecarSuffix)
  finally:
    db.store.endWrite()

proc vacuum*(db: Database) =
  ## Rebuild every index from live records and write the snapshot.
  ## INDEX.md I14: a vector index whose tombstone ratio has passed its
  ## threshold is one whose walk pays for tombstones forever, and the fix
  ## is a rebuild from live records — bounded by store size, which is why
  ## it is an explicit call rather than something close does (close must
  ## not write a full snapshot; see `close`).
  if db.wal == nil or db.inMemory:
    return
  db.store.beginWrite()
  try:
    db.wal.sync()
    db.indices.rebuild(db.store)
    writeSnapshot(db.store, db.path, db.wal.highestLsn)
    writeIndexDefs(db.indices, db.path)
  finally:
    db.store.endWrite()

proc runtimeStatsJson*(): string =
  ## Process-wide allocator and arena counters, as JSON: the property
  ## arenas and generation counters of every open database. The header says
  ## "per-thread"; the arena is a store-wide bump allocator with no
  ## per-thread accounting, so this reports what is measured and this
  ## paragraph is the ABI.md record of the difference.
  var arenaBytes = 0'i64
  var newest = 0'u64
  var dbs = 0
  for db in openDbs:
    if db.store != nil:
      arenaBytes += int64(db.store.arena.used())
      if db.store.generation > newest:
        newest = db.store.generation
    inc dbs
  result = "{\"databases\":" & $dbs &
           ",\"arena_bytes\":" & $arenaBytes &
           ",\"generation\":" & $newest & "}"

proc schemaJson*(db: Database, labels, properties, indexes: bool): string =
  ## The schema, as JSON. `db.schema(labels: true, …)` in Ruby is this
  ## string parsed; the sections are switchable because a host that only
  ## wants index names should not pay to walk a million property keys.
  var parts: seq[string] = @[]
  if labels:
    var names: seq[string] = @[]
    for code in 1 .. db.store.labels.count:
      let nm = db.store.labels.nameOf(int32(code))
      if nm.len > 0:
        names.add quoteJson(nm)
    parts.add "\"labels\":[" & names.join(",") & "]"
  if properties:
    var names: seq[string] = @[]
    for code in 1 .. db.store.propKeys.count:
      let nm = db.store.propKeys.nameOf(int32(code))
      if nm.len > 0:
        names.add quoteJson(nm)
    parts.add "\"properties\":[" & names.join(",") & "]"
  if indexes:
    var entries: seq[string] = @[]
    for d in db.indices.list():
      entries.add "{\"name\":" & quoteJson(d.name) &
                  ",\"kind\":" & $ord(d.kind) &
                  ",\"target\":" & quoteJson(d.target) &
                  ",\"property\":" & quoteJson(d.property) &
                  ",\"constraint\":" & $ord(d.constraint) &
                  ",\"generation\":" & $d.generation & "}"
    parts.add "\"indexes\":[" & entries.join(",") & "]"
  "{" & parts.join(",") & "}"

proc nodeJson*(db: Database, id: int64, labels, properties: bool): string =
  ## A node as JSON, for `glyphes_node_props` / `_labels` (RUBY.md §4.2).
  ## The reads go through the store's published arrays and the snapshot's
  ## generation, so a Node view re-reads current state — views, not copies.
  if not db.store.nodeExists(id):
    return ""
  if db.snapGen == 0:
    db.snapGen = db.store.generation
  var parts: seq[string] = @[]
  parts.add "\"id\":" & $id
  if labels:
    let nm = db.store.labels.nameOf(db.store.nodes[id.int].label)
    parts.add "\"labels\":[" & (if nm.len > 0: quoteJson(nm) else: "") & "]"
  if properties:
    var props: seq[string] = @[]
    for key in db.store.nodePropKeys(id):
      var v = Value(kind: vkNull)
      if db.store.getNodeProp(id, key, v):
        props.add quoteJson(key) & ":" & valueJson(v)
    parts.add "\"properties\":{" & props.join(",") & "}"
  "{" & parts.join(",") & "}"

proc assertOpen*(db: Database) =
  if db.closed:
    fail(glyErrClosed, fmt"database {db.path} is closed")

proc walSize*(db: Database): int64 =
  ## Bytes in the log, from the open handle's own size rather than
  ## stat(): the handle was opened O_APPEND and every frame since then
  ## went through it, so its counter is exact and a syscall is not.
  if db.wal == nil:
    return 0
  db.wal.size

proc statOf*(db: Database): GlyStat =
  db.assertOpen
  let st = db.store.stats()
  result.nodes = uint64(st.nodes)
  result.edges = uint64(st.edges)
  result.labels = uint64(st.labels)
  result.relTypes = uint64(st.relTypes)
  result.properties = uint64(st.properties)
  result.bytesResident = uint64(st.arenaBytes)
  result.walBytes = uint64(db.walSize)
  result.generation = db.store.generation

# ------------------------------------------------------------ transactions

proc beginTransaction*(db: Database): WriteTransaction =
  ## TXN.md §1: one writer, and a second one is `GLY_ERR_BUSY` rather than
  ## a wait. The claim itself is `store.claimWriter` inside `txn.begin`,
  ## as one compare-and-swap, so the check and the claim cannot be
  ## separated.
  db.assertOpen
  if db.readonly:
    fail(glyErrReadOnly, fmt"database {db.path} is read-only")
  if db.wal == nil and not db.inMemory:
    ## A snapshot-only database has no log and is not scratch either: it
    ## is somebody's durable file opened for reading. Writing to it with
    ## nowhere to be durable is a mistake worth refusing. A memory
    ## database is the opposite case — nothing to lose — and takes a
    ## transaction with `wal == nil` (txn.nim `begin`), exactly as
    ## SQLite's `:memory:` does.
    fail(glyErrReadOnly, fmt"database {db.path} is snapshot-only")
  if db.writerTx != 0:
    fail(glyErrBusy, "a write transaction is already active on this database")
  let id = db.nextTxId
  inc db.nextTxId
  result = txn.begin(db.store, db.wal, id)
  ## The index learns about this transaction's writes inside the commit's
  ## write exclusion (see `WriteTransaction.indicesToUpdate`), from the same
  ## deltas, in the one place that decides when an index is updated. An
  ## index is never stale relative to committed data because it is updated
  ## before the commit returns — not because five call sites remember to.
  result.indicesToUpdate = db.indices

proc attachTransaction*(db: Database, h: GlyHandle) =
  ## Claims the database's single writer slot for `h`. Kept separate from
  ## beginTransaction because the handle only exists once the boundary has
  ## registered it, and a slot pointing at a handle the caller does not
  ## hold would be a dangling reference.
  db.writerTx = h

proc assertOwns*(db: Database, h: GlyHandle, tx: WriteTransaction) =
  ## Two facts, both required: this database's writer slot names this
  ## transaction, and the transaction is built on this database's store.
  ## The first rejects a foreign or already-finished handle; the second
  ## rejects a store swap that the slot check alone would miss.
  if db.writerTx != h:
    fail(glyErrStale, "transaction handle is not this database's live transaction")
  if tx.store != db.store:
    fail(glyErrStale, "transaction belongs to a different database")

proc releaseTransaction*(db: Database) =
  db.writerTx = 0

proc commitTransaction*(db: Database, tx: WriteTransaction): bool =
  ## `txn.commit` bumps the store's generation, so the slot is cleared
  ## only on success: a failed commit leaves the transaction live and
  ## rollback-able, which is the only honest state for one that did not
  ## merge.
  if not tx.commit():
    return false
  db.releaseTransaction
  true

proc rollbackTransaction*(db: Database, tx: WriteTransaction): bool =
  if not tx.rollback():
    return false
  db.releaseTransaction
  true

proc txInfoOf*(tx: WriteTransaction): GlyTxInfo =
  ## Counts of what the transaction has written, read off its own deltas
  ## rather than off the store: a rollback reports what it discarded, and
  ## that is the number a caller diagnosing a failed import wants.
  result.id = uint64(tx.id)
  result.nodesWritten = uint64(tx.nodeDelta.len)
  result.edgesWritten = uint64(tx.edgeDelta.len)
  var props = 0
  for _, pv in tx.nodeProps:
    props += tx.store.arena.readSlots(pv).len
  for _, pv in tx.edgeProps:
    props += tx.store.arena.readSlots(pv).len
  result.propertiesWritten = uint64(props)
  result.walBytes = uint64(tx.walBytes)

# --------------------------------------------------------- integrity check

proc integrityReport*(db: Database): string =
  ## Read-only: runs the store's S1-S10 invariants (`store.check`) and
  ## reports what open had to do. It does not verify the snapshot's CRC
  ## against its own contents — `loadSnapshot` already refuses that at
  ## open, and a check that could only ever re-run the same code would
  ## be theatre. What it adds is the invariant sweep and the recovery
  ## facts, which is what a user asking "is my file sound?" is asking.
  ##
  ## Built as a seq of lines and joined, not by appending "\n" to a fmt
  ## string: `fmt` does not process escapes, so `fmt"...\n"` writes a
  ## literal backslash-n into the report — a detail nobody notices until
  ## they print it.
  db.assertOpen
  var lines: seq[string] = @["glyphes integrity check"]
  let st = db.store.stats()
  lines.add "database: " & db.path
  lines.add "generation: " & $db.store.generation
  lines.add "nodes: " & $st.nodes & "  edges: " & $st.edges &
            "  labels: " & $st.labels
  lines.add "rel_types: " & $st.relTypes & "  properties: " & $st.properties
  lines.add "arena_bytes: " & $st.arenaBytes & "  wal_bytes: " & $db.walSize
  if db.recovery.snapshotFound:
    lines.add "snapshot: found, lsn " & $db.recovery.snapshotLsn &
              ", generation " & $db.recovery.snapshotGeneration
  else:
    lines.add "snapshot: absent"
  lines.add "wal_frames_replayed: " & $db.recovery.framesReplayed
  lines.add "transactions_committed: " & $db.recovery.transactionsCommitted
  lines.add "transactions_discarded: " & $db.recovery.transactionsDiscarded
  if db.recovery.tornTail:
    ## Named, not hidden. A tail that was truncated is a fact about the
    ## last crash, and a database that silently dropped it would be
    ## indistinguishable from one that lost nothing.
    lines.add "torn_tail: truncated (" & db.recovery.tornReason & ")"
  else:
    lines.add "torn_tail: none"

  var failures = 0
  for inv in db.store.check():
    if not inv.ok:
      inc failures
      lines.add "FAIL " & inv.code & ": " & inv.detail
  lines.add(if failures == 0: "invariants: S1-S10 ok"
            else: "invariants: " & $failures & " failing")
  result = lines.join("\n") & "\n"