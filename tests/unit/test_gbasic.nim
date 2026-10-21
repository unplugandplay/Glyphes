## glyphes — GLYPH BASIC: the client language.
##
## The client is a *client* (PRD-GLYPH-BASIC.md): it reaches the graph
## only through a door, and the door is what the tests check. So the
## tests are:
##
## - **the transcript**, golden, byte for byte. A language's output is a
##   transcript, not a test count — the same discipline the eZ80's BASIC
##   transcript uses, and for the same reason: a transcript says what the
##   language *does*, and a count says only that something did.
## - **the door**, not the store: the client cannot reach the store, so a
##   client bug cannot corrupt a graph.
## - **the refusals**, which name the statement that caused them.
## - **the values**, which never reach the query text.

import std/[unittest, strutils, os, tables]
import ../../src/gbasic
import ../../src/gbasic_store
import ../../src/database
import ../../src/abi
import ../../src/store/prop
import ../../src/store/store
import ../../src/cypher/execute

var dbCounter = 0

proc freshDb(): Database =
  ## A database with three people and one edge. The path is unique per
  ## call: a database holds a writer lock, and two live handles on one
  ## path is a refusal the test would rather not explain.
  inc dbCounter
  let path = getTempDir() / "glyphes-gbasic-" & $getCurrentProcessId() &
            "-" & $dbCounter & ".glyph"
  removeFile(path)
  removeFile(path & "-wal")
  let db = openDatabase(path, GLY_OPEN_CREATE)
  let tx = db.beginTransaction()
  ## The fixture is built through the store, not through Cypher, for two
  ## reasons: the ids are then known exactly (a transcript is only
  ## checkable if the fixture is fixed), and the edge between two
  ## *existing* nodes is something the engine's query language cannot
  ## express — a comma-`MATCH` is a cartesian product and is refused, a
  ## second `MATCH` is a join and is refused, and a `MERGE` creates the
  ## whole pattern, including a second copy of the far end. That gap is
  ## what the link door exists for (PRD-GLYPH-QUERY.md §5).
  let ana = db.store.createNode("Person")
  let bo = db.store.createNode("Person")
  let acme = db.store.createNode("Company")
  discard db.store.setNodeProp(ana, "name", Value(kind: vkString, s: "Ana"))
  discard db.store.setNodeProp(ana, "age", Value(kind: vkInt, i: 34))
  discard db.store.setNodeProp(bo, "name", Value(kind: vkString, s: "Bo"))
  discard db.store.setNodeProp(bo, "age", Value(kind: vkInt, i: 41))
  discard db.store.setNodeProp(acme, "name", Value(kind: vkString, s: "Acme"))
  discard db.store.createEdge(ana, bo, "KNOWS")
  discard db.commitTransaction(tx)
  result = db

proc run(db: Database, lines: openArray[string]): string =
  ## Run a script, and give back the transcript.
  let t = newStoreTransport(db)
  var s = newSession()
  for line in lines:
    discard s.runStatement(t, line)
  result = s.transcript

suite "GLYPH BASIC — the transcript":

  test "a session finds, shows and chases":
    let db = freshDb()
    let text = run(db, ["find Person",
                        "p = 1",
                        "show p",
                        "go KNOWS"])
    check text == """
2 nodes
1 :Person
  name Ana
  age 34
  KNOWS -> 2
1 nodes
"""
    close(db)

  test "the cursor is replaced, not appended to":
    let db = freshDb()
    let text = run(db, ["find Person", "find Company"])
    check text == "2 nodes\n1 nodes\n"
    close(db)

  test "a name holds a node, and the chase follows it":
    let db = freshDb()
    let text = run(db, ["find Person", "p = 1", "go KNOWS from p"])
    check text == "2 nodes\n1 nodes\n"
    close(db)

  test "a name that matches nothing says what there is":
    ## The store's labels and types are exact, so `find person` finds
    ## nobody while `Person` is right there. The engine's rule is that an
    ## unknown label is an empty result and never an error (pin C2), which
    ## is right for a query and wrong for a prompt: silence reads as
    ## "there is nobody here", which is a different fact from "there is
    ## nobody *called* person". The client knows the labels, so it says
    ## which ones there are.
    let db = freshDb()
    let text = run(db, ["find person"])
    check text == "no label 'person'; the labels are: Person, Company\n"
    let text2 = run(db, ["go knows"])
    check text2 == "no relationship type 'knows'; the types are: KNOWS\n"
    close(db)

suite "GLYPH BASIC — the refusals":

  test "an unknown statement names itself":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runStatement(t, "frobnicate person")
    except GbError as e:
      msg = e.msg
    check "unknown statement 'frobnicate'" in msg
    close(db)

  test "a name that is not there is refused by name":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runStatement(t, "show nobody")
    except GbError as e:
      msg = e.msg
    check "no such name 'nobody'" in msg
    close(db)

suite "GLYPH BASIC — the values":

  test "a client's value reaches the engine as a parameter":
    ## The client's values are the client's business, and the engine sees
    ## a parameter: the value never reaches the query text (pin GB1).
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    s.names["who"] = GbValue(kind: gbvString, text: "Ana")
    ## The client's own variable, written with the `$` sigil, becomes a
    ## parameter: the value travels beside the query, never inside it.
    discard s.runStatement(t, "find Person where name = $who")
    check s.cursor.len == 1
    close(db)
