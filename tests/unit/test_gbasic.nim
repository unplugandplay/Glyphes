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
import ../../src/gbasic_types
import ../../src/gbasic_expr
import ../../src/gbasic_store
import ../../src/gbasic_channel

import ../../src/database
import ../../src/abi
import ../../src/store/prop
import ../../src/store/store
import ../../src/txn/txn
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
  ## The fixture is built through the *transaction*, not through the
  ## store, for three reasons. The ids are then known exactly (a
  ## transcript is only checkable if the fixture is fixed); the edge
  ## between two *existing* nodes is something the engine's query
  ## language cannot express — a comma-`MATCH` is a cartesian product
  ## and is refused, a second `MATCH` is a join and is refused, and a
  ## `MERGE` creates the whole pattern, including a second copy of the
  ## far end (that gap is what the link door exists for,
  ## PRD-GLYPH-QUERY.md §5); and the writes reach the log, so the
  ## fixture is as durable as the client's own writes. A fixture built
  ## through the store is a fixture that a reopen empties — which hides
  ## exactly the bug the durability test is there to catch.
  let ana = tx.createNode("Person")
  let bo = tx.createNode("Person")
  let acme = tx.createNode("Company")
  discard tx.setNodeProp(ana, "name", Value(kind: vkString, s: "Ana"))
  discard tx.setNodeProp(ana, "age", Value(kind: vkInt, i: 34))
  discard tx.setNodeProp(bo, "name", Value(kind: vkString, s: "Bo"))
  discard tx.setNodeProp(bo, "age", Value(kind: vkInt, i: 41))
  discard tx.setNodeProp(acme, "name", Value(kind: vkString, s: "Acme"))
  discard tx.createEdge(ana, bo, "KNOWS")
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

suite "GLYPH BASIC — the control flow":

  test "a conditional runs the statement that follows it":
    ## The conditional the query language refuses to have: the engine
    ## has no CASE and no EXISTS, so a client that wants a choice makes
    ## it here.
    let db = freshDb()
    let text = run(db, ["let x = 1",
                        "if x = 1 then print \"yes\"",
                        "if x = 2 then print \"no\"",
                        "if x = 1 then print \"a\" : print \"b\""])
    check text == "yes\na\nb\n"
    close(db)

  test "a condition that is null is false":
    ## Null is not truthy, in the client's language as in the engine's
    ## (C6): a language that treats null as false teaches the wrong
    ## thing quietly.
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    s.names["n"] = GbValue(kind: gbvNull)
    check not condition(s.names, "n")
    close(db)

  test "a loop counts, and the variable it leaves behind is the last one":
    let db = freshDb()
    let text = run(db, ["let t = 0",
                        "for i = 1 to 5 : t = t + i : next",
                        "print t",
                        "print i"])
    check text == "15\n5\n"
    close(db)

  test "a loop that counts down works too":
    let db = freshDb()
    let text = run(db, ["for i = 5 to 1 step -1 : print i : next"])
    check text == "5\n4\n3\n2\n1\n"
    close(db)

  test "a loop that cannot finish says so instead of hanging":
    ## The client is a prompt, and a prompt that hangs is a prompt that
    ## is broken.
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runStatement(t, "for i = 1 to 10000000 : print i : next")
    except CatchableError as e:
      msg = e.msg
    check "did not finish" in msg
    close(db)

  test "input reads a line into a name":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    s.inputFn = proc(): string = "42"
    discard s.runStatement(t, "input n")
    check s.names.hasKey("n")
    ## A line that reads as a whole number is a number: `input n` then
    ## `if n > 5` must not compare text.
    check s.names["n"].kind == gbvNumber
    check s.names["n"].number == 42
    close(db)

  test "input reads anything else as text":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    s.inputFn = proc(): string = "Ada"
    discard s.runStatement(t, "input who")
    check s.names["who"].kind == gbvString
    check s.names["who"].text == "Ada"
    close(db)

  test "the statements after a next run once, after the loop":
    let db = freshDb()
    let text = run(db, ["let t = 0",
                        "for i = 1 to 3 : t = t + i : next : print \"done\"",
                        "print t"])
    check text == "done\n6\n"
    close(db)

  test "a link survives a reopen, because it went through the log":
    ## The door's writes have to reach the log. A write that a restart
    ## forgets is a lie, and the store's own `createEdge` is such a
    ## write: it is in memory and nowhere else. The transaction's
    ## `createEdge` is the one that is in the log.
    inc dbCounter
    let path = getTempDir() / "glyphes-gbasic-link-" & $getCurrentProcessId() &
              "-" & $dbCounter & ".glyph"
    removeFile(path)
    removeFile(path & "-wal")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    let tx = db.beginTransaction()
    ## The *transaction's* createNode, not the store's: a node that never
    ## reached the log is a node a restart forgets, and then the link
    ## would point at nothing. Both ends of a link must be as durable as
    ## the link.
    let ana = tx.createNode("Person")
    let bo = tx.createNode("Person")
    discard db.commitTransaction(tx)
    let t = newStoreTransport(db)
    var s = newSession()
    discard s.runStatement(t, "p = " & $ana)
    discard s.runStatement(t, "q = " & $bo)
    discard s.runStatement(t, "link p KNOWS q")
    close(db)

    let db2 = openDatabase(path, 0)
    let t2 = newStoreTransport(db2)
    var s2 = newSession()
    discard s2.runStatement(t2, "p = " & $ana)
    ## The edge is there: the follow finds the far end.
    discard s2.runStatement(t2, "go KNOWS from p")
    check s2.cursor.len == 1
    check s2.cursor[0] == bo
    close(db2)

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


suite "GLYPH BASIC — the guest channel":

  test "a GLYPH QUERY line comes back as the ids it matched":
    ## The host's end of the channel: the guest sends the line, and the
    ## answer is the ids — the same rows the host client would have got.
    let db = freshDb()
    check channelAnswer(db, "gq find Person") == "1,2"
    close(db)

  test "the labels come back one per line":
    let db = freshDb()
    check channelAnswer(db, "gq labels") == "Person\rCompany"
    close(db)

  test "a node's properties and edges come back as text":
    ## The shape the guest's `show` prints: the label and the
    ## properties, one per line, the value after the first space.
    let db = freshDb()
    let props = channelAnswer(db, "props 1")
    check "label Person" in props
    check "name Ana" in props
    check "age 34" in props
    let edges = channelAnswer(db, "edges 1")
    check "KNOWS > 2" in edges
    close(db)

  test "a link comes back as the new edge's id":
    let db = freshDb()
    let answer = channelAnswer(db, "link 1 KNOWS 3")
    check parseInt(answer) > 0
    close(db)

  test "a refusal comes back as a refusal, and says why":
    ## The guest's whole job is to show what it was told: a refusal it
    ## cannot see is a refusal the child never learns about.
    let db = freshDb()
    let answer = channelAnswer(db, "gq find nosuchlabel")
    check answer == ""
    let bad = channelAnswer(db, "gq nosuchcommand")
    check bad.startsWith("!")
    check "nosuchcommand" in bad
    close(db)

  test "a value travels as a parameter, never as text":
    ## The channel is a door like any other: the guest's values are
    ## parameters, so the compiled text is the same whatever they are.
    let db = freshDb()
    let answer = channelAnswer(db, "gq find Person where name = $who\twho=\"Ana\"")
    check answer == "1"
    close(db)


suite "GLYPH BASIC — the program":

  test "a program runs its body and calls its subroutines":
    ## The program's shape: a name, a body, named subroutines, and an
    ## end. No line numbers anywhere, and no `goto` — a subroutine is
    ## called by its name and comes back by its `return`.
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    discard s.runProgram(t, [
      "PROGRAM-ID. demo.",
      "find Person",
      "gosub AFFICHER_TOTAL",
      "SUBROUTINE. AFFICHER_TOTAL.",
      "print \"in the subroutine\"",
      "return",
      "END PROGRAM."
    ])
    check s.transcript == "2 nodes\nin the subroutine\n"
    close(db)

  test "a subroutine is called by its name, dot or no dot":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    discard s.runProgram(t, [
      "PROGRAM-ID. demo.",
      "gosub SALUER",
      "SUBROUTINE. SALUER.",
      "print \"called\"",
      "return",
      "END PROGRAM."
    ])
    check s.transcript == "called\n"
    close(db)

  test "a subroutine that ends without a return is refused by name":
    ## Falling off the end is the trap COBOL's paragraphs have, and a
    ## child's language should not inherit it.
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runProgram(t, [
        "PROGRAM-ID. demo.",
        "gosub SANS_RETOUR",
        "SUBROUTINE. SANS_RETOUR.",
        "print \"no return\"",
        "END PROGRAM."
      ])
    except CatchableError as e:
      msg = e.msg
    check "RETURN" in msg
    close(db)

  test "gosub outside a program is refused":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runStatement(t, "gosub SOMEONE")
    except CatchableError as e:
      msg = e.msg
    check "no program" in msg
    close(db)

  test "a name that is not a subroutine is refused":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runProgram(t, [
        "PROGRAM-ID. demo.",
        "gosub NOWHERE",
        "END PROGRAM."
      ])
    except CatchableError as e:
      msg = e.msg
    check "NOWHERE" in msg
    close(db)

  test "while loops until its condition is false":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    discard s.runProgram(t, [
      "PROGRAM-ID. demo.",
      "let n = 0",
      "while n < 3 : print n : n = n + 1 : next",
      "END PROGRAM."
    ])
    check s.transcript == "0\n1\n2\n"
    close(db)

  test "a program that does not start with PROGRAM-ID is refused":
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    var msg = ""
    try:
      discard s.runProgram(t, ["find Person"])
    except CatchableError as e:
      msg = e.msg
    check "PROGRAM-ID" in msg
    close(db)


suite "GLYPH BASIC — the values":

  test "two strings concatenate, and a string and a number are refused":
    ## The mixed case used to read the wrong union member and answer
    ## with garbage; a language that refuses is better than one that
    ## guesses.
    let db = freshDb()
    let t = newStoreTransport(db)
    var s = newSession()
    discard s.runStatement(t, "let a = \"Ada\"")
    discard s.runStatement(t, "let b = \" Lovelace\"")
    check s.names["a"].text == "Ada"
    check s.names["b"].text == " Lovelace"
    var msg = ""
    try:
      discard s.runStatement(t, "let c = a + 1")
    except CatchableError as e:
      msg = e.msg
    check "two strings or two numbers" in msg
    ## Two strings do concatenate.
    discard s.runStatement(t, "let d = a + b")
    check s.names["d"].text == "Ada Lovelace"
    close(db)
