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
## Two names belong to the language rather than to the session: `first`
## and `last` pick the two ends of the cursor (pin GB2 — the prompt
## sketch's `p = first`). A name the session *holds* wins, so a `let
## first = 5` still reads back as 5, and the same rule runs on the
## guest.
##
## `null` is a value like any other, and it is not true: a comparison
## with null gives null, and null is not a condition. That is the
## engine's three-valued logic (CYPHER.md §6), inherited because a
## language that treats null as false teaches the wrong thing quietly.
## The client has no `null` literal to write; the rule is the session's
## to keep if a null ever reaches it.

import std/[strutils, tables]
import ./gbasic_types

type
  GbExprError* = object of CatchableError
    ## A refusal in an expression, naming the piece that was wrong.

proc exprFail(msg: string) {.noreturn.} =
  raise newException(GbExprError, "glyph basic: " & msg)

# ------------------------------------------------- checked 64-bit arithmetic
#
# The client's numbers are i64 (pin GB7), and *every* arithmetic edge
# refuses rather than overflows: an overflow is a Defect, and pin GB6
# says a bad line names itself and never crashes. The checks are
# written without doing the sum, so they answer the same whether or
# not the compiler's own overflow checks are switched on.

proc overAdd*(a, b: int64): bool {.inline.} =
  (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b)

proc overSub*(a, b: int64): bool {.inline.} =
  (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b)

proc overMul*(a, b: int64): bool =
  if a == 0 or b == 0: false
  elif a > 0:
    if b > 0: a > high(int64) div b
    else: b < low(int64) div a
  else:
    if b > 0: a < low(int64) div b
    else: a < high(int64) div b

proc overNeg(a: int64): bool {.inline.} =
  a == low(int64)

proc parseDigits(t: string): int64 =
  ## An all-digit token as a number, refusing a token that will not
  ## fit — the biggest number the language can hold is a fact about the
  ## language, and a token past it is a refusal rather than a wrap.
  var n: int64 = 0
  for ch in t:
    let d = ord(ch) - ord('0')
    if n > (high(int64) - d) div 10:
      exprFail("the number '" & t & "' is too big to hold")
    n = n * 10 + d
  n

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
  ## The expression's words. A quoted string is one word, and a
  ## comparison operator of two characters is one word too: `a <> b`
  ## is three tokens, not four (the parser has always had the operator;
  ## the lexer used to hand it the two halves).
  var cur = ""
  var inStr = false
  var i = 0
  while i < src.len:
    let ch = src[i]
    if ch == '"':
      inStr = not inStr
      cur.add ch
    elif not inStr and (isSpace(ch) or ch in {'=', '<', '>', '+', '-', '*', '/',
                                            '(', ')', ','}):
      if cur.len > 0:
        result.add cur
        cur = ""
      if not isSpace(ch):
        var op = $ch
        if i + 1 < src.len:
          let two = ch & src[i + 1]
          if two in ["<=", ">=", "<>"]:
            op = two
            inc i
        result.add op
    else:
      cur.add ch
    inc i
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
  var allDigits = t.len > 0
  for ch in t:
    if ch notin {'0'..'9'}:
      allDigits = false
  if allDigits:
    return Expr(kind: ekNum, num: parseDigits(t))
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

proc eval(e: Expr; names: Table[string, GbValue];
          cursor: seq[int64]): GbValue =
  case e.kind
  of ekNum: GbValue(kind: gbvNumber, number: e.num)
  of ekStr: GbValue(kind: gbvString, text: e.text)
  of ekName:
    ## The session's names first — a name may hold any value, including
    ## one bound to `first` itself — and then the two words that pick
    ## from the cursor (pin GB2). `show first` is the same rule in the
    ## client's `nodeOf`.
    if names.hasKey(e.text):
      names[e.text]
    elif e.text == "first" or e.text == "last":
      if cursor.len == 0:
        exprFail("the cursor is empty")
      GbValue(kind: gbvNumber,
              number: (if e.text == "first": cursor[0] else: cursor[^1]))
    else:
      exprFail("no such name '" & e.text & "'")
  of ekNeg:
    let v = eval(e.left, names, cursor)
    case v.kind
    of gbvNumber:
      if overNeg(v.number):
        exprFail("the result is too big to hold")
      GbValue(kind: gbvNumber, number: -v.number)
    else: exprFail("'-' needs a number")
  of ekNot:
    let v = eval(e.left, names, cursor)
    GbValue(kind: gbvBool, flag: not truthy(v))
  of ekBin:
    let l = eval(e.left, names, cursor)
    let r = eval(e.right, names, cursor)
    case e.op
    of "and":
      ## Eager, as the guest's evaluator is, and three-valued: false
      ## and null is false, and the other combinations are null.
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
      elif l.kind == gbvBool and r.kind == gbvBool:
        same = l.flag == r.flag
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
      ## Two strings concatenate; two numbers add; anything else — a
      ## text against a number, a yes/no, a node, null — is refused by
      ## name. The mixed case used to read the *wrong* union member:
      ## `l.number` on a yes/no is not a number, it is whichever byte
      ## the object happened to hold, and a language that answers with
      ## garbage (or crashes, pin GB6) is worse than one that refuses.
      if l.kind == gbvString and r.kind == gbvString:
        GbValue(kind: gbvString, text: l.text & r.text)
      elif l.kind == gbvNumber and r.kind == gbvNumber:
        if overAdd(l.number, r.number):
          exprFail("the result is too big to hold")
        GbValue(kind: gbvNumber, number: l.number + r.number)
      else:
        exprFail("'+' needs two strings or two numbers")
    of "-":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'-' needs two numbers")
      if overSub(l.number, r.number):
        exprFail("the result is too big to hold")
      GbValue(kind: gbvNumber, number: l.number - r.number)
    of "*":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'*' needs two numbers")
      if overMul(l.number, r.number):
        exprFail("the result is too big to hold")
      GbValue(kind: gbvNumber, number: l.number * r.number)
    of "/":
      if l.kind != gbvNumber or r.kind != gbvNumber:
        exprFail("'/' needs two numbers")
      if r.number == 0:
        exprFail("division by zero")
      if l.number == low(int64) and r.number == -1:
        exprFail("the result is too big to hold")
      GbValue(kind: gbvNumber, number: l.number div r.number)
    else:
      exprFail("unknown operator '" & e.op & "'")

proc evalExpr*(names: Table[string, GbValue]; text: string;
               cursor: seq[int64] = @[]): GbValue =
  ## Evaluate an expression against a session's names — and, for the
  ## two names that pick from it, against the cursor (pin GB2).
  eval(parseExpr(text), names, cursor)

proc condition*(names: Table[string, GbValue]; text: string;
                cursor: seq[int64] = @[]): bool =
  ## An expression as a condition. A null condition is *false*: the
  ## engine's rule (C6) that null is not truthy, inherited so that the
  ## two languages cannot disagree about what "no" means.
  truthy(evalExpr(names, text))
