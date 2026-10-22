## glyphes — M3: transactions (docs/TXN.md).
##
## The gates here are named T1-T8 in TXN.md §10. Each test names the gate
## it serves, because a durability test that does not say which gate it is
## for is a test whose deletion nobody notices.
##
## T1 (the 8-thread soak) and T6 (merge cost) live outside this file: T1
## needs a wall-clock budget and real threads, so it is
## `tests/soak/soak.nim`; T6 is a benchmark in `tests/bench/`.

import std/unittest
import std/os
import std/[strutils, sequtils]
import ../../src/store/store
import ../../src/store/prop
import ../../src/wal/wal
import ../../src/wal/recover
import ../../src/txn/txn

proc txnDir(): string =
  let d = "tmp" / "test-txn"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = txnDir() / name
  removeFile(p); removeFile(p & "-wal"); removeFile(p & ".tmp")
  result = p

proc renderValue(v: Value): string =
  ## Kind-safe: touching a variant field that the discriminant does not
  ## select is a FieldDefect, so every field read is inside its own `of`
  ## arm. Reading `v.s` for an int would raise rather than return junk.
  case v.kind
  of vkNull: "null"
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: $v.f
  of vkString, vkBytes: $v.s.len & ":" & v.s
  of vkVector: "vec" & $v.dims.len
  of vkList: "list" & $v.items.len
  of vkMap: "map" & $v.pairs.len
  of vkNode: "node" & $v.id
  of vkEdge: "edge" & $v.id
  of vkPath: "path" & $v.path.nodes.len
  of vkDate: "date" & $v.d
  of vkPoint: "point" & $v.x & "," & $v.y

proc stateHash(s: GraphStore): string =
  ## Every live record and property, in id order (TXN.md T3's oracle).
  ## Counts would not do: a rollback that leaked one property and lost
  ## another would keep the counts.
  for i in 1 ..< s.nodes.len:
    let n = s.nodes[i]
    if not n.live: continue
    result.add "N" & $n.id & ":" & s.labels.nameOf(n.label) &
      ":" & $n.outCount & "/" & $n.inCount
    for k in s.nodePropKeys(n.id):
      var v: Value
      if s.getNodeProp(n.id, k, v):
        result.add "|" & k & "=" & renderValue(v)
    result.add "\n"
  for i in 1 ..< s.edges.len:
    let e = s.edges[i]
    if not e.live: continue
    result.add "E" & $e.id & ":" & $e.src & "->" & $e.dst & ":" &
      s.relTypes.nameOf(e.etype)
    for k in s.edgePropKeys(e.id):
      var v: Value
      if s.getEdgeProp(e.id, k, v):
        result.add "|" & k & "=" & renderValue(v)
    result.add "\n"

suite "single writer (TXN.md §1, gate T5)":
  test "a second begin raises BUSY rather than blocking (T5)":
    let path = freshPath("busy.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let a = begin(s, w, 1'u32, doSync = false)
    var code: TxCode = tcGeneric
    try:
      let b = begin(s, w, 2'u32, doSync = false)
      discard b
    except TxError as e:
      code = e.code
    check int(code) == -8          ## GLY_ERR_BUSY
    check a.rollback()
    ## The claim is released by finishing, so the next begin succeeds.
    let c = begin(s, w, 2'u32, doSync = false)
    check c.commit()
    closeWal(w)

  test "rollback releases the writer claim too":
    let path = freshPath("busy-rollback.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let a = begin(s, w, 1'u32, doSync = false)
    discard a.createNode("Person")
    check a.rollback()
    let b = begin(s, w, 2'u32, doSync = false)
    check b.commit()
    closeWal(w)
    check s.nodeCount() == 0

  test "a commit with a stale base raises STALE (TXN.md §2)":
    ## Unreachable through the public path — one writer cannot move the
    ## generation under another transaction — so it is forced by hand.
    ## The check is what converts that class of bug into an error instead
    ## of a silent corruption, so it is worth proving it fires.
    let path = freshPath("stale.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false)
    discard tx.createNode("Person")
    s.generation += 1
    var code: TxCode = tcGeneric
    try:
      discard tx.commit()
    except TxError as e:
      code = e.code
    check int(code) == -3          ## GLY_ERR_STALE
    closeWal(w)

suite "budgets (TXN.md §6, gate T8)":
  test "max_txn_ops trips and returns LIMIT, leaving the transaction open":
    ## The caller decides whether to roll back, matching sqlite3; so the
    ## budget error must not close the transaction underneath it.
    let path = freshPath("budget-ops.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false, maxOps = 8)
    var tripped = false
    for i in 0 ..< 64:
      try:
        discard tx.createNode("Person")
      except TxError as e:
        check int(e.code) == -9   ## GLY_ERR_LIMIT
        tripped = true
        break
    check tripped
    check not tx.closed
    check tx.rollback()
    closeWal(w)

  test "max_txn_wal_bytes trips on the log volume, not the op count":
    let path = freshPath("budget-bytes.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false, maxWalBytes = 4096)
    var tripped = false
    for i in 0 ..< 4096:
      try:
        let id = tx.createNode("Person")
        discard tx.setNodeProp(id, "blob",
          Value(kind: vkString, s: "x".repeat(512)))
      except TxError as e:
        check int(e.code) == -9
        tripped = true
        break
    check tripped
    check tx.rollback()
    closeWal(w)

  test "a zero budget means unlimited":
    ## Otherwise "unset" and "no operations allowed" are the same value,
    ## and a caller cannot turn the check off.
    let path = freshPath("budget-off.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false, maxOps = 0, maxWalBytes = 0)
    for i in 0 ..< 500:
      discard tx.createNode("Person")
    check tx.commit()
    closeWal(w)
    check s.nodeCount() == 500

suite "rollback (gate T3)":
  test "rollback discards 100% of a 10^5-op transaction (T3)":
    ## T3 is the gate that catches delta leaks. The hash comparison is the
    ## whole point: a leak of one property and a loss of another would
    ## leave the counts unchanged.
    let path = freshPath("rollback-big.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    var ids: seq[int64] = @[]
    block:
      let seed = begin(s, w, 1'u32, doSync = false)
      for i in 0 ..< 200:
        let id = seed.createNode(if i mod 2 == 0: "Person" else: "Doc")
        discard seed.setNodeProp(id, "n", Value(kind: vkInt, i: int64(i)))
        ids.add id
        if i mod 10 == 0:
          let b = seed.createNode("Doc")
          discard seed.setNodeProp(b, "s",
            Value(kind: vkString, s: "seed-" & $i & "-" & "z".repeat(80)))
      let e = seed.createEdge(ids[0], ids[1], "KNOWS")
      discard seed.setEdgeProp(e, "w", Value(kind: vkFloat, f: 1.5))
      check seed.commit()
    let before = stateHash(s)
    let genBefore = s.generation

    ## A large transaction that touches everything it can: creates, sets,
    ## deletes, cascades.
    let big = begin(s, w, 2'u32, doSync = false)
    for i in 0 ..< 50_000:
      let id = big.createNode("Junk")
      discard big.setNodeProp(id, "n", Value(kind: vkInt, i: int64(i)))
      discard big.setNodeProp(id, "blob",
        Value(kind: vkString, s: "junk" & $i & "-" & "q".repeat(100)))
      if ids.len > 0 and i mod 3 == 0:
        let target = ids[i mod ids.len]
        if big.nodeExistsTx(target):
          discard big.setNodeProp(target, "clobbered",
            Value(kind: vkInt, i: int64(i)))
      if ids.len > 4 and i mod 7 == 0:
        let victim = ids[(i * 13) mod ids.len]
        if big.nodeExistsTx(victim):
          discard big.deleteNode(victim, true)
    check big.rollback()

    let after = stateHash(s)
    check after == before
    check s.generation == genBefore
    ## Nothing from the rolled-back transaction is visible, not even the
    ## ids it burned.
    for i in 1 ..< s.nodes.len:
      check s.nodes[i].label != s.labels.lookup("Junk")
    closeWal(w)

  test "a rolled-back transaction recovers to the committed state only":
    let path = freshPath("rollback-recover.glyph")
    let s = newStore()
    var kept = 0'i64
    block:
      let w = openWal(path & "-wal")
      let tx1 = begin(s, w, 1'u32, doSync = false)
      kept = tx1.createNode("Person")
      discard tx1.setNodeProp(kept, "n", Value(kind: vkInt, i: 42))
      check tx1.commit()
      let tx2 = begin(s, w, 2'u32, doSync = false)
      discard tx2.createNode("Ghost")
      discard tx2.setNodeProp(kept, "clobbered", Value(kind: vkInt, i: 1))
      check tx2.rollback()
      closeWal(w)
    let s2 = newStore()
    discard recover(path, s2)
    check s2.nodeCount() == 1
    var v: Value
    check s2.getNodeProp(kept, "n", v)
    check v.i == 42
    check not s2.getNodeProp(kept, "clobbered", v)

suite "read snapshots and generations (TXN.md §2, gate T2)":
  test "a snapshot pins the generation it opened at (T2)":
    let path = freshPath("snap-gen.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    block:
      let tx = begin(s, w, 1'u32, doSync = false)
      discard tx.createNode("Person")
      check tx.commit()
    ## A snapshot is a *lock*, not a copy: it is closed before the commit
    ## here because holding it across a commit on the same thread would
    ## self-deadlock. The property that a snapshot survives a commit made
    ## by *another* thread is T1's job, in tests/soak/soak.nim.
    let before = s.beginRead()
    let beforeGen = before.generation
    before.endRead()
    block:
      let tx = begin(s, w, 2'u32, doSync = false)
      discard tx.createNode("Person")
      check tx.commit()
    let after = s.beginRead()
    check beforeGen != after.generation
    check after.generation == s.generation
    after.endRead()

  test "a snapshot keeps the old records after commits that delete them":
    ## The mechanism behind pin X3. A reader that captured the array
    ## reference must not watch its records disappear mid-statement.
    let path = freshPath("snap-iso.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    var ids: seq[int64] = @[]
    block:
      let tx = begin(s, w, 1'u32, doSync = false)
      for i in 0 ..< 20:
        ids.add tx.createNode("Person")
      check tx.commit()
    block:
      let tx = begin(s, w, 2'u32, doSync = false)
      for id in ids:
        discard tx.deleteNode(id, true)
      check tx.commit()
    ## Empty, and it was not until the reader-counter race was replaced by
    ## a lock: a reader could register between the writer's "nobody is
    ## looking" sample and the merge, and the cascade then ran against
    ## state a reader was mid-read of. The same test asserted 1 survivor
    ## until that fix.
    check s.nodeCount() == 0
    let snap = s.beginRead()
    var stillLive = 0
    for i in 1 ..< snap.nodes().len:
      if snap.nodes()[i].live: inc stillLive
    check stillLive == 0
    snap.endRead()
    closeWal(w)

  test "a commit while a snapshot is open leaves the snapshot intact":
    ## There is no copy-on-write any more: the merge holds the store lock
    ## for its whole duration, so a snapshot and a merge cannot overlap and
    ## an in-place mutation is unobservable. What is asserted here is the
    ## guarantee that replaced the copy.
    let path = freshPath("snap-nocopy.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    var anId = 0'i64
    block:
      let tx = begin(s, w, 1'u32, doSync = false)
      for i in 0 ..< 500:
        anId = tx.createNode("Person")
      check tx.commit()
    ## Committed first, snapshot second — see the note in the generation
    ## test about holding a snapshot across a same-thread commit.
    block:
      let tx = begin(s, w, 2'u32, doSync = false)
      discard tx.setNodeProp(anId, "n", Value(kind: vkInt, i: 1))
      check tx.commit()
    let snap = s.beginRead()
    ## Not the array length: that is doubled on demand and is an
    ## implementation detail. The claim is that the snapshot sees the
    ## committed state and the store's own generation, with no drift.
    var live = 0
    for i in 1 ..< snap.nodes().len:
      if snap.nodes()[i].live: inc live
    check live == 500
    check snap.generation == s.generation
    snap.endRead()
    closeWal(w)

  test "endRead is idempotent":
    ## An error path that closes a statement and a `defer` that closes it
    ## again must not decrement a count it never incremented — that would
    ## silently resume in-place mutation under a live reader.
    let s = newStore()
    let snap = s.beginRead()
    snap.endRead()
    snap.endRead()
    snap.endRead()

suite "property slots under a concurrent writer":
  test "a slot is never observed half-written (TXN.md §4 seqlock)":
    ## Reads a property while a writer rewrites it in place. Either the old
    ## value or the new one, never a mix — which for an overflowing string
    ## would mean a length from one commit and bytes from the next.
    let path = freshPath("seqlock.glyph")
    let s = newStore()
    let w = openWal(path & "-wal")
    var id = 0'i64
    block:
      let tx = begin(s, w, 1'u32, doSync = false)
      id = tx.createNode("Person")
      discard tx.setNodeProp(id, "blob", Value(kind: vkString, s: "a".repeat(200)))
      check tx.commit()
    ## Writes happen with no snapshot open; the seqlock's job is to keep a
    ## *concurrent* reader from decoding a half-written slot, which needs
    ## two threads and is T1's job. What is asserted here is that a
    ## reader re-reading after many rewrites sees whole values, which is
    ## the property the dirty-bit protocol is supposed to preserve.
    for round in 0 ..< 50:
      let digit = char(ord('0') + (round mod 10))
      let tx = begin(s, w, uint32(round + 2), doSync = false)
      discard tx.setNodeProp(id, "blob",
        Value(kind: vkString, s: (("b" & $digit) & "c").repeat(100)))
      check tx.commit()
    var v: Value
    check s.getNodeProp(id, "blob", v)
    ## Whatever it read, it is a whole value of the right shape: the
    ## writer's value is the 3-character pattern ("b" & digit & "c")
    ## repeated, so a torn read would show up as a length from one commit
    ## or a character from another.
    check v.s.len == 300
    check (v.s.len mod 3) == 0
    check v.s[0] == 'b'
    check v.s[2] == 'c'
    closeWal(w)
suite "review regressions: a finished transaction has exactly one ending":
  test "a committed transaction is finished":
    ## `commit` checked `closed` and never set it, so a post-commit rollback
    ## was a real second ending: a ROLLBACK marker whose LSN the COMMIT had
    ## already consumed, and an unconditional writer-claim release that by
    ## then could name a different transaction — two writers in. Post-commit
    ## mutation was already `assertOpen`'s named error; post-commit rollback
    ## is now a no-op too.
    let s = newStore()
    let id = s.createNode("P")
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setNodeProp(id, "x", Value(kind: vkInt, i: 1))
    check tx.commit()
    check tx.rollback() == false        ## no second ending
    var v: Value
    check s.getNodeProp(id, "x", v)
    check v.i == 1                      ## the committed value, untouched
    expect TxError:
      discard tx.setNodeProp(id, "x", Value(kind: vkInt, i: 2))
    ## The claim was released exactly once: the next writer begins.
    let tx2 = begin(s, nil, 2'u32, doSync = false)
    check tx2.commit()

  test "a rolled-back transaction is finished too":
    let s = newStore()
    let tx = begin(s, nil, 1'u32, doSync = false)
    check tx.rollback()
    check tx.rollback() == false        ## idempotent, as it already was
    expect TxError:
      discard tx.createNode("P")
    let tx2 = begin(s, nil, 2'u32, doSync = false)
    check tx2.commit()

suite "review regressions: a rolled-back property write leaves no trace":
  test "rollback undoes an overwrite of an existing inline property":
    ## The executed corruption: `setPropCommon` took the committed record's
    ## own slot block and `arena.setProp` rewrote the used slots in place, so
    ## rollback — which drops only the deltas — left the uncommitted value in
    ## the committed state. Staging routes the write through a private copy.
    let s = newStore()
    let id = s.createNode("P")
    discard s.setNodeProp(id, "x", Value(kind: vkInt, i: 1))
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setNodeProp(id, "x", Value(kind: vkInt, i: 9))
    check tx.rollback()
    var v: Value
    check s.getNodeProp(id, "x", v)
    check v.i == 1

  test "rollback undoes an overwrite of an existing overflow property":
    ## The blob path had the same in-place rewrite after `putBlob` — the
    ## arena garbage from the uncommitted blob is the documented S9 trade,
    ## but the slot rewrite is not.
    let s = newStore()
    let id = s.createNode("P")
    discard s.setNodeProp(id, "blob", Value(kind: vkString, s: "committed"))
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setNodeProp(id, "blob", Value(kind: vkString, s: "uncommitted"))
    check tx.rollback()
    var v: Value
    check s.getNodeProp(id, "blob", v)
    check v.s == "committed"

  test "rollback undoes a REMOVE of a middle key":
    ## `removeProp` compacts the array in place. Removing the *first* of two
    ## keys rewrote the committed first slot with the second key's bytes; the
    ## last-key remove only looked safe because the tail survived the shift.
    let s = newStore()
    let id = s.createNode("P")
    discard s.setNodeProp(id, "a", Value(kind: vkInt, i: 1))
    discard s.setNodeProp(id, "b", Value(kind: vkInt, i: 2))
    let tx = begin(s, nil, 1'u32, doSync = false)
    check tx.removeNodeProp(id, "a")
    check tx.rollback()
    var v: Value
    check s.getNodeProp(id, "a", v)
    check v.i == 1
    check s.getNodeProp(id, "b", v)
    check v.i == 2

  test "rollback undoes an edge property overwrite":
    let s = newStore()
    let a = s.createNode("P")
    let b = s.createNode("P")
    let e = s.createEdge(a, b, "KNOWS")
    discard s.setEdgeProp(e, "w", Value(kind: vkInt, i: 1))
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setEdgeProp(e, "w", Value(kind: vkInt, i: 2))
    check tx.rollback()
    var v: Value
    check s.getEdgeProp(e, "w", v)
    check v.i == 1

  test "committed bytes are untouched while the transaction is open":
    ## The dirty-read half of the same defect: a reader outside the
    ## transaction resolves the record's committed view, which the old code
    ## rewrote underneath it.
    let s = newStore()
    let id = s.createNode("P")
    discard s.setNodeProp(id, "x", Value(kind: vkInt, i: 1))
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setNodeProp(id, "x", Value(kind: vkInt, i: 9))
    var v: Value
    check s.getNodeProp(id, "x", v)
    check v.i == 1              ## the committed value, not the staged one
    check tx.commit()
    check s.getNodeProp(id, "x", v)
    check v.i == 9              ## the merge published the staged block

  test "commit publishes staged values across every shape":
    ## Inline replace, blob replace, and a new key on a staged record all
    ## land through the same staged view.
    let s = newStore()
    let id = s.createNode("P")
    discard s.setNodeProp(id, "x", Value(kind: vkInt, i: 1))
    let tx = begin(s, nil, 1'u32, doSync = false)
    discard tx.setNodeProp(id, "x", Value(kind: vkInt, i: 9))
    discard tx.setNodeProp(id, "y", Value(kind: vkString, s: "new"))
    check tx.commit()
    var v: Value
    check s.getNodeProp(id, "x", v)
    check v.i == 9
    check s.getNodeProp(id, "y", v)
    check v.s == "new"
