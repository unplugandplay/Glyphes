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
##   2 nodes
## ready> p = first
## ready> show p
##   1 :Person
##     name Ana
##     age 34
##     KNOWS -> 2
## ready> go KNOWS
##   1 nodes
## ready> if p = 1 then print "found"
## ```
##
## The client reaches the engine through one door — a `GbTransport` — and
## never touches the store. That is what keeps a client bug from
## corrupting a graph (pin GB1), and it is what makes the eZ80 guest
## possible: the same grammar over a port channel instead of in-process
## (pin GB5).

import std/[tables, strutils]
import ./gq
import ./gbasic_types
import ./gbasic_expr
import ./store/prop

type
  GbError* = object of CatchableError
    ## A client-side refusal, naming the statement that caused it.

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
    ## Where `input` reads from. The host supplies it (the prompt reads
    ## the terminal); the guest would read a port channel. Without one,
    ## `input` is refused by name rather than hanging.
    inputFn*: proc(): string
    ## The program, when the session is running one: the lines, the
    ## name, where each subroutine starts, and the call stack.
    ##
    ## A program is *named* and its subroutines are *named* — no line
    ## numbers anywhere, and no `goto`: a subroutine is called by its
    ## name and comes back by its `return`, so there is nothing left
    ## that a line number would be for.
    progLines*: seq[string]     ## the program's lines
    progName*: string            ## the program's name (its title)
    progSubs*: Table[string, int]  ## a subroutine's name -> the line its body starts at
    progPc*: int                ## where the program is
    progStack*: seq[int]        ## the lines to come back to
    inProgram*: bool            ## is a program running? (an immediate
                                ## `gosub` has nothing to call)

proc gbFail(msg: string) {.noreturn.} =
  raise newException(GbError, "glyph basic: " & msg)

proc newSession*(): GbSession =
  result.names = initTable[string, GbValue]()

proc findKeyword(text: string, word: string): int =
  ## Where a keyword starts, at a word boundary — so `if tomorrow then`
  ## does not find a "to" inside "tomorrow", and a name called `then`
  ## does not end a condition early. Returns -1 if the word is not
  ## there.
  var at = 0
  while at < text.len:
    let i = text.toLowerAscii.find(word.toLowerAscii, at)
    if i < 0:
      return -1
    let beforeOk = i == 0 or not (text[i - 1] in {'a'..'z'} or
                                  text[i - 1] in {'A'..'Z'} or
                                  text[i - 1] in {'0'..'9'} or
                                  text[i - 1] == '_')
    let afterAt = i + word.len
    let afterOk = afterAt >= text.len or not (text[afterAt] in {'a'..'z'} or
                                            text[afterAt] in {'A'..'Z'} or
                                            text[afterAt] in {'0'..'9'} or
                                            text[afterAt] == '_')
    if beforeOk and afterOk:
      return i
    at = i + 1
  -1

proc splitStatements(line: string): seq[string] =
  ## The statements on one line, separated by `:` — the BASIC's own
  ## separator (the eZ80 BASIC uses it, and so does the CPC's).
  var cur = ""
  var inStr = false
  for ch in line:
    if ch == '"':
      inStr = not inStr
      cur.add ch
    elif ch == ':' and not inStr:
      if cur.strip.len > 0:
        result.add cur.strip
      cur = ""
    else:
      cur.add ch
  if cur.strip.len > 0:
    result.add cur.strip

proc say*(s: var GbSession, text: string) =
  ## Append to the transcript.
  s.transcript.add text
  s.transcript.add "\n"

# ------------------------------------------------------------- the values

proc first*(s: GbSession): int64 =
  ## The cursor's first node (pin GB2): `p = first` in the prompt
  ## sketch. An empty cursor is refused by name — there is no first.
  if s.cursor.len == 0: gbFail("the cursor is empty")
  s.cursor[0]

proc last*(s: GbSession): int64 =
  ## The cursor's last node — the other end of the same pick.
  if s.cursor.len == 0: gbFail("the cursor is empty")
  s.cursor[^1]

proc findBlank(text: string): int =
  ## Where the first space or tab is. A statement's words are split on
  ## either, so a label must not swallow a tab: `find Person\twhere …`
  ## has the label and the clause, and taking the first *space* alone
  ## would make the label `Person\twhere`.
  for i, ch in text:
    if ch in {' ', '\t'}:
      return i
  -1

proc nodeOf(s: GbSession, name: string): int64 =
  ## The node a name holds. A name that holds a number is a node id too:
  ## the client is the one that knows ids are numbers, and a child
  ## should not have to. A literal id — `show 1` — is the same thing
  ## written the other way, so it is accepted for the same reason.
  ## `first` and `last` pick the cursor's ends (pin GB2), after the
  ## session's own names and after a literal.
  if not s.names.hasKey(name):
    if name.len > 0:
      var allDigits = true
      for ch in name:
        if ch notin {'0'..'9'}:
          allDigits = false
      if allDigits:
        var literal = 0'i64
        for ch in name:
          let d = ord(ch) - ord('0')
          if literal > (high(int64) - d) div 10:
            gbFail("the number '" & name & "' is too big to hold")
          literal = literal * 10 + d
        return literal
    if name == "first":
      return s.first()
    if name == "last":
      return s.last()
    gbFail("no such name '" & name & "'")
  let v = s.names[name]
  case v.kind
  of gbvNode: v.nodeId
  of gbvNumber: v.number
  of gbvString: gbFail("the name '" & name & "' holds text, not a node")
  of gbvBool: gbFail("the name '" & name & "' holds a yes or a no, not a node")
  of gbvNull: gbFail("the name '" & name & "' holds nothing, not a node")

proc setCursor*(s: var GbSession, ids: seq[int64]) =
  s.cursor = ids

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

proc cleanName(name: string): string =
  ## A name as it was written. The trailing dot of a COBOL-style
  ## declaration is punctuation, not part of the name: `SUBROUTINE.
  ## AFFICHER_TOTAL.` and `gosub AFFICHER_TOTAL` are the same name.
  result = name
  if result.len > 0 and result[^1] == '.':
    result.setLen(result.len - 1)

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
      of gbvBool: params[pname] = Value(kind: vkBool, b: v.flag)
      of gbvNull: params[pname] = Value(kind: vkNull)
      acc.add "$" & pname
      i = j
    else:
      acc.add text[i]
      inc i
  result = acc

proc showNode(s: var GbSession, t: GbTransport, id: int64) =
  ## A node, printed as a node: its id, its label, its properties and
  ## its edges. This is the "chase" — the thing a graph prompt is for.
  ##
  ## The label comes from the properties the transport knows how to
  ## name; a node's own label is one of them. (The labels of the whole
  ## graph were once looped over here without using them — a loop that
  ## asked every label of the engine and answered nothing.)
  var label = ""
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

proc loopBlocks(parts: seq[string]): tuple[blocks, after: seq[string]] =
  ## A loop written `... : stmt : ... : next : stmt`. The statements after
  ## the `next` are the ones that follow the loop; a loop that never
  ## writes `next` runs to the end of the line, which is the one-line
  ## form.
  ##
  ## **A nested loop is handed its own body.** A `for` inside a body is
  ## grouped with its matching `next` and run as one line, because
  ## `runStatement` sees one statement at a time and a nested loop is one
  ## statement whose body is the lines that follow it. Without the
  ## grouping, `for a : for b : show a, b : next : next` would hand the
  ## outer loop the inner one's `next` and the inner loop no body at all.
  ##
  ## A nested loop therefore writes its own `next` — the one ambiguity
  ## the flat line leaves, and the reason the marker exists.
  var i = 0
  while i < parts.len:
    let stmt = parts[i].strip()
    let w = stmt.splitWhitespace
    if w.len > 0 and w[0].toLowerAscii == "next":
      if i + 1 < parts.len:
        result.after = parts[i + 1 .. ^1]
      return
    if w.len > 0 and w[0].toLowerAscii == "for":
      var piece = @[stmt]
      var depth = 1
      inc i
      while i < parts.len and depth > 0:
        piece.add parts[i]
        let bw = parts[i].strip().splitWhitespace
        if bw.len > 0 and bw[0].toLowerAscii == "for":
          inc depth
        elif bw.len > 0 and bw[0].toLowerAscii == "next":
          dec depth
        inc i
      result.blocks.add piece.join(" : ")
      continue
    result.blocks.add stmt
    inc i

proc runStatement*(s: var GbSession, t: GbTransport, raw: string): bool =
  ## Run one client statement. Returns false when the statement asked
  ## the client to stop (`end`).
  ##
  ## The line is **stripped first**: `  print 1` and `print 1` are the
  ## same statement, and so are `  find Person` and `find Person` — the
  ## guest's tokenizer skips blanks while it splits, so the host must
  ## too, or a line pasted with its indent would read a *different
  ## label* on the two clients.
  let line = raw.strip()
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
    ## The right-hand side is the *rest of the line*, so `t = t + 1` is a
    ## thing: taking the third word alone would quietly drop the `+ 1`.
    let eq = line.find('=')
    if eq < 0:
      gbFail("'" & words[0] & " = ' needs a value")
    let v = evalExpr(s.names, line[eq + 1 .. ^1].strip(), s.cursor)
    s.names[words[0]] = v
    return true
  case cmd
  of "rem":
    discard
  of "end":
    return false
  of "let":
    ## let <name> = <expression>
    ##
    ## The right-hand side is an *expression*, like the bare
    ## assignment's: `let t = t + 1` is a thing, and a `let` that took
    ## only a literal or a name would be a second, weaker way of
    ## saying the same thing.
    if words.len < 4 or words[2] != "=":
      gbFail("let needs a name, '=' and a value")
    let eq = line.find('=')
    if eq < 0:
      gbFail("let needs a name, '=' and a value")
    let v = evalExpr(s.names, line[eq + 1 .. ^1].strip(), s.cursor)
    s.names[words[1]] = v
  of "print":
    if words.len == 1:
      ## the cursor
      if s.cursor.len == 0:
        s.say("the cursor is empty")
      else:
        s.say($s.cursor.len & " nodes")
    else:
      ## Each item is an expression, so `print i + 1` is a thing.
      for item in splitStatements(line[5 .. ^1]):
        if item.len == 0: continue
        let v = evalExpr(s.names, item, s.cursor)
        s.say(v.valueText())
  of "if":
    ## if <expr> then <statement>[: <statement>...]
    ##
    ## The conditional the query language refuses to have: the engine
    ## has no CASE and no EXISTS, so a client that wants a choice makes
    ## it here.
    let rest = line[2 .. ^1].strip()
    let at = findKeyword(rest, "then")
    if at < 0:
      gbFail("if needs 'then'")
    let condText = rest[0 ..< at].strip()
    let bodyText = rest[at + 4 .. ^1].strip()
    if condText.len == 0:
      gbFail("if needs a condition")
    if bodyText.len == 0:
      gbFail("if needs a statement after 'then'")
    if condition(s.names, condText, s.cursor):
      for piece in loopBlocks(splitStatements(bodyText)).blocks:
        if not s.runStatement(t, piece):
          return false
  of "for":
    ## for <var> = <a> to <b> [step <s>] : <statement>... : next
    ## for each <var> [do] : <statement>... : next
    ##
    ## The loop the query language refuses to have: no FOREACH, no UNION.
    ## The body is on the same line, separated by `:` — the first cut's
    ## shape, and a multi-line body is the next cut.
    if words.len >= 2 and words[1].toLowerAscii == "each":
      ## **The cursor loop.** The set is the one `find` and `go` leave,
      ## and the name holds a node id for the body's length — so `show`,
      ## `link`, `set`, `drop` and `go ... from` all take it, and the
      ## language needs no second way to name a node.
      ##
      ##     find Person
      ##     for each p : show p : next
      ##
      ## The walk uses a *copy* of the cursor and puts the cursor back
      ## afterwards. A body that runs `go` — the natural way to look at
      ## a node's neighbours — therefore does not disturb the walk, and
      ## a nested loop sees the set its own entry found.
      let parts = splitStatements(line[3 .. ^1].strip())
      if parts.len == 0 or parts[0].strip().len < 4:
        gbFail("for each needs a name")
      var head = parts[0].strip()
      if head[0 .. 3].toLowerAscii != "each":
        gbFail("expected 'each' after 'for'")
      head = head[4 .. ^1].strip()
      let sp = findBlank(head)
      let varName = (if sp < 0: head else: head[0 ..< sp]).strip()
      let tail = (if sp < 0: "" else: head[sp .. ^1].strip())
      if varName.len == 0:
        gbFail("for each needs a name")
      var bodyParts: seq[string] = @[]
      if tail.len > 0:
        if tail.toLowerAscii == "in" or tail.toLowerAscii.startsWith("in "):
          ## There is no list value to walk: the cursor is the client's
          ## one set (pin GB2), and a second way to name a set would be
          ## a second language.
          gbFail("for each walks the cursor; there is no 'in'")
        if not tail.toLowerAscii.startsWith("do"):
          gbFail("expected 'do' or ':' after the name, found '" & tail & "'")
        let firstBody = tail[2 .. ^1].strip()
        if firstBody.len == 0:
          gbFail("for each needs a statement after 'do'")
        bodyParts.add firstBody
      for i in 1 ..< parts.len:
        bodyParts.add parts[i]
      let (blocks, after) = loopBlocks(bodyParts)
      if blocks.len == 0:
        gbFail("for each needs a body")
      let ids = s.cursor
      var stopped = false
      for id in ids:
        s.names[varName] = GbValue(kind: gbvNumber, number: id)
        for piece in blocks:
          if not s.runStatement(t, piece):
            stopped = true
            break
        if stopped:
          break
      ## The walk leaves the cursor where it found it.
      s.cursor = ids
      if stopped:
        return false
      for stmt in after:
        if not s.runStatement(t, stmt):
          return false
      return true
    let rest = line[3 .. ^1].strip()
    let parts = splitStatements(rest)
    if parts.len == 0:
      gbFail("for needs a variable, a range and a body")
    let header = parts[0]
    let eq = header.find('=')
    if eq < 0:
      gbFail("for needs '=' between the variable and the first value")
    let varName = header[0 ..< eq].strip()
    let rangeText = header[eq + 1 .. ^1].strip()
    let toAt = findKeyword(rangeText, "to")
    if toAt < 0:
      gbFail("for needs 'to'")
    let firstText = rangeText[0 ..< toAt].strip()
    var lastText = rangeText[toAt + 2 .. ^1].strip()
    var stepText = "1"
    let stepAt = findKeyword(lastText, "step")
    if stepAt >= 0:
      stepText = lastText[stepAt + 4 .. ^1].strip()
      lastText = lastText[0 ..< stepAt].strip()
    if varName.len == 0:
      gbFail("for needs a variable name")
    if parts.len < 2:
      gbFail("for needs a body")
    ## `next` ends the body: the statements before it are the loop's, and
    ## the statements after it are the ones that follow the loop. The
    ## marker itself is optional — a one-line loop may end without it.
    let (blocks, after) = loopBlocks(parts[1 .. ^1])
    if blocks.len == 0:
      gbFail("for needs a body")
    let first = evalExpr(s.names, firstText, s.cursor)
    let last = evalExpr(s.names, lastText, s.cursor)
    let step = evalExpr(s.names, stepText, s.cursor)
    if first.kind != gbvNumber or last.kind != gbvNumber or
       step.kind != gbvNumber:
      gbFail("for needs numbers")
    if step.number == 0:
      gbFail("for needs a step that is not zero")
    ## A cap, so a loop that cannot finish says so instead of hanging:
    ## the client is a prompt, and a prompt that hangs is a prompt that
    ## is broken. The cap is checked *before* the body runs: a million
    ## rounds run, and the million-and-first is refused rather than
    ## executed — the guest checks its 16-bit guard the same way.
    var v = first.number
    var rounds = 0
    while (if step.number > 0: v <= last.number else: v >= last.number):
      inc rounds
      if rounds > 1_000_000:
        gbFail("the loop did not finish after a million rounds")
      s.names[varName] = GbValue(kind: gbvNumber, number: v)
      for piece in blocks:
        if not s.runStatement(t, piece):
          return false
      ## The next value. A step that would leave int64 *ends* the loop:
      ## there is no number past every number, so no further round can
      ## meet the condition — and computing it anyway would crash (GB6).
      if step.number > 0:
        if overAdd(v, step.number): break
        v += step.number
      else:
        if overSub(v, step.number): break
        v += step.number
    ## Whatever followed the `next` runs once, after the loop.
    for piece in after:
      if not s.runStatement(t, piece):
        return false
  of "gosub":
    ## gosub <name>
    ##
    ## The call. A subroutine is called by its *name*: there are no line
    ## numbers in this language, and no `goto` — the name is the only
    ## thing a call can mean.
    if words.len != 2:
      gbFail("gosub needs a subroutine name")
    if not s.inProgram:
      gbFail("there is no program to call")
    let name = cleanName(words[1])
    let at = s.progSubs.getOrDefault(name, -1)
    if at < 0:
      gbFail("no subroutine '" & name & "'")
    s.progStack.add s.progPc
    s.progPc = at
  of "return":
    ## return
    ##
    ## The way back. A subroutine that reaches its end without a
    ## `return` is refused by name: falling off the end is the trap
    ## COBOL's paragraphs have, and a child's language should not
    ## inherit it.
    if words.len != 1:
      gbFail("return needs nothing")
    if s.progStack.len == 0:
      gbFail("return outside a subroutine")
    s.progPc = s.progStack[^1]
    s.progStack.setLen(s.progStack.len - 1)
  of "while":
    ## while <expr> : <statement>
    ##
    ## The unbounded loop, which is what `goto` used to be for. The
    ## same cap as `for`: a loop that cannot finish says so rather
    ## than hanging.
    let rest = line[5 .. ^1].strip()
    let parts = splitStatements(rest)
    if parts.len < 2:
      gbFail("while needs a condition and a statement")
    ## The body, and the optional `next` marker — the same shape as
    ## `for`, so a child who writes one writes the other.
    let (blocks, after) = loopBlocks(parts[1 .. ^1])
    if blocks.len == 0:
      gbFail("while needs a statement")
    var rounds = 0
    while condition(s.names, parts[0], s.cursor):
      inc rounds
      if rounds > 1_000_000:
        gbFail("the loop did not finish after a million rounds")
      for piece in blocks:
        if not s.runStatement(t, piece):
          return false
    for piece in after:
      if not s.runStatement(t, piece):
        return false
  of "input":
    ## input <name>
    ##
    ## A line that reads as a whole number is a number, and anything
    ## else is text — the BASIC's INPUT, which takes what you type and
    ## knows what it is. The alternative (text always) would make
    ## `input n` then `if n > 5` a *text* comparison, quietly wrong
    ## rather than refused.
    if words.len != 2:
      gbFail("input needs a name")
    if s.inputFn == nil:
      gbFail("there is nothing to read from")
    let typed = s.inputFn().strip()
    ## The rule is the host's: strip both ends, all digits is a number,
    ## anything else text. The digit line is checked against int64 the
    ## way every literal is — a typed number too big to hold is refused
    ## by name, never an overflow crash (GB6).
    var isNumber = typed.len > 0
    for ch in typed:
      if ch notin {'0'..'9'}:
        isNumber = false
    if isNumber:
      var n: int64 = 0
      for ch in typed:
        let d = ord(ch) - ord('0')
        if n > (high(int64) - d) div 10:
          gbFail("the number typed is too big to hold")
        n = n * 10 + d
      s.names[words[1]] = GbValue(kind: gbvNumber, number: n)
    else:
      s.names[words[1]] = GbValue(kind: gbvString, text: typed)
  of "find", "count":
    ## find <label> [where <expr>]
    ## count [<label> [where <expr>]]
    ##
    ## `count` with no label is the *client's* count — the size of the
    ## cursor it is holding (PRD §3.1, and the prompt sketch's own
    ## `count` on its own line). With a label it asks the engine, the
    ## way `find` does.
    var label = ""
    let after = cmd.len
    var tail = line[after .. ^1].strip()
    if tail.len > 0:
      let sp = findBlank(tail)
      if sp < 0:
        label = tail
        tail = ""
      else:
        label = tail[0 ..< sp]
        tail = tail[sp .. ^1].strip()
    if label.len == 0 and tail.len == 0:
      if cmd == "count":
        s.say($s.cursor.len)
        return true
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
      if rest.len > 3:
        ## The guest refuses a statement with words it does not
        ## understand, and so does the host now: `go KNOWS from p
        ## extra` used to *drop* the extra word and answer as if it
        ## had not been there.
        gbFail("go has extra words after '" & rest[2] & "'")
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
    ##
    ## The property list is the client's own text, passed through as
    ## written: `{name "Ada", age 36}` is already the GQ statement's
    ## syntax, and rebuilding it word by word was how the commas and
    ## the braces got lost. GQ turns each literal into a parameter, so
    ## the value still never reaches the Cypher text (pin GQ4).
    let rest = line[3 .. ^1].strip()
    if rest.len == 0:
      gbFail("add needs a label")
    let gq = "add " & rest
    let res = t.runFn(gq, initTable[string, Value]())
    ## The new node is the cursor afterwards (PRD §3.1): the id came
    ## back with the write, and the client's next statement is usually
    ## about the node it just made.
    if res.ids.len > 0:
      s.setCursor(res.ids)
    s.say($res.affected & " created")
  of "link":
    if words.len != 4:
      gbFail("link needs two names and a relationship type")
    let a = s.nodeOf(words[1])
    let b = s.nodeOf(words[3])
    let id = t.linkFn(a, words[2], b)
    s.say("linked " & $id)
  of "set":
    ## set <name> <prop> = <value>
    ##
    ## Both the node and the value travel as *parameters*: the name is
    ## resolved here (the engine never sees a client name), and the
    ## value is the client's own expression, evaluated in the client.
    ## `set p age 36` and `set p age = 36` are the same statement.
    if words.len < 4:
      gbFail("set needs a name, a property and a value")
    var valueWords = (if words[3] == "=": words[4 .. ^1] else: words[3 .. ^1])
    if valueWords.len == 0:
      gbFail("set needs a value")
    let value = evalExpr(s.names, valueWords.join(" "), s.cursor)
    var params = initTable[string, Value]()
    params["n"] = Value(kind: vkInt, i: s.nodeOf(words[1]))
    case value.kind
    of gbvNode: params["v0"] = Value(kind: vkInt, i: value.nodeId)
    of gbvNumber: params["v0"] = Value(kind: vkInt, i: value.number)
    of gbvString: params["v0"] = Value(kind: vkString, s: value.text)
    of gbvBool: params["v0"] = Value(kind: vkBool, b: value.flag)
    of gbvNull: params["v0"] = Value(kind: vkNull)
    let gq = "set $n " & words[2] & " = $v0"
    let res = t.runFn(gq, params)
    s.say($res.affected & " updated")
  of "drop":
    if words.len != 2:
      gbFail("drop needs a name")
    var params = initTable[string, Value]()
    params["n"] = Value(kind: vkInt, i: s.nodeOf(words[1]))
    let res = t.runFn("drop $n", params)
    s.say($res.affected & " dropped")
  else:
    gbFail("unknown statement '" & words[0] & "'")
  true


proc isDeclaration(line: string): bool =
  ## Is this line structure rather than a statement? `SUBROUTINE. NAME.`
  ## and `END PROGRAM.` are structure, and the runner must not execute
  ## them. A bare `end` is not: it is the BASIC's stop, and the
  ## statement executor answers it.
  let w = line.strip.splitWhitespace
  if w.len == 0:
    return true
  let first = w[0].toLowerAscii
  if first == "subroutine.":
    return true
  first == "end" and w.len >= 2 and w[1].toLowerAscii == "program."

proc runProgram*(s: var GbSession, t: GbTransport; lines: openArray[string]): bool =
  ## Run a program: the main body, and the subroutines it calls.
  ##
  ## The program's shape (PRD-GLYPH-BASIC.md §3.3):
  ##
  ##     PROGRAM-ID. <name>
  ##     <the main body>
  ##     SUBROUTINE. <name>
  ##     <the body>
  ##     END PROGRAM.
  ##
  ## The main body ends the program — there is no falling into the
  ## first subroutine, which is the trap COBOL's paragraphs have.
  if lines.len == 0:
    gbFail("a program needs a line")
  let first = lines[0].strip.splitWhitespace
  if first.len < 2 or first[0].toLowerAscii != "program-id.":
    gbFail("a program starts with PROGRAM-ID. <name>")
  s.progLines = @[]
  for l in lines:
    s.progLines.add l
  s.inProgram = true
  s.progName = cleanName(first[1])
  s.progSubs = initTable[string, int]()
  s.progStack = @[]
  s.progPc = 1
  ## Where each subroutine's body starts: the line after its
  ## declaration.
  for i, line in s.progLines:
    let w = line.strip.splitWhitespace
    if w.len >= 2 and w[0].toLowerAscii == "subroutine.":
      s.progSubs[cleanName(w[1])] = i + 1
  ## The body, statement by statement.
  try:
    while s.progPc < s.progLines.len:
      let line = s.progLines[s.progPc]
      s.progPc = s.progPc + 1
      if isDeclaration(line):
        ## The main body ended, or a subroutine's body did.
        if s.progStack.len > 0:
          gbFail("a subroutine ended without a RETURN")
        break
      if not s.runStatement(t, line):
        break
    ## Falling off the *end of the lines* with a call open is the same
    ## trap the declaration catches: a program with no `END PROGRAM.`
    ## used to return as if nothing were still waiting for its
    ## `return`.
    if s.progStack.len > 0:
      gbFail("a subroutine ended without a RETURN")
  finally:
    ## Whatever happened — the last line, `end`, or a refusal in the
    ## middle — the session is back at its prompt: an immediate `gosub`
    ## has nothing to call, and `end` is the prompt's own stop again.
    ## An exception used to skip the clearing line and leave
    ## `inProgram` set, so the *next* line after a refused program
    ## still believed it was inside one.
    s.inProgram = false
    s.progStack = @[]
  true

