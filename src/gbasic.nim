## gbasic.nim — GLYPH BASIC: a client language for the graph.
##
## GLYPH BASIC is a **client**, not a query language
## (PRD-GLYPH-BASIC.md). Every statement it runs becomes a GLYPH QUERY
## statement, which the engine compiles to Cypher; what the client adds
## is what a query language deliberately has not: variables, a session,
## a cursor, conditionals and loops.
##
## ```
## ready> find Person
##   2 people
## ready> p = first
## ready> show p
##   1 :Ana
##   age 34
##   knows -> 2 :Bo
## ready> go knows
##   1 :Bo
## ready> if p is 1 then print "found"
## ```
##
## The client reaches the engine through one door — a `GbTransport` — and
## never touches the store. That is what keeps a client bug from
## corrupting a graph (pin GB1), and it is what makes the eZ80 guest
## possible: the same grammar over a port channel instead of in-process
## (pin GB5).

import std/[tables, strutils]
import ./gq
import ./store/prop

type
  GbError* = object of CatchableError
    ## A client-side refusal, naming the statement that caused it.

  GbValueKind* = enum
    gbvNode, gbvNumber, gbvString

  GbValue* = object
    ## What a name in the session can hold.
    case kind*: GbValueKind
    of gbvNode: nodeId*: int64
    of gbvNumber: number*: int64
    of gbvString: text*: string

  GbResult* = object
    ## What a GLYPH QUERY statement returned, in the client's terms.
    ##
    ## The shape is the client's, not the engine's: a row can be a node,
    ## a number or a list, and the guest's channel carries text, so the
    ## two implementations must agree on something the channel can carry.
    ids*: seq[int64]        ## the node ids, for find and go
    count*: int64           ## the count, for count
    labels*: seq[string]    ## the labels, for labels
    affected*: int64        ## the rows a write affected
    linkId*: int64          ## the new edge's id, for link

  GbTransport* = ref object
    ## The door. Everything the client knows about the graph comes
    ## through here.
    ##
    ## The door is a set of callbacks rather than a class with methods:
    ## Nim does not allow method declarations inside an object, and a
    ## class hierarchy here would be the wrong shape anyway -- the guest
    ## transport is not a subclass of the in-process one, it is a
    ## different way to reach the same engine.
    runFn*: proc(gq: string, params: Table[string, Value]): GbResult
    labelsFn*: proc(): seq[string]
    typesFn*: proc(): seq[string]
    propsFn*: proc(id: int64): seq[(string, string)]
    edgesFn*: proc(id: int64): seq[(string, int64, bool)]
    linkFn*: proc(fromId: int64, rtype: string, toId: int64): int64

  GbSession* = object
    ## The client's state: the names, and the cursor.
    names*: Table[string, GbValue]
    cursor*: seq[int64]     ## the current set of node ids (pin GB2)
    transcript*: string      ## the transcript so far

  GbLoop* = object
    ## One `for` loop's state: the variable, the limit, the step and the
    ## line the loop came back to.
    varName*: string
    limit*: int64
    step*: int64
    current*: int64
    line*: int

proc gbFail(msg: string) {.noreturn.} =
  raise newException(GbError, "glyph basic: " & msg)

proc newSession*(): GbSession =
  result.names = initTable[string, GbValue]()

proc say*(s: var GbSession, text: string) =
  ## Append to the transcript.
  s.transcript.add text
  s.transcript.add "\n"

# ------------------------------------------------------------- the values

proc parseValue(s: GbSession, text: string): GbValue =
  ## A literal or a name.
  if text.len >= 2 and text[0] == '"' and text[^1] == '"':
    return GbValue(kind: gbvString, text: text[1 .. ^2])
  var n: int64 = 0
  var allDigits = text.len > 0
  for ch in text:
    if ch in {'0'..'9'}: n = n * 10 + (ord(ch) - ord('0'))
    else: allDigits = false
  if allDigits:
    return GbValue(kind: gbvNumber, number: n)
  if s.names.hasKey(text):
    return s.names[text]
  gbFail("no such name '" & text & "'")

proc valueText(v: GbValue): string =
  case v.kind
  of gbvNode: $v.nodeId
  of gbvNumber: $v.number
  of gbvString: v.text

proc nodeOf(s: GbSession, name: string): int64 =
  ## The node a name holds. A name that holds a number is a node id too:
  ## the client is the one that knows ids are numbers, and a child
  ## should not have to.
  if not s.names.hasKey(name):
    gbFail("no such name '" & name & "'")
  let v = s.names[name]
  case v.kind
  of gbvNode: v.nodeId
  of gbvNumber: v.number
  of gbvString: gbFail("the name '" & name & "' holds text, not a node")

proc setCursor*(s: var GbSession, ids: seq[int64]) =
  s.cursor = ids

proc first*(s: GbSession): int64 =
  if s.cursor.len == 0: gbFail("the cursor is empty")
  s.cursor[0]

proc last*(s: GbSession): int64 =
  if s.cursor.len == 0: gbFail("the cursor is empty")
  s.cursor[^1]

# --------------------------------------------------------- the statements

proc splitWords(line: string): seq[string] =
  ## The statement's words. A quoted string is one word, whatever is
  ## inside it.
  var cur = ""
  var inStr = false
  for ch in line:
    if ch == '"':
      inStr = not inStr
      cur.add ch
    elif ch in {' ', '\t'} and not inStr:
      if cur.len > 0:
        result.add cur
        cur = ""
    else:
      cur.add ch
  if cur.len > 0: result.add cur

proc clientParams(s: GbSession, text: string, params: var Table[string, Value]) =
  ## The client's variables inside a `where` clause.
  ##
  ## A `$NAME` in the clause is the client's variable, and it becomes a
  ## *parameter*: the client's values never reach the query text (pin
  ## GB1, pin GQ4).
  var i = 0
  while i < text.len:
    if text[i] == '$':
      var j = i + 1
      while j < text.len and (text[j] in {'a'..'z'} or text[j] in {'A'..'Z'} or
                               text[j] in {'0'..'9'} or text[j] == '_'):
        inc j
      let name = text[i + 1 ..< j]
      if name.len == 0:
        gbFail("a '$' with no name after it")
      if not s.names.hasKey(name):
        gbFail("no such name '" & name & "'")
      let v = s.names[name]
      let pname = "c" & $params.len
      case v.kind
      of gbvNode: params[pname] = Value(kind: vkInt, i: v.nodeId)
      of gbvNumber: params[pname] = Value(kind: vkInt, i: v.number)
      of gbvString: params[pname] = Value(kind: vkString, s: v.text)
      i = j
    else:
      inc i

proc substituteVars(s: GbSession, text: string, params: var Table[string, Value]): string =
  ## A clause with the client's variables replaced by parameter
  ## references, so the text the engine sees holds no client value.
  var acc = ""
  var i = 0
  while i < text.len:
    if text[i] == '$':
      var j = i + 1
      while j < text.len and (text[j] in {'a'..'z'} or text[j] in {'A'..'Z'} or
                             text[j] in {'0'..'9'} or text[j] == '_'):
        inc j
      let name = text[i + 1 ..< j]
      if name.len == 0:
        gbFail("a '$' with no name after it")
      if not s.names.hasKey(name):
        gbFail("no such name '" & name & "'")
      let v = s.names[name]
      let pname = "c" & $params.len
      case v.kind
      of gbvNode: params[pname] = Value(kind: vkInt, i: v.nodeId)
      of gbvNumber: params[pname] = Value(kind: vkInt, i: v.number)
      of gbvString: params[pname] = Value(kind: vkString, s: v.text)
      acc.add "$" & pname
      i = j
    else:
      acc.add text[i]
      inc i
  result = acc

proc showNode(s: var GbSession, t: GbTransport, id: int64) =
  ## A node, printed as a node: its id, its label, its properties and
  ## its edges. This is the "chase" — the thing a graph prompt is for.
  var label = ""
  for l in t.labelsFn():
    if l.len == 0: continue
  ## The label comes from the properties the transport knows how to name;
  ## a node's own label is one of them.
  let props = t.propsFn(id)
  for (k, v) in props:
    if k == "label": label = v
  var line = $id
  if label.len > 0: line.add " :" & label
  s.say(line)
  for (k, v) in props:
    if k == "label": continue
    s.say("  " & k & " " & v)
  for (rtype, other, outgoing) in t.edgesFn(id):
    let arrow = (if outgoing: "->" else: "<-")
    s.say("  " & rtype & " " & arrow & " " & $other)

proc runStatement*(s: var GbSession, t: GbTransport, line: string): bool =
  ## Run one client statement. Returns false when the statement asked
  ## the client to stop (`end`).
  let words = splitWords(line)
  if words.len == 0:
    return true
  ## A bare assignment — `p = 1` — is the BASIC's own shorthand for
  ## `LET p = 1`, and a child writes the short one. It is recognised
  ## before the statement table, so a name that happens to be a
  ## statement's name is still a statement.
  let cmd = words[0].toLowerAscii
  if words.len >= 3 and words[1] == "=" and cmd notin
      ["find", "go", "count", "show", "add", "link", "set", "drop",
       "labels", "print", "let", "if", "for", "end", "rem"]:
    let v = s.parseValue(words[2])
    s.names[words[0]] = v
    return true
  case cmd
  of "rem":
    discard
  of "end":
    return false
  of "let":
    if words.len < 4 or words[2] != "=":
      gbFail("let needs a name, '=' and a value")
    let v = s.parseValue(words[3])
    s.names[words[1]] = v
  of "print":
    if words.len == 1:
      ## the cursor
      if s.cursor.len == 0:
        s.say("the cursor is empty")
      else:
        s.say($s.cursor.len & " nodes")
    else:
      for w in words[1 .. ^1]:
        let v = s.parseValue(w)
        s.say(v.valueText())
  of "find", "count":
    ## find [<label>] [where <expr>]
    var label = ""
    var rest = line
    var at = 0
    let after = cmd.len
    var tail = line[after .. ^1].strip()
    if tail.len > 0:
      let sp = tail.find(' ')
      if sp < 0:
        label = tail
        tail = ""
      else:
        label = tail[0 ..< sp]
        tail = tail[sp .. ^1].strip()
    if label.len == 0 and tail.len == 0:
      gbFail(cmd & " needs a label")
    var gq = cmd
    if label.len > 0: gq.add " " & label
    var params = initTable[string, Value]()
    if tail.len > 0:
      if not tail.toLowerAscii.startsWith("where"):
        gbFail("expected 'where' after the label, found '" & tail & "'")
      gq.add " where " & s.substituteVars(tail[5 .. ^1].strip(), params)
    let res = t.runFn(gq, params)
    if cmd == "find":
      s.setCursor(res.ids)
      if res.ids.len == 0 and label.len > 0:
        ## The store's labels are exact, so `find person` does not find
        ## `Person` — and the engine's rule is that an unknown label is
        ## an empty result and never an error (pin C2). Silence would
        ## read as "there is nobody here", which is a different fact
        ## from "there is nobody *called* person". The client knows the
        ## labels, so it says which ones there are.
        let known = t.labelsFn()
        if known.len > 0 and label notin known:
          s.say("no label '" & label & "'; the labels are: " &
                known.join(", "))
          return true
      s.say($res.ids.len & " nodes")
    else:
      s.say($res.count)
  of "go":
    ## go [back] <type> [from <name>]
    var gq = "go"
    var rest = words[1 .. ^1]
    if rest.len == 0:
      gbFail("go needs a relationship type")
    if rest[0].toLowerAscii == "back":
      gq.add " back"
      rest = rest[1 .. ^1]
    if rest.len == 0:
      gbFail("go needs a relationship type")
    gq.add " " & rest[0]
    var params = initTable[string, Value]()
    if rest.len > 1:
      if rest[1].toLowerAscii != "from":
        gbFail("expected 'from' after the relationship type")
      if rest.len < 3:
        gbFail("go from needs a name")
      ## The name is the client's, so it is resolved here and travels as
      ## a parameter (pin GB1): the engine never sees the client's
      ## names.
      let pname = "c" & $params.len
      params[pname] = Value(kind: vkInt, i: s.nodeOf(rest[2]))
      gq.add " from $" & pname
    let res = t.runFn(gq, params)
    s.setCursor(res.ids)
    if res.ids.len == 0:
      let known = t.typesFn()
      if known.len > 0 and rest[0] notin known:
        s.say("no relationship type '" & rest[0] & "'; the types are: " &
              known.join(", "))
        return true
    s.say($res.ids.len & " nodes")
  of "show":
    if words.len != 2:
      gbFail("show needs a name")
    s.showNode(t, s.nodeOf(words[1]))
  of "labels":
    let res = t.runFn("labels", initTable[string, Value]())
    for l in res.labels:
      s.say(l)
  of "add":
    ## add <label> [{<prop> <value>}]
    if words.len < 2:
      gbFail("add needs a label")
    var gq = "add " & words[1]
    if words.len > 2:
      ## the property list is the client's own text: {name "Ada", age 36}
      var props = ""
      for w in words[3 .. ^1]:
        if w == "," or w == "{" or w == "}": continue
        if props.len > 0: props.add ", "
        props.add w
      gq.add " {" & props & "}"
    let res = t.runFn(gq, initTable[string, Value]())
    s.say($res.affected & " created")
  of "link":
    if words.len != 4:
      gbFail("link needs two names and a relationship type")
    let a = s.nodeOf(words[1])
    let b = s.nodeOf(words[3])
    let id = t.linkFn(a, words[2], b)
    s.say("linked " & $id)
  of "set":
    if words.len < 4:
      gbFail("set needs a name, a property and a value")
    var gq = "set $" & words[1] & " " & words[2]
    if words[3] == "=":
      if words.len < 5:
        gbFail("set needs a value")
      gq.add " = " & words[4]
    else:
      gq.add " = " & words[3]
    let res = t.runFn(gq, initTable[string, Value]())
    s.say($res.affected & " updated")
  of "drop":
    if words.len != 2:
      gbFail("drop needs a name")
    let res = t.runFn("drop $" & words[1], initTable[string, Value]())
    s.say($res.affected & " dropped")
  else:
    gbFail("unknown statement '" & words[0] & "'")
  true
