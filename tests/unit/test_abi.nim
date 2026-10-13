## glyphes — M3: the transaction surface as a *foreign caller* sees it.
##
## Every other suite in this directory drives the engine from the inside:
## `newStore()`, `begin(store, wal, id)`, `commit(tx)`. That proves the
## engine. It does not prove the thing M3 actually delivers — that the
## functions in src/glyphes.h are reachable, correctly typed, and safe
## against a caller that knows nothing about Nim.
##
## So this file calls the exported procs themselves, through `GlyHandle`
## integers, exactly as C and Ruby do:
##
##   - `glyphes_tx_begin` hands back a uintptr_t. To write anything, the
##     test has to resolve that handle back to the engine's transaction
##     object — which is what a future statement layer will do, and is why
##     this file is allowed to import src/handles.
##   - failures must arrive as GlyStatus numbers, never as exceptions;
##   - a stale or wrong-kind handle must be refused, not dereferenced
##     (ABI.md B4).
##
## The Ruby suite (tests/e2e/test_m3.rb) proves the same surface through
## FFI. Between them, a regression in the boundary cannot hide behind a
## green engine test.

import std/unittest
import std/os
import ../../src/abi
import ../../src/errors
import ../../src/handles
import ../../src/glyphes
import ../../src/database
import ../../src/store/store
import ../../src/store/prop
import ../../src/txn/txn

proc abiDir(): string =
  let d = "tmp" / "test-abi"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = abiDir() / name
  removeFile(p); removeFile(p & "-wal"); removeFile(p & ".tmp")
  result = p

proc openAt(path: string; mode = int32(GLY_OPEN_CREATE)): GlyHandle =
  ## Through the exported proc, not `openDatabase`, so the handle
  ## encoding and the registration are part of what is under test.
  ##
  ## `mode = 0` is read-write with no CREATE and no snapshot-only: the
  ## reopen cases below use it, and they have to be able to fail with
  ## "does not exist" rather than silently creating anything.
  var h: GlyHandle
  let status = glyphes_open(path.cstring, mode, addr h)
  if status != 0:
    raise newException(AssertionDefect,
      "glyphes_open(" & path & ") -> " & $status & ": " & globalErrorMsg())
  h

proc txOf(h: GlyHandle): WriteTransaction =
  ## What the statement layer will do at M4: resolve a handle to the
  ## object it names. Typed, so a wrong-kind handle raises here rather
  ## than corrupting something downstream.
  lookup[WriteTransaction](h, hkTransaction)

proc statOfHandle(h: GlyHandle): GlyStat =
  var st: GlyStat
  check glyphes_stat(h, addr st) == 0
  st

suite "ABI: transactions (M3, PRD phase A row 3)":
  test "tx_begin returns a usable handle and commit is visible in stat":
    let path = freshPath("tx-commit.glyph")
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    check txh != 0

    let tx = txOf(txh)
    let id = tx.createNode("Person")
    check id > 0
    check tx.setNodeProp(id, "name", Value(kind: vkString, s: "Ana"))
    let other = tx.createNode("Person")
    check tx.createEdge(id, other, "KNOWS") > 0

    ## tx_info reports the delta, not the store: TXN.md §3.
    var info: GlyTxInfo
    check glyphes_tx_info(txh, addr info) == 0
    check info.nodesWritten == 2
    check info.edgesWritten == 1
    check info.propertiesWritten == 1

    check glyphes_tx_commit(dbh, txh) == 0

    let st = statOfHandle(dbh)
    check st.nodes == 2
    check st.edges == 1
    check st.labels == 1
    check st.generation == 2          ## bumped once per commit (X4)
    check st.walBytes > 0
    check glyphes_close(dbh) == 0

  test "a committed transaction survives close and reopen (WAL replay)":
    let path = freshPath("tx-reopen.glyph")
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    let id = txOf(txh).createNode("Doc")
    discard txOf(txh).setNodeProp(id, "title",
      Value(kind: vkString, s: "Graph Databases"))
    check glyphes_tx_commit(dbh, txh) == 0
    check glyphes_close(dbh) == 0

    ## No checkpoint is exported yet, so the snapshot file does not exist
    ## and this open recovers from the log alone. That is the case that
    ## has to work: it is the state every database is in between two
    ## checkpoints.
    let again = openAt(path, 0)
    let st = statOfHandle(again)
    check st.nodes == 1
    check st.labels == 1
    check st.generation == 2
    let db = lookup[Database](again, hkDatabase)
    var v: Value
    check db.store.getNodeProp(1, "title", v)
    check v.s == "Graph Databases"
    check glyphes_close(again) == 0

  test "rollback leaves the store exactly as it was (gate T3)":
    let path = freshPath("tx-rollback.glyph")
    let dbh = openAt(path)
    var keep: GlyHandle
    check glyphes_tx_begin(dbh, addr keep) == 0
    discard txOf(keep).createNode("Keep")
    check glyphes_tx_commit(dbh, keep) == 0
    let before = statOfHandle(dbh)

    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    let tx = txOf(txh)
    for i in 0 ..< 100:
      let id = tx.createNode("Temp")
      discard tx.setNodeProp(id, "i", Value(kind: vkInt, i: int64(i)))
    check glyphes_tx_rollback(dbh, txh) == 0

    ## Generation must not move for a rollback: the base was never
    ## touched, so there is nothing to publish (TXN.md §3).
    let after = statOfHandle(dbh)
    check after.nodes == before.nodes
    check after.edges == before.edges
    check after.generation == before.generation
    let db = lookup[Database](dbh, hkDatabase)
    var v: Value
    ## And the burned ids must not be visible either.
    check not db.store.getNodeProp(2, "i", v)
    check glyphes_close(dbh) == 0

  test "a second tx_begin is GLY_ERR_BUSY, not a wait (gate T5)":
    let path = freshPath("tx-busy.glyph")
    let dbh = openAt(path)
    var first: GlyHandle
    check glyphes_tx_begin(dbh, addr first) == 0
    var second: GlyHandle
    let status = glyphes_tx_begin(dbh, addr second)
    check status == int32(glyErrBusy)
    check second == 0                ## never handed out on failure
    check glyphes_tx_rollback(dbh, first) == 0
    ## The claim is released by finishing, so the next begin succeeds.
    var third: GlyHandle
    check glyphes_tx_begin(dbh, addr third) == 0
    check glyphes_tx_commit(dbh, third) == 0
    check glyphes_close(dbh) == 0

  test "a transaction handle is stale once it has been committed":
    let path = freshPath("tx-stale.glyph")
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    discard txOf(txh).createNode("A")
    check glyphes_tx_commit(dbh, txh) == 0
    ## Reusing the handle must be refused, not dereferenced: this is what
    ## makes `ensure`-based cleanup safe in Ruby (ABI.md B4).
    check glyphes_tx_commit(dbh, txh) == int32(glyErrStale)
    check glyphes_tx_rollback(dbh, txh) == int32(glyErrStale)
    check glyphes_tx_info(txh, nil) == int32(glyErr)
    check glyphes_close(dbh) == 0

  test "a database handle is not a transaction handle":
    let path = freshPath("tx-kind.glyph")
    let dbh = openAt(path)
    check glyphes_tx_commit(dbh, dbh) == int32(glyErrStale)
    check glyphes_tx_rollback(dbh, dbh) == int32(glyErrStale)
    check glyphes_tx_info(dbh, nil) == int32(glyErr)
    var st: GlyStat
    check glyphes_stat(dbh, addr st) == 0
    check glyphes_close(dbh) == 0

  test "a read-only database refuses a transaction":
    let path = freshPath("tx-readonly.glyph")
    discard openAt(path)
    let ro = openAt(path, GLY_OPEN_READONLY)
    var txh: GlyHandle
    check glyphes_tx_begin(ro, addr txh) == int32(glyErrReadOnly)
    check txh == 0
    check glyphes_close(ro) == 0

  test "closing a database rolls back an open transaction":
    let path = freshPath("tx-close-rollback.glyph")
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    discard txOf(txh).createNode("Doomed")
    ## The host is going away with a transaction open. The engine must not
    ## commit it, and must not leave the writer claimed — which is what a
    ## Ruby `ensure` block does on the exception path.
    check glyphes_close(dbh) == 0

    let again = openAt(path, 0)
    check statOfHandle(again).nodes == 0
    check glyphes_close(again) == 0

suite "ABI: integrity check (M3)":
  test "the report is well-formed and the invariants pass":
    let path = freshPath("integrity.glyph")
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    let a = txOf(txh).createNode("A")
    let b = txOf(txh).createNode("B")
    discard txOf(txh).createEdge(a, b, "REL")
    check glyphes_tx_commit(dbh, txh) == 0

    var report: cstring
    check glyphes_integrity_check(dbh, addr report) == 0
    check not report.isNil
    let text = $report
    check text.contains("invariants: S1-S10 ok")
    check text.contains("nodes: 2")
    check text.contains("edges: 1")
    check text.contains("torn_tail: none")
    check glyphes_close(dbh) == 0

  test "a null out-param is an error, not a crash":
    let path = freshPath("integrity-null.glyph")
    let dbh = openAt(path)
    check glyphes_integrity_check(dbh, nil) == int32(glyErr)
    check glyphes_close(dbh) == 0

suite "ABI: the handle registry does not leak (ABI.md §3)":
  test "every handle taken here is still accounted for":
    let path = freshPath("handles.glyph")
    let base = liveHandleCount()
    let dbh = openAt(path)
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    check liveHandleCount() == base + 2
    ## A failed begin must not leave a slot behind.
    var second: GlyHandle
    discard glyphes_tx_begin(dbh, addr second)
    check liveHandleCount() == base + 2
    check glyphes_tx_commit(dbh, txh) == 0
    check liveHandleCount() == base + 1
    check glyphes_close(dbh) == 0
    check liveHandleCount() == base