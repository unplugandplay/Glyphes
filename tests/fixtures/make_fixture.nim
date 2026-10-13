## Builds `tests/fixtures/social.glyph` deterministically for the Ruby M4
## e2e suite. The Ruby side has no mutation surface yet (ABI.md pin B6:
## Cypher-only, and write Cypher is M5), so graph data crosses the seam as
## a file produced here, where the Nim write path is real: one write
## transaction through `txn.nim`, committed, closed, leaving the WAL for
## the reader's recovery to replay — the exact open path a host takes.
##
## Re-run any time; the previous file and log are removed first. No RNG:
## the e2e assertions need row sets that are stable byte for byte.

import std/os
import ../../src/abi
import ../../src/database
import ../../src/txn/txn
import ../../src/store/prop

let dir = currentSourcePath.parentDir
let path = dir / "social.glyph"
for suffix in ["", "-wal"]:
  let f = path & suffix
  if fileExists(f):
    removeFile(f)

let db = openDatabase(path, GLY_OPEN_CREATE)
var tx = db.beginTransaction()

proc person(tx: WriteTransaction, name: string, age: int64, home: string): int64 =
  let id = tx.createNode("Person")
  doAssert tx.setNodeProp(id, "name", Value(kind: vkString, s: name))
  doAssert tx.setNodeProp(id, "age", Value(kind: vkInt, i: age))
  if home != "":
    doAssert tx.setNodeProp(id, "home", Value(kind: vkString, s: home))
  id

proc knows(tx: WriteTransaction, a, b: int64, since: int64): int64 =
  let e = tx.createEdge(a, b, "KNOWS")
  doAssert e != 0
  doAssert tx.setEdgeProp(e, "since", Value(kind: vkInt, i: since))
  e

let alice = tx.person("Alice", 30, "Lisbon")
let bob   = tx.person("Bob",   25, "Porto")
let carol = tx.person("Carol", 35, "Lisbon")
let dave  = tx.person("Dave",  25, "Braga")
let eve   = tx.person("Eve",   28, "")
## Frank carries the missing property: one row where `n.age` is null, so
## the e2e can pin the three-valued behaviour at the seam, not just in
## Nim tests.
let frank = tx.person("Frank", 0, "Faro")
doAssert tx.setNodeProp(frank, "age", Value(kind: vkNull))

discard tx.knows(alice, bob, 2020)
discard tx.knows(alice, carol, 2018)
discard tx.knows(bob, dave, 2021)
discard tx.knows(carol, dave, 2019)
discard tx.knows(dave, eve, 2018)

let acme = tx.createNode("Company")
doAssert tx.setNodeProp(acme, "name", Value(kind: vkString, s: "Acme"))
doAssert tx.setNodeProp(acme, "founded", Value(kind: vkInt, i: 2010))
doAssert tx.createEdge(bob, acme, "WORKS_AT") != 0
doAssert tx.createEdge(carol, acme, "WORKS_AT") != 0

doAssert tx.commit()
db.close()
echo "wrote " & path