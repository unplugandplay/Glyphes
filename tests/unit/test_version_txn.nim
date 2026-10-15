## glyphes — version history, V0.2: the transaction hook (gate G1e)
##
## V0 built the revision store and proved `diff` correct against an oracle.
## V0.2 makes it a *real* history: the write transaction is where revisions
## come from, so the question here is whether what the engine did to a graph
## is what the revision store recorded.
##
## The failure this guards against is the one the plan names for V0.2: a
## revision whose contents depend on *when* it was read rather than on what
## the transaction did. A hook that re-read the node at commit would produce
## exactly that, and every test here would still pass while the history was a
## plausible fiction.

import std/unittest
import std/os
import std/strutils

import ../../src/store/store
import ../../src/store/prop
import ../../src/store/revision
import ../../src/wal/wal
import ../../src/txn/txn

proc txnDir(): string =
  let d = "tmp" / "test-version-txn"
  createDir(d)
  result = d

proc freshPath(name: string): string =
  let p = txnDir() / name
  removeFile(p); removeFile(p & "-wal"); removeFile(p & ".tmp")
  result = p

suite "V0.2 recording revisions (VERSIONING-PLAN V0.2)":
  test "a committed create and set becomes one revision per node":
    let s = newStore()
    let w = openWal(freshPath("basic.glyph") & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false)
    let n = tx.createNode("Person")
    check tx.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
    check tx.setNodeProp(n, "age", Value(kind: vkInt, i: 36))
    check tx.commit()
    closeWal(w)

    let h = s.history
    check h.commits.len == 1
    let c1 = 1'u64
    ## One commit, and the node it touched is in it exactly once.
    check h.commits[0].changed == @[n]
    ## The state after the commit is the node as the transaction left it.
    let st = h.stateAt(n, c1)
    check st.live == true
    check st.props.len == 2

  test "each committed transaction is its own history commit":
    ## Two transactions, two commits, and a diff between them names only what
    ## the second changed.
    let s = newStore()
    let w = openWal(freshPath("two.glyph") & "-wal")
    var n: int64
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      n = t1.createNode("Person")
      discard t1.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
      check t1.commit()
    block:
      let t2 = begin(s, w, 2'u32, doSync = false)
      discard t2.setNodeProp(n, "name", Value(kind: vkString, s: "grace"))
      check t2.commit()
    closeWal(w)

    let h = s.history
    check h.commits.len == 2
    ## diff(1, 2) is the second transaction's effect on the node.
    let d = h.diff(1'u64, 2'u64)
    check d.len == 1
    check d[0].nodeId == n
    ## ...and the before/after are the two names, in order. This is the whole
    ## point of recording the delta rather than re-reading: the value before
    ## is what the first transaction wrote, and nothing in the hook could have
    ## known it without the history already holding it.
    check d[0].before.props.len == 1
    check d[0].after.props.len == 1
    check d[0].before.props[0][1].s == "ada"
    check d[0].after.props[0][1].s == "grace"

  test "a rolled-back transaction leaves no commit in the history":
    ## The engine's rollback is free because the base arrays were never
    ## touched. The history is outside those arrays, so it is not free, and it
    ## has to be undone explicitly — a revision written by a transaction that
    ## then failed would be a commit that never happened.
    let s = newStore()
    let w = openWal(freshPath("rb.glyph") & "-wal")
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      discard t1.createNode("Person")
      check t1.commit()
    block:
      let t2 = begin(s, w, 2'u32, doSync = false)
      discard t2.createNode("Ghost")
      discard t2.setNodeProp(1, "name", Value(kind: vkString, s: "nope"))
      check t2.rollback()
    closeWal(w)

    let h = s.history
    ## Only the first transaction is in the history.
    check h.commits.len == 1
    check h.commits[0].changed == @[1'i64]
    ## And the property the rolled-back transaction set is not visible at the
    ## only commit that exists.
    let st = h.stateAt(1, 1'u64)
    for kv in st.props:
      check kv[1].kind != vkString      # the ghost's `name` is absent

  test "a write that nets out reports no diff":
    ## Three ways a transaction can touch a node and leave it as it found it.
    ## The revision still records the node in `changed` — it was written — but
    ## a diff of the two commits is a question about the two states, and both
    ## states are equal, so it names nothing. The third is the contrast: a set
    ## followed by a *remove* is not a net no-op, it is a key that ended
    ## gone, and that one does diff.
    let s = newStore()
    let w = openWal(freshPath("net.glyph") & "-wal")
    var n: int64
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      n = t1.createNode("Person")
      discard t1.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
      discard t1.setNodeProp(n, "age", Value(kind: vkInt, i: 36))
      check t1.commit()
    block:
      ## set to the value it already holds
      let t2 = begin(s, w, 2'u32, doSync = false)
      discard t2.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
      check t2.commit()
    block:
      ## set, then set back, inside one transaction
      let t3 = begin(s, w, 3'u32, doSync = false)
      discard t3.setNodeProp(n, "age", Value(kind: vkInt, i: 99))
      discard t3.setNodeProp(n, "age", Value(kind: vkInt, i: 36))
      check t3.commit()
    block:
      ## set, then remove, inside one transaction: the key ends *gone*
      let t4 = begin(s, w, 4'u32, doSync = false)
      discard t4.setNodeProp(n, "age", Value(kind: vkInt, i: 99))
      check t4.removeNodeProp(n, "age")
      check t4.commit()
    closeWal(w)

    let h = s.history
    check h.commits.len == 4
    ## All four touched the node, so all four name it.
    for i in 0 ..< 4:
      check h.commits[i].changed == @[n]
    ## ...but only the last one left it in a different state.
    check h.diff(1'u64, 2'u64).len == 0     ## wrote the same value
    check h.diff(2'u64, 3'u64).len == 0     ## wrote it back
    check h.diff(3'u64, 4'u64).len == 1     ## ended with the key removed

  test "a delete is recorded as a revision, not an erasure":
    ## A tombstone is a revision (PRD §4.4). If liveness were not its own
    ## axis, a deleted node would fold as unchanged and a diff across the
    ## delete would be empty.
    let s = newStore()
    let w = openWal(freshPath("del.glyph") & "-wal")
    var n: int64
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      n = t1.createNode("Person")
      check t1.commit()
    block:
      let t2 = begin(s, w, 2'u32, doSync = false)
      check t2.deleteNode(n, false)
      check t2.commit()
    closeWal(w)

    let h = s.history
    check h.stateAt(n, 1'u64).live == true
    check h.stateAt(n, 2'u64).live == false
    let d = h.diff(1'u64, 2'u64)
    check d.len == 1
    check d[0].nodeId == n
    check d[0].after.live == false

  test "a property removed in a transaction reads as removed, not null":
    ## `removeNodeProp` removes a key. The revision has to say the key is
    ## gone, because a stored null and an absent property are different
    ## states — and the revision's `removed` list is how the two stay apart
    ## through the fold.
    let s = newStore()
    let w = openWal(freshPath("rm.glyph") & "-wal")
    var n: int64
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      n = t1.createNode("Person")
      discard t1.setNodeProp(n, "name", Value(kind: vkString, s: "ada"))
      discard t1.setNodeProp(n, "age", Value(kind: vkInt, i: 36))
      check t1.commit()
    block:
      let t2 = begin(s, w, 2'u32, doSync = false)
      check t2.removeNodeProp(n, "age")
      check t2.commit()
    closeWal(w)

    let h = s.history
    let st = h.stateAt(n, 2'u64)
    check st.props.len == 1
    var sawName = false
    for kv in st.props:
      if kv[1].kind == vkString: sawName = true
    check sawName                  # `name` survived
    ## and the diff across the removal is non-empty (the state changed).
    check h.diff(1'u64, 2'u64).len == 1

  test "a transaction that writes nothing creates no history commit":
    ## An empty commit would put a zero-row revision in the history, and a
    ## diff across two real commits would then span a commit that changed
    ## nothing.
    let s = newStore()
    let w = openWal(freshPath("empty.glyph") & "-wal")
    block:
      let t1 = begin(s, w, 1'u32, doSync = false)
      discard t1.createNode("Person")
      check t1.commit()
    block:
      let t2 = begin(s, w, 2'u32, doSync = false)
      check t2.commit()             # touches nothing
    closeWal(w)
    check s.history.commits.len == 1

  test "many nodes in one transaction record one commit naming them all":
    ## The bulk path: a load is one transaction touching N nodes. This is the
    ## case that made `changed` quadratic when it was deduplicated with a
    ## linear scan, so it is worth a size that would have shown it.
    let s = newStore()
    let w = openWal(freshPath("bulk.glyph") & "-wal")
    let tx = begin(s, w, 1'u32, doSync = false)
    var ids: seq[int64] = @[]
    for i in 0 ..< 2000:
      let n = tx.createNode("Doc")
      discard tx.setNodeProp(n, "i", Value(kind: vkInt, i: int64(i)))
      ids.add n
    check tx.commit()
    closeWal(w)

    let h = s.history
    check h.commits.len == 1
    check h.commits[0].changed.len == 2000
    ## And every one of them folds to the value it was given.
    for i in 0 ..< 2000:
      let st = h.stateAt(ids[i], 1'u64)
      check st.live == true