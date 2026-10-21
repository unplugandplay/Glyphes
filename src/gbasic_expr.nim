## gbasic_expr.nim — GLYPH BASIC's expressions.
##
## The client's *own* arithmetic, in the client, for two reasons:
##
## * **The client does not lean on the engine for arithmetic** (pin GB1):
##   the door is for the *graph*, not for `1 + 1`. A condition that asked
##   the engine to evaluate it would be a round trip per `if`, and a
##   condition is the one thing a program does most.
## * **The client's numbers are 64-bit** (pin GB7): a node id is an i64,
##   and the host's word size is not the language's data model.
##
## The grammar is small on purpose — a child should be able to hold it:
##
##     expr    := orExpr
##     orExpr  := andExpr ('or' andExpr)*
##     andExpr := notExpr ('and' notExpr)*
##     notExpr := 'not' notExpr | cmpExpr
##     cmpExpr := addExpr (('='|'<>'|'<'|'>'|'<='|'>=') addExpr)?
##     addExpr := mulExpr (('+'|'-') mulExpr)*
##     mulExpr := unary (('*'|'/') unary)*
##     unary   := '-' unary | primary
##     primary := number | string | name | '(' expr ')'
##
## `null` is a value like any other, and it is not true: a comparison
## with null gives null, and null is not a condition. That is the
## engine's three-valued logic (CYPHER.md §6), inherited because a
## language that treats null as false teaches the wrong thing quietly.

import std/[strutils, tables]
import ./gbasic_types

type
  GbExprError* = object of CatchableError
    ## A refusal in an expression, naming the piece that was wrong.

proc exprFail(msg: string) {.noreturn.} =
  raise newException(GbExprError, "glyph basic: " & msg)

type
  ExprKind = enum
    ekNum, ekStr, ekName, ekBin, ekNot, ekNeg

  ## A reference: the tree is recursive, and a value tree would be an
  ## illegal recursive type.
  Expr = ref object
    kind: ExprKind
    num: int64
    text: string
    op: string
    left, right: Expr

  Lexer = object
    src: string
    pos: int

proc isSpace(c: char): bool {.inline.} =
  c == ' ' or c == '\t'

proc lexAll(src: string): seq[string] =
  ## The expression's words. A quoted string is one word.
  var cur = ""
  var inStr = false
  for ch in src:
    if ch == '"':
      inStr = not inStr
      cur.add ch
    elif not inStr and (isSpace(ch) or ch in {'=', '<', '>', '+', '-', '*', '/',
                                            '(', ')', ','}):
      if cur.len > 0:
        result.add cur
        cur = ""
      if not isSpace(ch):
        result.add $ch
    else:
      cur.add ch
  if inStr:
    exprFail("a string with no closing quote")
  if cur.len > 0:
    result.add cur

type
  Parser = object
    ## The recursive-descent parser. A parser *object* rather than nested
    ## procs, because the descent is mutual: `or` calls `and` calls `not`
    ## calls the comparison, and Nim's nested procs cannot call forward.
    toks: seq[string]
    pos: int

proc peek(p: Parser): string =
  if p.pos < p.toks.len: p.toks[p.pos] else: ""

proc take(p: var Parser): string =
  result = p.peek()
  inc p.pos

proc parseOr(p: var Parser): Expr

proc parsePrimary(p: var Parser): Expr =
  let t = p.take()
  if t.len == 0:
    exprFail("the expression ended early")
  if t == "(":
    result = p.parseOr()
    if p.peek() != ")":
      exprFail("expected ')'")
    discard p.take()
    return
  if t[0] == '"':
    if t.len < 2 or t[^1] != '"':
      exprFail("a string with no closing quote")
    return Expr(kind: ekStr, text: t[1 .. ^2])
  var n: int64 = 0
  var allDigits = t.len > 0
  for ch in t:
    if ch in {'0'..'9'}: n = n * 10 + (ord(ch) - ord('0'))
    else: allDigits = false
  if allDigits:
    return Expr(kind: ekNum, num: n)
  for ch in t:
    if not (ch in {'a'..'z'} or ch in {'A'..'Z'} or ch in {'0'..'9'} or
            ch == '_'):
      exprFail("'" & t & "' is not a name")
  result = Expr(kind: ekName, text: t)

proc parseUnary(p: var Parser): Expr =
  if p.peek() == "-":
    discard p.take()
    return Expr(kind: ekNeg, left: p.parseUnary())
  p.parsePrimary()

proc parseMul(p: var Parser): Expr =
  result = p.parseUnary()
  while p.peek() in ["*", "/"]:
    let op = p.take()
    let rhs = p.parseUnary()
    result = Expr(kind: ekBin, op: op, left: result, right: rhs)

proc parseAdd(p: var Parser): Expr =
  result = p.parseMul()
  while p.peek() in ["+", "-"]:
    let op = p.take()
    let rhs = p.parseMul()
    result = Expr(kind: ekBin, op: op, left: result, right: rhs)

proc parseCmp(p: var Parser): Expr =
  result = p.parseAdd()
  let op = p.peek().toLowerAscii
  if op in ["=", "<>", "<", ">", "<=", ">="]:
    discard p.take()
    result = Expr(kind: ekBin, op: op, left: result, right: p.parseAdd())

proc parseNot(p: var Parser): Expr =
  if p.peek().toLowerAscii == "not":
    discard p.take()
    return Expr(kind: ekNot, left: p.parseNot())
  p.parseCmp()

proc parseAnd(p: var Parser): Expr =
  result = p.parseNot()
  while p.peek().toLowerAscii == "and":
    discard p.take()
    let rhs = p.parseNot()
    result = Expr(kind: ekBin, op: "and", left: result, right: rhs)

proc parseOr(p: var Parser): Expr =
  result = p.parseAnd()
  while p.peek().toLowerAscii == "or":
    discard p.take()
    let rhs = p.parseAnd()
    result = Expr(kind: ekBin, op: "or", left: result, right: rhs)

proc parseExpr(src: string): Expr =
  ## The expression tree.
  if src.strip.len == 0:
    exprFail("an empty expression")
  var p = Parser(toks: lexAll(src))
  result = p.parseOr()
  if p.pos < p.toks.len:
    exprFail("unexpected '" & p.toks[p.pos] & "' in the expression")

# ------------------------------------------------------------- evaluation

proc truthy(v: GbValue): bool =
  ## A value as a condition. `null` is not true, and neither is zero,
  ## an empty string, or a node id of zero.
  case v.kind
  of gbvNull: false
  of gbvBool: v.flag
  of gbvNumber: v.number != 0
  of gbvString: v.text.len > 0
  of gbvNode: v.nodeId != 0

proc eval(e: Expr; names: Table[string, GbValue]): GbValue =
  case e.kind
  of ekNum: GbValue(kind: gbvNumber, number: e.num)
  of ekStr: GbValue(kind: gbvString, text: e.text)
  of ekName:
    if not names.hasKey(e.text):
      exprFail("no such name '" & e.text & "'")
    names[e.text]
  of ekNeg:
    let v = eval(e.left, names)
    case v.kind
    of gbvNumber: GbValue(kind: gbvNumber, number: -v.number)
    else: exprFail("'-' needs a number")
  of ekNot:
    let v = eval(e.left, names)
    GbValue(kind: gbvBool, flag: not truthy(v))
  of ekBin:
    let l = eval(e.left, names)
    let r = eval(e.right, names)
    case e.op
    of "and":
      ## Short-circuit, and three-valued: false and null is false, and
      ## the other combinations are null.
      if l.kind == gbvBool and not l.flag:
        return GbValue(kind: gbvBool, flag: false)
      if r.kind == gbvBool and not r.flag:
        return GbValue(kind: gbvBool, flag: false)
      if l.kind == gbvNull or r.kind == gbvNull:
        return GbValue(kind: gbvNull)
      GbValue(kind: gbvBool, flag: truthy(l) and truthy(r))
    of "or":
      if l.kind == gbvBool and l.flag:
        return GbValue(kind: gbvBool, flag: true)
      if r.kind == gbvBool and r.flag:
        return GbValue(kind: gbvBool, flag: true)
      if l.kind == gbvNull or r.kind == gbvNull:
        return GbValue(kind: gbvNull)
      GbValue(kind: gbvBool, flag: truthy(l) or truthy(r))
    of "=", "<>":
      if l.kind == gbvNull or r.kind == gbvNull:
        return GbValue(kind: gbvNull)
      var same = false
      if l.kind == gbvNumber and r.kind == gbvNumber:
        same = l.number == r.number
      elif l.kind == gbvString and r.kind == gbvString:
        same = l.text == r.text
      elif l.kind == gbvNode and r.kind == gbvNode:
        same = l.nodeId == r.nodeId
      elif l.kind == gbvNumber and r.kind == gbvNode:
        same = l.number == r.nodeId
      elif l.kind == gbvNode and r.kind == gbvNumber:
        same = l.nodeId == r.number
      else:
        ## Two different kinds are not equal, and never an error: the
        ## engine's rule (C8), inherited.
        same = false
      GbValue(kind: gbvBool, flag: (if e.op == "=": same else: not same))
    of "<", ">", "<=", ">=":
      if l.kind == gbvNull or r.kind == gbvNull:
        return GbValue(kind: gbvNull)
      var cmp = 0
      if l.kind == gbvNumber and r.kind == gbvNumber:
        cmp = (if l.number < r.number: -1 elif l.number > r.number: 1 else: 0)
      elif l.kind == gbvString and r.kind == gbvString:
        cmp = cmpIgnoreCase(l.text, r.text)
      else:
        exprFail("cannot compare " & $l.kind & " with " & $r.kind)
      case e.op
      of "<": GbValue(kind: gbvBool, flag: cmp < 0)
      of ">": GbValue(kind: gbvBool, flag: cmp > 0)
      of "<=": GbValue(kind: gbvBool, flag: cmp <= 0)
      else: GbValue(kind: gbvBool, flag: cmp >= 0)
    of "+":
      if l.kind == gbvString or r.kind == gbvString:
        GbValue(kind: gbvString, text: l.text & r.text)
      else:
        GbValue(kind: gbvNumber, number: l.number + r.number)
    of "-":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'-' needs two numbers")
      GbValue(kind: gbvNumber, number: l.number - r.number)
    of "*":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'*' needs two numbers")
      GbValue(kind: gbvNumber, number: l.number * r.number)
    of "/":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'/' needs two numbers")
      if r.number == 0:
        exprFail("division by zero")
      GbValue(kind: gbvNumber, number: l.number div r.number)
    else:
      exprFail("unknown operator '" & e.op & "'")

proc evalExpr*(names: Table[string, GbValue]; text: string): GbValue =
  ## Evaluate an expression against a session's names.
  eval(parseExpr(text), names)

proc condition*(names: Table[string, GbValue]; text: string): bool =
  ## An expression as a condition. A null condition is *false*: the
  ## engine's rule (C6) that null is not truthy, inherited so that the
  ## two languages cannot disagree about what "no" means.
  truthy(evalExpr(names, text))
