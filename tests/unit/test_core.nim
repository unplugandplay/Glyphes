## glyphes — Nim-side tests.
##
## M0 runs the handle registry and the status vocabulary, because those
## are the two pieces the ABI depends on and neither is exercised by the
## Ruby suite beyond "does it not crash". Later milestones add store,
## WAL and query tests per docs/TESTING.md §3.

import std/os
import std/unittest

import ../../src/abi
import ../../src/errors
import ../../src/handles
import ../../src/database

suite "status vocabulary":
  test "ordinals match the C enum":
    # The ordinals are the contract (ABI.md B1). A reordering here
    # silently reinterprets every status on the Ruby side.
    check ord(glyOk) == 0
    check ord(glyMore) == 1
    check ord(glyDone) == 2
    check ord(glyErr) == -1
    check ord(glyErrClosed) == -2
    check ord(glyErrStale) == -3
    check ord(glyErrSql) == -4
    check ord(glyErrConstraint) == -5
    check ord(glyErrIo) == -6
    check ord(glyErrReadOnly) == -7
    check ord(glyErrBusy) == -8
    check ord(glyErrLimit) == -9
    check ord(glyErrNoMem) == -10
    check ord(glyErrUnsupported) == -11

  test "names spell the C enum":
    check statusName(glyOk) == "GLY_OK"
    check statusName(glyErrStale) == "GLY_ERR_STALE"
    check statusName(GlyStatus(-99)) == "GLY_ERR_UNKNOWN(-99)"

  test "errors are negative, progress is not":
    for s in [glyOk, glyMore, glyDone]:
      check not statusIsError(s)
    for s in [glyErr, glyErrClosed, glyErrStale, glyErrSql,
              glyErrConstraint, glyErrIo, glyErrReadOnly, glyErrBusy,
              glyErrLimit, glyErrNoMem, glyErrUnsupported]:
      check statusIsError(s)

suite "struct layouts":
  # TESTING.md Q3: layout is asserted against the spec, not against the
  # implementation. GlyCell 24 / GlyPath 32 / GlyStat 64 / GlyTxInfo 40.
  test "GlyCell is 24 bytes":
    check sizeof(GlyCell) == 24

  test "GlyPath is 32 bytes":
    check sizeof(GlyPath) == 32

  test "GlyStat is 64 bytes":
    check sizeof(GlyStat) == 64

  test "GlyTxInfo is 40 bytes":
    check sizeof(GlyTxInfo) == 40

  test "GlyCell field offsets match docs/ABI.md":
    # u32 tag, u32 len, ptr, u64 aux
    check cast[uint](offsetOf(GlyCell, tag)) == 0
    check cast[uint](offsetOf(GlyCell, len)) == 4
    check cast[uint](offsetOf(GlyCell, `ptr`)) == 8
    check cast[uint](offsetOf(GlyCell, aux)) == 16

suite "handle registry":
  test "a fresh handle is live":
    let h = register(hkDatabase, new(Database))
    check isLive(h)
    check liveHandleCount() == 1
    discard release[Database](h)

  test "a released handle is stale":
    let h = register(hkDatabase, new(Database))
    discard release[Database](h)
    check not isLive(h)
    check liveHandleCount() == 0

  test "null is never live":
    check not isLive(0)

  test "generation bumps so a reused slot is distinguishable":
    # ABI.md B4. Without the bump, slot 0 with generation 1 would be
    # indistinguishable from the second object that reuses it.
    let h1 = register(hkDatabase, new(Database))
    discard release[Database](h1)
    let h2 = register(hkDatabase, new(Database))

    check slotIndex(h1) == slotIndex(h2)     # same slot, reused
    check generationOf(h1) != generationOf(h2)
    check not isLive(h1)                     # the old value stays stale
    check isLive(h2)
    discard release[Database](h2)

  test "handles carry both a slot and a generation":
    let h = register(hkDatabase, new(Database))
    check generationOf(h) >= 1
    check slotIndex(h) < int(1'u64 shl GenerationShift)
    discard release[Database](h)

  test "lookup rejects a released handle":
    let h = register(hkDatabase, new(Database))
    discard release[Database](h)
    expect ValueError:
      discard lookup[Database](h, hkDatabase)

  test "lookup rejects a null handle":
    expect ValueError:
      discard lookup[Database](0, hkDatabase)

  test "lookup rejects a wrong-kind handle":
    let h = register(hkStatement, new(Database))
    expect ValueError:
      discard lookup[Database](h, hkDatabase)
    discard release[Database](h)

  test "many handles round-trip":
    let n = 500
    var handles = newSeq[GlyHandle](n)
    for i in 0 ..< n:
      handles[i] = register(hkDatabase, new(Database))
    check liveHandleCount() == n
    for i in 0 ..< n:
      check isLive(handles[i])
    for h in handles:
      discard release[Database](h)
    check liveHandleCount() == 0

  test "handle-local error text":
    let h = register(hkDatabase, new(Database))
    setError(h, "something went wrong")
    check lastError(h) == "something went wrong"
    discard release[Database](h)
    check lastError(h) == ""

suite "error slots":
  test "the global slot round-trips":
    setGlobalError("boom")
    check globalErrorMsg() == "boom"
    check globalErrorCStr() != nil
    check $globalErrorCStr() == "boom"
    clearGlobalError()
    check globalErrorMsg() == ""
    check globalErrorCStr() == nil

  test "setting twice frees the previous buffer":
    # The cstring mirror is reallocated on every set. Doing this a
    # thousand times under ASan is what proves there is no leak.
    for i in 0 ..< 1000:
      setGlobalError("message " & $i & " with some padding to make it non-trivial")
    clearGlobalError()

  test "an empty message yields no cstring":
    setGlobalError("")
    check globalErrorCStr() == nil
    clearGlobalError()

suite "database open":
  test "memory database opens":
    let db = openDatabase(":memory:", GLY_OPEN_MEMORY)
    check db.inMemory
    check db.store.generation == 1     # TXN.md X4. On the store, not on
                                       # the Database: generation is
                                       # bumped by the merge, so a second
                                       # copy on the handle would be a
                                       # second thing to keep in step.
    db.close()

  test "closing twice is an error, not a crash":
    let db = openDatabase(":memory:", GLY_OPEN_MEMORY)
    db.close()
    expect GlyError:
      db.close()

  test "stat on a closed database is a closed error":
    let db = openDatabase(":memory:", GLY_OPEN_MEMORY)
    db.close()
    expect GlyError:
      discard statOf(db)

  test "a fresh stat reports zeros and generation 1":
    let db = openDatabase(":memory:", GLY_OPEN_MEMORY)
    let s = statOf(db)
    check s.nodes == 0
    check s.edges == 0
    check s.generation == 1
    db.close()

  test "unknown mode bits are rejected":
    expect GlyError:
      discard openDatabase(":memory:", GLY_OPEN_MEMORY or (1 shl 20))

  test "an empty path is rejected":
    expect GlyError:
      discard openDatabase("", GLY_OPEN_MEMORY)

  test "memory plus read-only has no coherent meaning":
    expect GlyError:
      discard openDatabase(":memory:", GLY_OPEN_MEMORY or GLY_OPEN_READONLY)

  test "a missing file without create is an IO error":
    let path = getTempDir() / "glyphes-does-not-exist-" & $getCurrentProcessId() & ".glyph"
    removeFile(path)
    expect GlyError:
      discard openDatabase(path, 0)
    removeFile(path)

  test "a missing parent directory is an IO error":
    let path = getTempDir() / "glyphes-no-such-dir-" & $getCurrentProcessId() / "x.glyph"
    expect GlyError:
      discard openDatabase(path, GLY_OPEN_CREATE)

suite "databases are independent":
  test "two open databases do not share state":
    let a = openDatabase(":memory:", GLY_OPEN_MEMORY)
    let b = openDatabase(":memory:", GLY_OPEN_MEMORY)
    a.store.generation = 7
    check b.store.generation == 1
    a.close()
    # Closing a must not disturb b.
    check b.store.generation == 1
    discard statOf(b)
    b.close()
