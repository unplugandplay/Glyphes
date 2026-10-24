## glyphes — what the link door costs, with and without properties.
##
## The ABI's `glyphes_link_props` comment quotes a rate. A rate in a
## comment is a claim; this is the program that makes it, so the claim
## can be re-run on another machine instead of believed.
##
## Three paths, each in its own fresh database, each inside one
## transaction unless the label says autocommit:
##
##   link             glyphes_link, N edges
##   link_props       glyphes_link_props, N edges, two properties each
##   link + SET       glyphes_link, then one Cypher MATCH/SET per edge
##                    (the path a bulk loader reaches for when the door
##                    does not carry properties)
##   link + SET (ac)  the same Cypher update, but each statement in its
##                    own transaction — what `db.exec` does outside a
##                    transaction block
##
## The Cypher SET is addressed by `id(r)`, which CYPHER.md gives as a
## node-or-relationship function.

import std/[os, strformat, strutils, times]
import ../../src/abi
import ../../src/errors
import ../../src/glyphes

const
  NBulk = 100_000
  NPerEdge = 2_000

proc checkOk(status: int32, what: string) =
  if status != 0:
    quit(what & ": status " & $status & ": " & globalErrorMsg(), QuitFailure)

proc makeDb(name: string): GlyHandle =
  let path = "tmp" / ("bench-link-" & name & ".glyph")
  removeFile(path)
  removeFile(path & "-wal")
  checkOk(glyphes_open(path.cstring, int32(GLY_OPEN_CREATE), addr result), "open " & name)

proc twoNodes(db: GlyHandle): (int64, int64) =
  var n: int64 = 0
  var a: int64 = 0
  var b: int64 = 0
  checkOk(glyphes_exec_returning(db,
    "CREATE (n:bulk) RETURN id(n) AS id".cstring, nil, addr n, addr a),
    "create a")
  checkOk(glyphes_exec_returning(db,
    "CREATE (n:bulk) RETURN id(n) AS id".cstring, nil, addr n, addr b),
    "create b")
  (a, b)

proc report(label: string, n: int, body: proc()) =
  let t0 = cpuTime()
  body()
  let elapsed = cpuTime() - t0
  echo &"{label:<18} {n:>7} edges  {elapsed:>8.3f} s  " &
       &"{float(n) / elapsed:>12.0f} edges/s"

proc main() =
  block link:
    let db = makeDb("link")
    let (a, b) = twoNodes(db)
    var tx: GlyHandle
    checkOk(glyphes_tx_begin(db, addr tx), "tx begin")
    report("link", NBulk):
      for i in 0 ..< NBulk:
        var eid: int64 = 0
        checkOk(glyphes_link(db, a, "SIMILAR_TO".cstring, b, addr eid), "link")
    checkOk(glyphes_tx_commit(db, tx), "tx commit")
    checkOk(glyphes_close(db), "close")

  block linkProps:
    let db = makeDb("link-props")
    let (a, b) = twoNodes(db)
    var tx: GlyHandle
    checkOk(glyphes_tx_begin(db, addr tx), "tx begin")
    report("link_props", NBulk):
      for i in 0 ..< NBulk:
        var eid: int64 = 0
        checkOk(glyphes_link_props(db, a, "SIMILAR_TO".cstring, b,
          "{\"weight\": 0.5, \"evidence\": \"bench\"}".cstring, addr eid),
          "link_props")
    checkOk(glyphes_tx_commit(db, tx), "tx commit")
    checkOk(glyphes_close(db), "close")

  block linkThenSet:
    let db = makeDb("link-set")
    let (a, b) = twoNodes(db)
    var tx: GlyHandle
    checkOk(glyphes_tx_begin(db, addr tx), "tx begin")
    report("link + SET", NPerEdge):
      for i in 0 ..< NPerEdge:
        var eid: int64 = 0
        checkOk(glyphes_link(db, a, "SIMILAR_TO".cstring, b, addr eid), "link")
        var n: int64 = 0
        checkOk(glyphes_exec(db,
          "MATCH ()-[r:SIMILAR_TO]->() WHERE id(r) = $eid SET r.weight = $w".cstring,
          (&"{{\"eid\": {eid}, \"w\": 0.5}}").cstring, addr n), "set")
    checkOk(glyphes_tx_commit(db, tx), "tx commit")
    checkOk(glyphes_close(db), "close")

  block linkThenSetAutocommit:
    let db = makeDb("link-set-auto")
    let (a, b) = twoNodes(db)
    report("link + SET (ac)", NPerEdge):
      for i in 0 ..< NPerEdge:
        var eid: int64 = 0
        checkOk(glyphes_link(db, a, "SIMILAR_TO".cstring, b, addr eid), "link")
        var n: int64 = 0
        checkOk(glyphes_exec(db,
          "MATCH ()-[r:SIMILAR_TO]->() WHERE id(r) = $eid SET r.weight = $w".cstring,
          (&"{{\"eid\": {eid}, \"w\": 0.5}}").cstring, addr n), "set")
    checkOk(glyphes_close(db), "close")

main()
