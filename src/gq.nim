## gq.nim — GLYPH QUERY: the graph's own query language.
##
## GLYPH QUERY is a small, line-oriented query language for the graph.
## It is a **surface**, not a second engine: every statement compiles to
## Cypher — text plus parameters — and the existing Cypher interpreter,
## planner and operators run it (PRD-GLYPH-QUERY.md, pin GQ1).
##
## ```
## find person                  ->  MATCH (n:person) RETURN id(n) AS id
## find person where age > 30   ->  MATCH (n:person) WHERE n.age > 30 ...
## go knows                     ->  MATCH (a)-[:knows]->(b) RETURN id(b) AS id
## go back knows                ->  MATCH (a)-[:knows]->(b) RETURN id(a) AS id
## count person                 ->  MATCH (n:person) RETURN count(n) AS n
## labels                       ->  the schema door
## add person {name "Ada"}      ->  CREATE (n:person {name: $p1})
## link $a knows $b             ->  the link door
## set $n age = 36              ->  MATCH (n) WHERE id(n) = $n SET n.age = $p1
## drop $n                      ->  MATCH (n) WHERE id(n) = $n DETACH DELETE n
## ```
##
## A label and a relationship type are **exact**, as they are in the
## store: `find person` does not find `Person`. The engine's rule is
## that an unknown label is an empty result and never an error (pin C2),
## so the *client* is the one that can be helpful about it — it knows
## the labels, and can say "no label 'person'; the labels are: Person,
## Company" instead of returning nothing.
##
## Two rules make the language safe to expose:
##
## * **A value is a parameter, never text.** A literal the client
##   supplies becomes `$p1`, `$p2`, … and the value goes in the
##   parameter map. The only text that reaches the compiled query is
##   text the client *wrote* — a label, a relationship type, or the body
##   of a `where` clause.
## * **The expression language is Cypher's.** A `where` clause is not
##   parsed here: it is handed to the engine, with bare property names
##   rewritten to `n.<name>` so that `where age > 30` means the same
##   thing it means in Cypher.
##
## The `where` rewrite is textual, not a re-emission: the engine's lexer
## finds the identifier tokens and the compiler inserts `n.` at their
## positions, so a float literal or a string with an escape keeps its
## exact spelling.

import std/[tables, strutils]
import ./store/prop
import ./cypher/lexer

type
  GqError* = object of CatchableError
    ## A refusal, naming the construct that caused it (pin GQ6).

  GqProgramKind* = enum
    gpkQuery = 0     ## a Cypher statement to run
    gpkLabels        ## the labels in the graph (the schema door)
    gpkLink          ## one relationship between two node ids

  GqProgram* = object
    ## What a GLYPH QUERY line compiles to.
    kind*: GqProgramKind
    cypher*: string               ## the compiled Cypher, for gpkQuery
    params*: Table[string, Value]  ## the parameter map, for gpkQuery
    linkType*: string              ## for gpkLink
    linkFrom*, linkTo*: string     ## for gpkLink: the *parameter names*,
                                   ## which the client resolves to node
                                   ## ids (the client owns the values)

const
  ## The words that are not property names. A `where` clause's identifier
  ## that is not here and is not a function call is a property of the
  ## node the statement matched.
  gqReserved = [
    "and", "or", "xor", "not", "in", "is", "contains", "startswith",
    "endswith", "case", "when", "then", "else", "end", "true", "false",
    "null", "distinct", "as", "by", "limit", "skip", "asc", "desc"
  ]

proc describeTok(t: Token): string =
  ## What the token was, for a refusal that names it.
  case t.kind
  of tkEof: "the end of the statement"
  of tkIdent: "'" & t.text & "'"
  of tkInt, tkFloat: "the number " & t.text
  of tkString: "a string"
  of tkParam: "the parameter " & t.text
  else: "'" & t.text & "'"

proc gqFail(msg: string) {.noreturn.} =
  raise newException(GqError, "glyph query: " & msg)

proc isReserved(w: string): bool =
  for r in gqReserved:
    if cmpIgnoreCase(w, r) == 0:
      return true
  false

# ------------------------------------------------------------- the lexer

proc lexAll(src: string): seq[Token] =
  ## The statement's tokens. The engine's lexer does the work: GLYPH QUERY
  ## has no lexical rules of its own, and borrowing the engine's means the
  ## two languages cannot disagree about what an identifier is.
  ##
  ## The engine's own `Token` is used rather than a parallel copy: a type
  ## here with the same field names shadows the engine's, and the shadow
  ## is enough to make the engine's fields unreachable (Nim reports
  ## "undeclared field" for a field that is plainly there).
  tokenize(src)

# ------------------------------------------------------- the where rewrite

proc rewriteWhere(where: string): string =
  ## `where age > 30` becomes `where n.age > 30`.
  ##
  ## The rewrite is textual and positional: the engine's lexer says
  ## where the identifiers are, and `n.` is inserted there. Nothing else
  ## in the clause moves, so a float, a string with an escape, or a
  ## comment keeps its exact spelling.
  if where.len == 0:
    return where
  let toks = lexAll(where)
  var inserts: seq[int] = @[]
  for i, t in toks:
    if t.kind != tkIdent:
      continue
    if isReserved(t.text):
      continue
    ## A function call is not a property: `count(x)` is a function.
    if i + 1 < toks.len and toks[i + 1].kind == tkSym and toks[i + 1].text == "(":
      continue
    inserts.add t.col - 1
  if inserts.len == 0:
    return where
  result = where
  ## The offsets shift as the text grows, so the insertions run from the
  ## last one backwards: each one leaves the earlier offsets valid.
  var i = inserts.len - 1
  while i >= 0:
    result.insert("n.", inserts[i])
    dec i

# ------------------------------------------------------------ the compiler

type
  Compiler = object
    toks: seq[Token]
    pos: int
    src: string
    params: Table[string, Value]
    nextParam: int

proc peek(c: Compiler): Token {.inline.} =
  if c.pos < c.toks.len: c.toks[c.pos] else: Token(kind: tkEof, text: "", col: 1)

proc next(c: var Compiler): Token {.inline.} =
  result = c.peek()
  inc c.pos

proc at(c: Compiler; word: string): bool {.inline.} =
  let t = c.peek()
  t.kind == tkIdent and cmpIgnoreCase(t.text, word) == 0

proc eat(c: var Compiler; word: string): bool =
  if c.at(word):
    discard c.next()
    true
  else:
    false

proc expectWord(c: var Compiler; word: string) =
  if not c.eat(word):
    gqFail("expected '" & word & "', found " & describeTok(c.peek()))

proc expectIdent(c: var Compiler; what: string): string =
  ## An identifier that goes into the query *text*: a label or a
  ## relationship type. It is checked here, because this is the one
  ## place where client text becomes part of a query, and a name with a
  ## quote in it would be a hole in the language.
  let t = c.next()
  if t.kind != tkIdent:
    gqFail("expected " & what & ", found " & describeTok(t))
  for ch in t.text:
    if not (ch in {'a'..'z'} or ch in {'A'..'Z'} or ch in {'0'..'9'} or ch == '_'):
      gqFail(what & " '" & t.text & "' is not a plain name")
  t.text

proc expectParam(c: var Compiler; what: string): string =
  ## A `$name` — the client's own parameter, passed through untouched so
  ## that the client keeps the name it chose.
  let t = c.next()
  if t.kind != tkParam:
    gqFail("expected " & what & ", found " & describeTok(t))
  ## The engine's lexer hands back a parameter's *name*: the '$' is a
  ## sigil, not part of the name, and the compiled Cypher needs it back.
  "$" & t.text

proc addParam(c: var Compiler; v: Value): string =
  ## A literal becomes a parameter, never text (pin GQ4).
  c.nextParam += 1
  let name = "p" & $c.nextParam
  c.params[name] = v
  name

proc literalValue(t: Token): Value =
  case t.kind
  of tkInt: Value(kind: vkInt, i: t.intNum)
  of tkFloat: Value(kind: vkFloat, f: t.num)
  of tkString: Value(kind: vkString, s: t.str)
  else: Value(kind: vkString, s: t.text)

proc literal(c: var Compiler; what: string): string =
  ## A literal value, as a parameter reference.
  let t = c.next()
  case t.kind
  of tkInt, tkFloat, tkString:
    "$" & c.addParam(literalValue(t))
  of tkParam:
    ## A `$name` keeps its sigil: the *name* is what the token holds,
    ## and a compiled Cypher property value without the `$` would be a
    ## variable, not the parameter the client passed.
    "$" & t.text
  else:
    gqFail("expected " & what & ", found " & describeTok(t))

proc restOfLine(c: var Compiler): string =
  ## The rest of the statement, from the current token to the end.
  ##
  ## Used for a `where` clause, which is handed to the engine verbatim.
  ## The statement is one line (pin: one statement per line), so a
  ## token's column is its offset in the source.
  ##
  ## The tokens are consumed as well as read: a clause that is looked at
  ## but not consumed is a clause the statement then complains about.
  if c.pos >= c.toks.len:
    return ""
  let start = c.toks[c.pos].col - 1
  c.pos = c.toks.len
  if start < 0 or start >= c.src.len:
    return ""
  c.src[start .. ^1].strip()

proc compileFind(c: var Compiler): string =
  ## find [<label>] [where <expr>]
  var label = ""
  if c.peek().kind == tkIdent and not c.at("where"):
    label = c.expectIdent("a label")
  elif c.peek().kind != tkEof and not c.at("where"):
    gqFail("expected a label, found " & describeTok(c.peek()))
  var where = ""
  if c.eat("where"):
    where = c.restOfLine()
  var s = "MATCH (n"
  if label.len > 0:
    s.add ":" & label
  s.add ")"
  if where.len > 0:
    s.add " WHERE " & rewriteWhere(where)
  s.add " RETURN id(n) AS id"
  result = s

proc compileGo(c: var Compiler): string =
  ## go [back] <type> [from <param>] [where <expr>]
  let backwards = c.eat("back")
  let rtype = c.expectIdent("a relationship type")
  var fromRef = ""
  if c.eat("from"):
    fromRef = c.expectParam("a node reference")
  var where = ""
  if c.eat("where"):
    where = c.restOfLine()
  var s = "MATCH (a)-[:" & rtype & "]->(b)"
  if fromRef.len > 0:
    s.add " WHERE id(a) = " & fromRef
  if where.len > 0:
    if fromRef.len > 0:
      s.add " AND "
    s.add rewriteWhere(where)
  s.add " RETURN id(" & (if backwards: "a" else: "b") & ") AS id"
  result = s

proc compileCount(c: var Compiler): string =
  ## count [<label>] [where <expr>]
  var label = ""
  if c.peek().kind == tkIdent and not c.at("where"):
    label = c.expectIdent("a label")
  elif c.peek().kind != tkEof and not c.at("where"):
    gqFail("expected a label, found " & describeTok(c.peek()))
  var where = ""
  if c.eat("where"):
    where = c.restOfLine()
  var s = "MATCH (n"
  if label.len > 0:
    s.add ":" & label
  s.add ")"
  if where.len > 0:
    s.add " WHERE " & rewriteWhere(where)
  s.add " RETURN count(n) AS n"
  result = s

proc compileAdd(c: var Compiler): string =
  ## add <label> [{<prop> <value>}]
  let label = c.expectIdent("a label")
  var s = "CREATE (n:" & label
  if c.peek().kind == tkSym and c.peek().text == "{":
    discard c.next()
    var props: seq[string] = @[]
    while true:
      let name = c.expectIdent("a property name")
      ## The property list is space-separated -- `{name "Ada"}` -- because
      ## a colon is punctuation a beginner has to be taught. A colon is
      ## accepted too, so a line copied from Cypher still works.
      if c.peek().kind == tkSym and c.peek().text == ":":
        discard c.next()
      let value = c.literal("a property value")
      props.add name & ": " & value
      if c.peek().kind == tkSym and c.peek().text == ",":
        discard c.next()
        continue
      break
    if c.peek().kind != tkSym or c.peek().text != "}":
      gqFail("expected '}' to close the property list")
    discard c.next()
    if props.len > 0:
      s.add " {" & props.join(", ") & "}"
  s.add ")"
  ## The id comes back, because the client's next statement is usually
  ## about the node it just made ("add it, then link it"). The row is
  ## the ordinary RETURN, which the engine already answers for a write.
  s.add " RETURN id(n) AS id"
  result = s

proc compileSet(c: var Compiler): string =
  ## set <param> <prop> = <value>
  let node = c.expectParam("a node reference")
  let prop = c.expectIdent("a property name")
  if not (c.peek().kind == tkSym and c.peek().text == "="):
    gqFail("expected '=' after the property name")
  discard c.next()
  let value = c.literal("a property value")
  result = "MATCH (n) WHERE id(n) = " & node & " SET n." & prop & " = " & value

proc compileDrop(c: var Compiler): string =
  ## drop <param>
  let node = c.expectParam("a node reference")
  result = "MATCH (n) WHERE id(n) = " & node & " DETACH DELETE n"

proc compileLink(c: var Compiler): GqProgram =
  ## link <param> <type> <param>
  ##
  ## The one statement GLYPH QUERY cannot express in Cypher: two nodes
  ## bound at once is a join, and the engine refuses joins. So `link` is
  ## a write door of its own (PRD-GLYPH-QUERY.md §5).
  let fromRef = c.expectParam("a node reference")
  let rtype = c.expectIdent("a relationship type")
  let toRef = c.expectParam("a node reference")
  result.kind = gpkLink
  result.linkType = rtype
  result.linkFrom = fromRef
  result.linkTo = toRef

proc compileGq*(text: string): GqProgram =
  ## Compile one GLYPH QUERY line.
  ##
  ## The line is one statement, and one line: a second line is a
  ## refusal, not a continuation (the language has no continuation).
  var src = text
  if src.contains('\n') or src.contains('\r'):
    gqFail("a GLYPH QUERY statement is one line")

  var c = Compiler(toks: lexAll(src), src: src,
                   params: initTable[string, Value]())

  result.params = initTable[string, Value]()
  if c.toks.len == 0 or c.peek().kind == tkEof:
    gqFail("empty statement")

  let word = c.peek()
  if word.kind != tkIdent:
    gqFail("expected a command, found " & describe(word))
  let cmd = word.text.toLowerAscii
  discard c.next()
  case cmd
  of "find":
    result.kind = gpkQuery
    result.cypher = c.compileFind()
  of "go":
    result.kind = gpkQuery
    result.cypher = c.compileGo()
  of "count":
    result.kind = gpkQuery
    result.cypher = c.compileCount()
  of "labels":
    result.kind = gpkLabels
  of "add":
    result.kind = gpkQuery
    result.cypher = c.compileAdd()
  of "set":
    result.kind = gpkQuery
    result.cypher = c.compileSet()
  of "drop":
    result.kind = gpkQuery
    result.cypher = c.compileDrop()
  of "link":
    result = c.compileLink()
  else:
    gqFail("unknown command '" & word.text & "'")

  ## Nothing may follow the statement: a trailing word is a mistake, and
  ## a mistake that is ignored is a mistake that is never found.
  if c.peek().kind != tkEof:
    gqFail("unexpected " & describeTok(c.peek()) & " after the statement")

  result.params = c.params
