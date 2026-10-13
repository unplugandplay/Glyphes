## glyphes — the Cypher parser (CYPHER.md §§2–4)
##
## Recursive descent over one token of lookahead, which is all the read
## subset needs: every construct in §2–§4 either starts with a distinct
## keyword or is left-recursive in exactly one place (the relational chain),
## and the chain is a `while` loop rather than a recursive rule.
##
## **What "left-recursive in one place" buys.** `MATCH (a)-[r]->(b)-[s]->(c)`
## is a loop over elements, not a recursive rule, which means a path's
## length is bounded by a `while` and an attacker cannot blow the stack with
## a query of ten thousand hops. Cypher's grammar has no other unbounded
## left recursion, so the parser is iterative everywhere it can be.
##
## **Precedence**, lowest first, from `CYPHER.md` §2.3:
##
##   OR  <  XOR  <  AND  <  NOT  <  comparison  <  + -  <  * / %  <  ^  <  unary
##
## `^` binds tighter than `*` and looser than unary, which is the one that
## surprises people: `-2^2` is `-(2^2)`, and `-2 * 2` is `(-2) * 2`.
##
## **Out-of-contract constructs are not syntax errors.** `CREATE`, `MERGE`,
## `SET`, `DELETE`, `REMOVE`, `FOREACH`, `LOAD CSV` and `CALL {}` all
## lex and are recognised as clause keywords; they are then rejected with
## `GLY_ERR_UNSUPPORTED` naming the clause. PRD §5.1 requires exactly that
## — "every construct outside it returns a specific error naming the
## construct, never a wrong answer" — and a query that writes must fail at
## M4 loudly, not parse into a read plan that silently ignores it.
##
## Positions are carried from the lexer, so every error this file raises
## already says where.

import std/strutils
import ../store/prop
import ./errors
import ./lexer
import ./ast

type
  Parser = object
    toks: seq[Token]
    pos: int
    src: string

proc cur(p: Parser): Token {.inline.} =
  if p.pos < p.toks.len: p.toks[p.pos] else: p.toks[^1]

proc peekAt(p: Parser, ahead: int): Token {.inline.} =
  let i = p.pos + ahead
  if i < p.toks.len: p.toks[i] else: p.toks[^1]

proc advance(p: var Parser): Token {.inline.} =
  result = p.cur
  if p.pos < p.toks.len: inc p.pos

proc atEof(p: Parser): bool {.inline.} = p.cur.kind == tkEof

proc atSym(p: Parser, sym: string): bool {.inline.} =
  p.cur.kind == tkSym and p.cur.text == sym

proc atKw(p: Parser, kw: string): bool {.inline.} = p.cur.isKeyword(kw)

proc where(p: Parser): string =
  p.src & ":" & $p.cur.line & ":" & $p.cur.col

proc failHere(p: Parser, msg: string) {.noreturn.} =
  parseFail(p.where & ": " & msg & ", found " & p.cur.describe)

proc expectSym(p: var Parser, sym: string) =
  if not p.atSym(sym):
    p.failHere("expected '" & sym & "'")
  discard p.advance()

proc expectKw(p: var Parser, kw: string) =
  if not p.atKw(kw):
    p.failHere("expected " & kw)
  discard p.advance()

proc takeIdent(p: var Parser, what: string): string =
  if p.cur.kind != tkIdent:
    p.failHere("expected " & what)
  p.advance().text

proc takeString(p: var Parser, what: string): string =
  if p.cur.kind != tkString:
    p.failHere("expected " & what)
  p.advance().str

# ------------------------------------------------------------- expressions

proc parseExpr(p: var Parser): Expr
proc parsePattern(p: var Parser): Pattern

proc parsePrimary(p: var Parser): Expr =
  let t = p.cur
  case t.kind
  of tkInt:
    discard p.advance()
    result = lit Value(kind: vkInt, i: t.intNum)
    result.uval = t.uval
  of tkFloat:
    discard p.advance()
    result = lit Value(kind: vkFloat, f: t.num)
  of tkString:
    discard p.advance()
    result = lit Value(kind: vkString, s: t.str)
  of tkParam:
    discard p.advance()
    result = paramExpr t.text
  of tkSym:
    case t.text
    of "(":
      discard p.advance()
      ## `()` is an empty list, not an empty tuple: Cypher has no tuples.
      if p.atSym(")"):
        discard p.advance()
        return listExpr(@[])
      result = p.parseExpr()
      p.expectSym(")")
    of "[":
      discard p.advance()
      ## `[x IN list | ...]` is a comprehension. Parsed as a list literal it
      ## dies at IN with a bare syntax error; caught here it refuses with
      ## its name, which is pin C1's requirement and the difference between
      ## "unsupported" and "your query is broken".
      if p.cur.kind == tkIdent and isKeyword(p.toks[p.pos + 1], "in"):
        unsupported("list comprehension")
      var items: seq[Expr] = @[]
      if not p.atSym("]"):
        while true:
          items.add p.parseExpr()
          if p.atSym(","):
            discard p.advance()
            continue
          break
      p.expectSym("]")
      result = listExpr(items)
    of "{":
      ## A map literal in expression position; in a pattern it is a
      ## property filter, which is why the pattern parser calls its own
      ## routine rather than reusing this one.
      discard p.advance()
      var pairs: seq[PropEntry] = @[]
      if not p.atSym("}"):
        while true:
          ## A map key is an identifier or a string — `{name: $n}` is as
          ## legal as `{"name": $n}` in Cypher, and node/relationship
          ## property maps already take bare keys elsewhere in the grammar.
          let key =
            if p.cur.kind == tkString: p.takeString("a map key")
            elif p.cur.kind == tkIdent: p.advance().text
            else: p.takeString("a quoted map key")
          p.expectSym(":")
          pairs.add (key, p.parseExpr())
          if p.atSym(","):
            discard p.advance()
            continue
          break
      p.expectSym("}")
      result = mapExpr(pairs)
    else:
      p.failHere("expected an expression")
  of tkIdent:
    ## Keyword literals first, by comparison rather than by `case`: Nim's
    ## `case` does not dispatch on strings, and a `case` on an enum built
    ## from `cmpIgnoreCase` would need a keyword table that the lexer
    ## deliberately does not have.
    if cmpIgnoreCase(t.text, "true") == 0:
      discard p.advance()
      return lit Value(kind: vkBool, b: true)
    if cmpIgnoreCase(t.text, "false") == 0:
      discard p.advance()
      return lit Value(kind: vkBool, b: false)
    if cmpIgnoreCase(t.text, "null") == 0:
      discard p.advance()
      return litNull()
    ## Constructs the document pins (CYPHER.md C3 names CASE's null
    ## semantics) but the M4 slice does not evaluate. Named here rather
    ## than left to the "expected an expression" fall-through: a refusal
    ## must say what was refused, and a SQL error for a keyword the
    ## grammar recognises is the wrong diagnosis.
    for kw in ["case", "all", "any", "none", "single", "reduce",
               "shortestpath", "allshortestpaths"]:
      if cmpIgnoreCase(t.text, kw) == 0:
        unsupported(t.text)
    if cmpIgnoreCase(t.text, "exists") == 0:
      ## Both spellings — `exists { (n)-[:KNOWS]->() }` and the older
      ## `exists((n)...)`, plus property `exists(n.age)` — are refused
      ## here, at parse time. The evaluator has no subpattern planner to
      ## hand the pattern to (ops.nim fills nothing for ekExists), so
      ## accepting the parse would mean every exists() failing at eval
      ## with "no pattern bound", a message about the implementation
      ## rather than the query. Refusing by name is pin C1's rule; the
      ## Cypher spellings that survive the slice are `IS NULL` and a
      ## relationship property filter.
      unsupported("pattern EXISTS")
    discard p.advance()
    ## A function call is `name(`. Anything else is a variable — and
    ## `count` alone is a variable named count, not a function, which is
    ## why the paren is the discriminator and not the name.
    if p.atSym("("):
      discard p.advance()
      ## `count(*)` is the one call whose argument is not an expression.
      if p.atKw("distinct"):
        discard p.advance()
        if p.atSym("*"):
          discard p.advance()
          p.expectSym(")")
          return funcCall(t.text, @[countStar()], isDistinct = true)
        var dargs: seq[Expr] = @[]
        if not p.atSym(")"):
          while true:
            dargs.add p.parseExpr()
            if p.atSym(","):
              discard p.advance()
              continue
            break
        p.expectSym(")")
        return funcCall(t.text, dargs, isDistinct = true)
      if p.atSym("*"):
        discard p.advance()
        p.expectSym(")")
        return funcCall(t.text, @[countStar()])
      var args: seq[Expr] = @[]
      if not p.atSym(")"):
        while true:
          args.add p.parseExpr()
          if p.atSym(","):
            discard p.advance()
            continue
          break
      p.expectSym(")")
      return funcCall(t.text, args)
    result = varExpr t.text
  of tkEof:
    p.failHere("expected an expression")


proc parsePostfix(p: var Parser): Expr =
  result = p.parsePrimary()
  ## Property access and subscripting bind tightest, left-associatively.
  ## `a.b.c` is one expression, so this loop is also what makes a chain
  ## readable in the AST rather than a nest of two-argument nodes.
  while true:
    if p.atSym("."):
      discard p.advance()
      let key = p.takeIdent("a property name")
      result = propExpr(result, key)
    elif p.atSym("["):
      discard p.advance()
      let idx = p.parseExpr()
      p.expectSym("]")
      var e = new(Expr)
      e.kind = ekIndex
      e.target = result
      e.index = idx
      result = e
    else:
      break

proc foldNeg(e: Expr): Expr =
  ## Collapse `-<literal>` into the negated literal. Not an optimisation:
  ## it is what keeps `-9223372036854775808` representable, because folding
  ## it in the evaluator would mean going through a float and coming back
  ## with the wrong integer.
  ## Only a *number* collapses. Anything else becomes a unary node, which
  ## is the whole point: returning `e` unchanged here silently drops the
  ## minus from `-2^2`, because its operand is a binary rather than a
  ## literal.
  if e.kind == ekLit:
    case e.lit.kind
    of vkInt:
      if e.uval == (1'u64 shl 63):
        ## The magnitude is exactly one past the largest int64, so the only
        ## value it can belong to is the smallest int64.
        return lit Value(kind: vkInt, i: low(int64))
      return lit Value(kind: vkInt, i: -e.lit.i)
    of vkFloat:
      return lit Value(kind: vkFloat, f: -e.lit.f)
    else:
      discard
  unary("-", e)

proc parseUnary(p: var Parser): Expr =
  if p.atSym("-"):
    discard p.advance()
    ## Not folded here: `-2^2` must come out as `-(2^2)`, and folding the
    ## operand first turns it into `(-2)^2`. The fold happens in
    ## parsePower, once `^` has had its chance at the operand.
    return unary("-", p.parseUnary())
  if p.atSym("+"):
    discard p.advance()
    return p.parseUnary()
  p.parsePostfix()

proc parsePower(p: var Parser): Expr =
  ## Right-associative, and looser than unary so `-2^2` is `-(2^2)`.
  ##
  ## The sign is taken here rather than in `parseUnary` for exactly that
  ## reason: folding `-2` before `^` sees it would produce `(-2)^2`. The
  ## fold is applied at the end, and only when a minus was actually
  ## written — folding unconditionally negates every positive literal.
  let negative = p.atSym("-")
  if negative:
    discard p.advance()
  var base = p.parseUnary()
  if p.atSym("^"):
    discard p.advance()
    base = binary(ekBinary, "^", base, p.parsePower())
  if negative:
    base = foldNeg(base)
  base

proc parseMul(p: var Parser): Expr =
  var left = p.parsePower()
  while p.atSym("*") or p.atSym("/") or p.atSym("%"):
    let op = p.advance().text
    left = binary(ekBinary, op, left, p.parsePower())
  left

proc parseAdd(p: var Parser): Expr =
  var left = p.parseMul()
  while p.atSym("+") or p.atSym("-"):
    let op = p.advance().text
    left = binary(ekBinary, op, left, p.parseMul())
  left

proc parseComparison(p: var Parser): Expr =
  var left = p.parseAdd()
  while true:
    if p.cur.kind == tkSym and p.cur.text in ["=", "<>", "<", "<=", ">", ">="]:
      let op = p.advance().text
      left = binary(ekCompare, op, left, p.parseAdd())
    elif p.cur.kind == tkSym and p.cur.text == "=~":
      discard p.advance()
      left = binary(ekCompare, "=~", left, p.parseAdd())
    elif p.atKw("in"):
      discard p.advance()
      left = binary(ekCompare, "IN", left, p.parseAdd())
    elif p.atKw("contains"):
      discard p.advance()
      left = binary(ekCompare, "CONTAINS", left, p.parseAdd())
    elif p.atKw("starts"):
      discard p.advance()
      p.expectKw("with")
      left = binary(ekCompare, "STARTS WITH", left, p.parseAdd())
    elif p.atKw("ends"):
      discard p.advance()
      p.expectKw("with")
      left = binary(ekCompare, "ENDS WITH", left, p.parseAdd())
    elif p.atKw("is"):
      discard p.advance()
      var negated = false
      if p.atKw("not"):
        discard p.advance()
        negated = true
      p.expectKw("null")
      left = isNull(left, negated)
    else:
      break
  left

proc parseNot(p: var Parser): Expr =
  if p.atKw("not"):
    discard p.advance()
    var e = new(Expr)
    e.kind = ekNot
    e.target = p.parseNot()
    return e
  p.parseComparison()

proc parseAnd(p: var Parser): Expr =
  var left = p.parseNot()
  while p.atKw("and"):
    discard p.advance()
    left = binary(ekAnd, "AND", left, p.parseNot())
  left

proc parseXor(p: var Parser): Expr =
  var left = p.parseAnd()
  while p.atKw("xor"):
    discard p.advance()
    left = binary(ekXor, "XOR", left, p.parseAnd())
  left

proc parseExpr(p: var Parser): Expr =
  var left = p.parseXor()
  while p.atKw("or"):
    discard p.advance()
    left = binary(ekOr, "OR", left, p.parseXor())
  left

# ---------------------------------------------------------------- patterns

proc parsePropMap(p: var Parser): seq[PropEntry] =
  ## `{k: v, …}` in a pattern position. Keys may be bare identifiers as well
  ## as strings — `{name: 'x'}` is how everyone writes it, and requiring
  ## quotes would be a papercut with no semantic content.
  result = @[]
  if not p.atSym("{"):
    return
  discard p.advance()
  if p.atSym("}"):
    discard p.advance()
    return
  while true:
    var key: string
    if p.cur.kind == tkString:
      key = p.advance().str
    elif p.cur.kind == tkIdent:
      key = p.advance().text
    else:
      p.failHere("expected a property name")
    p.expectSym(":")
    result.add (key, p.parseExpr())
    if p.atSym(","):
      discard p.advance()
      continue
    break
  p.expectSym("}")

proc parseTypes(p: var Parser): seq[string] =
  ## `:KNOWS|SIMILAR_TO`, an alternation over relationship types.
  while true:
    result.add p.takeIdent("a relationship type")
    if p.atSym("|"):
      discard p.advance()
      if p.atSym(":"):
        discard p.advance()
      continue
    break

proc parseHops(p: var Parser, minHops, maxHops: var int) =
  ## `*`, `*2`, `*1..3`, `*2..`, `*..5`. A bare `*` is 1..∞, which is what
  ## openCypher means, and it is deliberately not bounded here: EXEC.md
  ## §2.2 expands it into one Expand per hop count, so an unbounded `*`
  ## expands lazily and `LIMIT 10` pulls ten hops.
  discard p.advance()          # '*'
  minHops = 1
  maxHops = 0                  # 0 = unbounded
  if p.cur.kind == tkInt:
    minHops = p.advance().intNum.int
    maxHops = minHops
  if p.atSym(".."):
    discard p.advance()
    if p.cur.kind == tkInt:
      maxHops = p.advance().intNum.int
    else:
      maxHops = 0
  if minHops < 1:
    p.failHere("variable length must start at 1 or more")
  if maxHops != 0 and maxHops < minHops:
    p.failHere("variable length upper bound is below its lower bound")

proc parseNodePattern(p: var Parser): NodePattern =
  result.line = p.cur.line
  result.col = p.cur.col
  p.expectSym("(")
  if p.cur.kind == tkIdent:
    result.varName = p.advance().text
  if p.atSym(":"):
    discard p.advance()
    result.label = p.takeIdent("a label")
    if p.atSym(":"):
      ## `(a:A:B)` needs a per-node label set in a fixed-size record, which
      ## STORAGE.md §2.1 does not have. CYPHER.md §5 rejects it and says why;
      ## saying so here beats a second colon parsing into silence.
      unsupported("a node pattern with more than one label (a:A:B)")
  result.props = p.parsePropMap()
  p.expectSym(")")

proc parseRelPattern(p: var Parser): RelPattern =
  result.line = p.cur.line
  result.col = p.cur.col
  ## Direction is decided by the *closing* symbol, not the opening one.
  ## `-[r]-` is undirected, `-[r]->` is outgoing and `<-[r]-` is incoming,
  ## so a parser that commits on seeing the opening `-` gets two of the
  ## three wrong — which is exactly what the first version did, returning
  ## `dirOut` for `MATCH (a)-[:KNOWS]-(b)`.
  let openedIn = p.atSym("<-")
  if openedIn or p.atSym("-"):
    discard p.advance()
  else:
    p.failHere("expected a relationship")

  if p.atSym("["):
    discard p.advance()
    if p.cur.kind == tkIdent:
      result.varName = p.advance().text
    if p.atSym(":"):
      discard p.advance()
      result.types = p.parseTypes()
    result.props = p.parsePropMap()
    if p.atSym("*"):
      var lo, hi: int
      p.parseHops(lo, hi)
      result.minHops = lo
      result.maxHops = hi
      ## Set even when the range is a single number: `*2..2` is a walk of two
      ## with relationship uniqueness, not a plain relationship, and the two
      ## are indistinguishable from min == max alone.
      result.varLen = true
    p.expectSym("]")

  if p.atSym("->"):
    discard p.advance()
    result.dir = dirOut
  elif p.atSym("<-"):
    discard p.advance()
    result.dir = dirIn
  elif p.atSym("-"):
    discard p.advance()
    ## `-[r]-` is undirected, but `<-[r]-` is an incoming relationship
    ## written with the arrow split across the bracket. Both are the same
    ## two symbols, and the opening one is the only thing that tells them
    ## apart.
    result.dir = if openedIn: dirIn else: dirBoth
  else:
    p.failHere("expected '-', '->' or '<-' after the relationship pattern")

proc parsePattern(p: var Parser): Pattern =
  ## A path is an element chain: node, (rel, node)*. The loop rather than
  ## recursion is what bounds the parser's stack on a long path.
  if p.cur.kind == tkIdent and p.peekAt(1).kind == tkSym and
     p.peekAt(1).text == "=" and not p.peekAt(1).isKeyword("="):
    result.pathVar = p.advance().text
    discard p.advance()
  var elems: seq[PatternElement] = @[]
  elems.add PatternElement(isNode: true, node: p.parseNodePattern())
  while p.atSym("-") or p.atSym("<-"):
    elems.add PatternElement(isNode: false, rel: p.parseRelPattern())
    elems.add PatternElement(isNode: true, node: p.parseNodePattern())
  result.elems = elems

# ----------------------------------------------------------------- clauses

proc parseProjection(p: var Parser, isWithClause: bool): QueryPart =
  ## Built through the constructor rather than by writing `kind` and then
  ## the branch's fields: Nim 2 raises a FieldDefect on a field write whose
  ## branch the discriminant has not selected, which makes the
  ## field-by-field form illegal for a variant object.
  result = QueryPart(kind: qpProjection, withClause: isWithClause,
                     projection: Projection(items: @[], isDistinct: false))
  if p.atKw("distinct"):
    discard p.advance()
    var proj = Projection(items: @[])
    proj.isDistinct = true
    while true:
      let e = p.parseExpr()
      var item = ReturnItem(expr: e)
      if p.atKw("as"):
        discard p.advance()
        item.alias = p.takeIdent("an alias")
      item.line = e.line
      item.col = e.col
      proj.items.add item
      if p.atSym(","):
        discard p.advance()
        continue
      break
    result.projection = proj
    return
  while true:
    let e = p.parseExpr()
    var item = ReturnItem(expr: e)
    if p.atKw("as"):
      discard p.advance()
      item.alias = p.takeIdent("an alias")
    item.line = e.line
    item.col = e.col
    result.projection.items.add item
    if p.atSym(","):
      discard p.advance()
      continue
    break

proc parseOrderBy(p: var Parser): SortSpec =
  while true:
    let e = p.parseExpr()
    var item = SortItem(expr: e, desc: false)
    if p.atKw("desc") or p.atKw("descending"):
      discard p.advance()
      item.desc = true
    elif p.atKw("asc") or p.atKw("ascending"):
      discard p.advance()
    result.items.add item
    if p.atSym(","):
      discard p.advance()
      continue
    break

proc parseTail(p: var Parser, q: Query) =
  ## ORDER BY / SKIP / LIMIT in any order after a projection. Cypher fixes
  ## the order, but accepting the permutations costs nothing and every one
  ## of them is a query someone has written.
  while true:
    if p.atKw("order"):
      discard p.advance()
      p.expectKw("by")
      q.addPart QueryPart(kind: qpOrderBy, sort: p.parseOrderBy())
    elif p.atKw("skip"):
      discard p.advance()
      q.addPart QueryPart(kind: qpSkip, skipAmount: p.parseExpr())
    elif p.atKw("limit"):
      discard p.advance()
      q.addPart QueryPart(kind: qpLimit, limitAmount: p.parseExpr())
    else:
      break

proc parseMatch(p: var Parser, q: Query, optional: bool) =
  var part = QueryPart(kind: qpMatch, optional: optional, patterns: @[])
  while true:
    part.patterns.add p.parsePattern()
    if p.atSym(","):
      discard p.advance()
      continue
    break
  if p.atKw("where"):
    discard p.advance()
    part.matchCond = p.parseExpr()
  q.addPart(part)

proc parseCreate(p: var Parser, q: Query) =
  ## `CREATE` takes one or more comma-separated patterns and nothing else:
  ## no WHERE, no alias. The pattern grammar is MATCH's — the difference
  ## is semantic (write, not filter) and lives in the planner.
  var part = QueryPart(kind: qpCreate, createPatterns: @[])
  while true:
    part.createPatterns.add p.parsePattern()
    if p.atSym(","):
      discard p.advance()
      continue
    break
  q.addPart(part)

proc parsePropRef(p: var Parser): PropRef =
  ## A write target: a variable, a dot, and one property name.
  ## `a.x.y` is refused here rather than walked — setting a property *of a
  ## map-valued property* is a different operation with different rules
  ## (CYPHER.md §5's `SET a.m.k` is an M5.5 refusal), and silently
  ## applying the last segment would write the wrong thing.
  result.varName = p.takeIdent("a variable")
  p.expectSym(".")
  result.key = p.takeIdent("a property name")
  if p.atSym("."):
    p.failHere("nested property writes (SET a.m.k) are not supported yet")

proc parseSet(p: var Parser, q: Query) =
  ## `SET a.x = 1, b.y = 2` and the map forms `SET a = {…}` / `SET a += {…}`.
  ## One part, one operator: the assignments apply per row, in the order
  ## written.
  ##
  ## The grammar is a decision tree on what follows the variable name, not a
  ## fixed shape: `+=` is a merge, `=` on a map is a replace, `=` on
  ## anything else is a replace Cypher will reject as a type error, and a
  ## dot is a property assignment. Reading the target as a property path
  ## first and backtracking was the first version, and it refused `SET n +=
  ## {…}` for "expected '.', found '+'" — the grammar is not "a path with an
  ## optional suffix", it is four distinct shapes.
  var part = QueryPart(kind: qpSet, setItems: @[])
  while true:
    var item = SetItem()
    if p.cur.kind == tkIdent and p.peekAt(1).kind == tkSym and
       p.peekAt(1).text == ":":
      p.failHere("SET n:Label — a node carries one label (pin C13)")
    let varName = p.takeIdent("a variable")
    if p.atSym("+="):
      discard p.advance()
      item.isMap = true
      item.merge = true
      item.target = PropRef(varName: varName, key: "")
      item.mapValue = p.parseExpr()
    elif p.atSym("="):
      discard p.advance()
      let e = p.parseExpr()
      if e.kind != ekMap:
        ## `SET n = 3` is a type error in Cypher, and it is caught at the
        ## operator with a message about maps rather than here — the parser
        ## accepts the shape and the evaluator explains the type.
        p.failHere("SET " & varName & " = … needs a map; use SET " & varName & ".key = …")
      item.isMap = true
      item.merge = false
      item.target = PropRef(varName: varName, key: "")
      item.mapValue = e
    else:
      p.expectSym(".")
      item.target = PropRef(varName: varName, key: p.takeIdent("a property name"))
      if p.atSym("."):
        p.failHere("nested property writes (SET a.m.k) are not supported yet")
      p.expectSym("=")
      item.expr = p.parseExpr()
    part.setItems.add item
    if p.atSym(","):
      discard p.advance()
      continue
    break
  q.addPart(part)

proc parseRemove(p: var Parser, q: Query) =
  var part = QueryPart(kind: qpRemove, removeItems: @[])
  while true:
    if p.cur.kind == tkIdent and p.peekAt(1).kind == tkSym and
       p.peekAt(1).text == ":":
      ## `REMOVE n:Label`. Refused: one label per node (pin C13), so there
      ## is no label to remove, and saying so is better than accepting the
      ## parse and quietly doing nothing.
      p.failHere("REMOVE n:Label — a node carries one label (pin C13)")
    part.removeItems.add p.parsePropRef()
    if p.atSym(","):
      discard p.advance()
      continue
    break
  q.addPart(part)

proc parseDelete(p: var Parser, q: Query, detach: bool) =
  var part = QueryPart(kind: qpDelete, deleteVars: @[], detach: detach)
  while true:
    part.deleteVars.add p.takeIdent("a variable to delete")
    if p.atSym(","):
      discard p.advance()
      continue
    break
  q.addPart(part)

proc parseMerge(p: var Parser, q: Query) =
  ## `MERGE` is `CREATE`'s pattern grammar plus the two action clauses.
  ## `ON CREATE`/`ON MATCH` each take a SET or a REMOVE list — the same
  ## parsers, because they are the same clause with a condition attached.
  var part = QueryPart(kind: qpMerge, mergePatterns: @[], onCreateSet: @[],
                      onCreateRemove: @[], onMatchSet: @[], onMatchRemove: @[])
  while true:
    part.mergePatterns.add p.parsePattern()
    if p.atSym(","):
      discard p.advance()
      continue
    break
  while p.atKw("on"):
    discard p.advance()
    var onCreate = false
    if p.atKw("create"):
      onCreate = true
      discard p.advance()
    elif p.atKw("match"):
      discard p.advance()
    else:
      p.failHere("expected ON CREATE or ON MATCH")
    if p.atKw("set"):
      discard p.advance()
      ## Reuse the SET item parser by parsing the list through the same
      ## shape, without the keyword. `p.parseSet` builds a part; this needs
      ## the items, so the list loop is spelled here rather than threaded
      ## through a parameter.
      while true:
        var item = SetItem()
        let varName = p.takeIdent("a variable")
        if p.atSym("+="):
          discard p.advance()
          item.isMap = true
          item.merge = true
          item.target = PropRef(varName: varName, key: "")
          item.mapValue = p.parseExpr()
        elif p.atSym("="):
          discard p.advance()
          let e = p.parseExpr()
          if e.kind != ekMap:
            p.failHere("SET " & varName & " = … needs a map; use SET " & varName & ".key = …")
          item.isMap = true
          item.target = PropRef(varName: varName, key: "")
          item.mapValue = e
        else:
          p.expectSym(".")
          item.target = PropRef(varName: varName, key: p.takeIdent("a property name"))
          if p.atSym("."):
            p.failHere("nested property writes (SET a.m.k) are not supported yet")
          p.expectSym("=")
          item.expr = p.parseExpr()
        if onCreate: part.onCreateSet.add item
        else: part.onMatchSet.add item
        if p.atSym(","):
          discard p.advance()
          continue
        break
    elif p.atKw("remove"):
      discard p.advance()
      while true:
        let target = p.parsePropRef()
        if onCreate: part.onCreateRemove.add target
        else: part.onMatchRemove.add target
        if p.atSym(","):
          discard p.advance()
          continue
        break
    else:
      p.failHere("expected SET or REMOVE after ON CREATE / ON MATCH")
  q.addPart(part)

proc atRefusalKeyword*(p: Parser): bool =
  ## True when the current token is a construct §5 refuses by name. Those
  ## must keep their named refusal even after a RETURN; everything else
  ## after a RETURN is a syntax error naming the rule.
  for kw in ["union", "call", "create", "merge", "set", "delete", "remove",
             "detach", "foreach", "load", "optional", "on"]:
    if isKeyword(p.cur, kw):
      return true
  false

proc rejectWrite(q: Query, tok: Token) {.noreturn.} =
  ## Every write clause is recognised so the error names it. Landing here
  ## means the query is valid Cypher that glyphes 0.1 does not evaluate, and
  ## saying so is PRD §5.1's requirement — a write query must not parse into
  ## a read plan that quietly drops the writes.
  ##
  ## `CREATE` left this list at M5.1: it is the first write the engine
  ## actually evaluates, so refusing it would refuse the milestone's own
  ## unlock.
  if cmpIgnoreCase(tok.text, "union") == 0 or cmpIgnoreCase(tok.text, "call") == 0:
    ## Not writes: naming them "write queries" would point the caller at
    ## the wrong milestone for a read-side feature.
    unsupported(tok.text & " (multi-query composition lands after M4)")
  else:
    unsupported(tok.text & " (write queries land at M5)")

proc parseTextCall(p: var Parser, q: Query) =
  ## `CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score` — the whole
  ## M6.2 retrieval surface, and the only `CALL` this slice evaluates.
  ## Everything else spelled with `CALL` keeps a named refusal: an unknown
  ## procedure, the vector family (M6.3), a subquery, `IN TRANSACTIONS`.
  ## A blanket refusal would be simpler and wrong — the refusal is the
  ## milestone's door, not the keyword's.
  discard p.advance()                     ## CALL
  if p.atSym("{"):
    unsupported("a CALL subquery (CALL { … })")
  if p.cur.kind != tkIdent:
    p.failHere("expected a procedure name after CALL")
  var procName = p.advance().text
  while p.atSym("."):
    discard p.advance()
    if p.cur.kind != tkIdent:
      p.failHere("expected a procedure name after '.'")
    procName.add "." & p.advance().text
  if p.atKw("in"):
    unsupported("CALL … IN TRANSACTIONS")
  var isVec = false
  if procName == "db.idx.text":
    discard
  elif procName == "db.idx.vector":
    ## M6.3: the vector family rides the same retrieval shape — AGAINST a
    ## vector, YIELD doc and score. One clause, two families, because the
    ## query grammar should not grow a second spelling for the second
    ## index type.
    isVec = true
  else:
    ## Named, because "unsupported: CALL" would point a caller who
    ## misspelled a procedure at the wrong fix.
    unsupported("unknown procedure " & procName)
  p.expectSym("(")
  let indexName = p.takeString("an index name, quoted: db.idx.text('Doc.body')")
  p.expectSym(")")
  p.expectKw("against")
  let qe = p.parseExpr()
  ## The query is data — a parameter, a string literal (text) or a list of
  ## number literals (vector). An expression would have to be evaluated
  ## per row, and a retrieval is a source: there are no rows yet to
  ## evaluate it against.
  var listOk = false
  if qe.kind == ekList:
    listOk = qe.items.len > 0
    for item in qe.items:
      if item.kind != ekLit or (item.lit.kind != vkInt and
                                item.lit.kind != vkFloat):
        listOk = false
  if qe.kind != ekParam and
     not (qe.kind == ekLit and qe.lit.kind == vkString) and
     not listOk:
    unsupported("AGAINST needs a parameter, a string literal or a list of " &
                "numbers, got " &
                (if qe.kind == ekVar: qe.name else: "an expression"))
  p.expectKw("yield")
  let nodeVar = p.takeIdent("a variable to yield the document into")
  var scoreVar = ""
  if p.atSym(","):
    discard p.advance()
    scoreVar = p.takeIdent("a variable to yield the score into")
  q.addPart QueryPart(kind: qpTextCall, indexName: indexName,
                      queryExpr: qe, yieldNode: nodeVar, yieldScore: scoreVar,
                      isVec: isVec)

proc parseQuery*(src: string): Query =
  ## Parse a whole query. Raises `CypherError`; never returns a partial tree,
  ## because a partial tree is how a rejected query becomes a wrong answer.
  var p = Parser(toks: tokenize(src), pos: 0, src: src)
  result = newQuery(src)
  if p.atEof:
    parseFail(p.where & ": the query is empty")
  ## A RETURN ends the query: after its tail, nothing may follow. The old
  ## loop just kept parsing, so `RETURN 1 AS a UNWIND [2] AS b RETURN b`
  ## executed *both* projections and answered the second — the first
  ## computed and thrown away, a wrong answer with the shape of a right
  ## one. The refusal keywords stay reachable through the fall-through set
  ## below: `RETURN a CREATE (:X)` is a named write refusal (§5) wherever
  ## it appears, not a syntax error.
  var sawReturn = false
  while not p.atEof:
    if sawReturn and not p.atRefusalKeyword():
      p.failHere("only ORDER BY, SKIP and LIMIT may follow RETURN")
    if p.atKw("match"):
      discard p.advance()
      p.parseMatch(result, false)
    elif p.atKw("optional"):
      discard p.advance()
      p.expectKw("match")
      p.parseMatch(result, true)
    elif p.atKw("where"):
      ## A bare WHERE with no MATCH before it is legal in a WITH-led query
      ## only after a projection; a leading one has nothing to filter.
      discard p.advance()
      result.addPart QueryPart(kind: qpWhere, cond: p.parseExpr())
    elif p.atKw("return"):
      discard p.advance()
      result.addPart(p.parseProjection(false))
      p.parseTail(result)
      sawReturn = true
    elif p.atKw("with"):
      discard p.advance()
      result.addPart(p.parseProjection(true))
      if p.atKw("where"):
        discard p.advance()
        result.addPart QueryPart(kind: qpWhere, cond: p.parseExpr())
      p.parseTail(result)
    elif p.atKw("unwind"):
      discard p.advance()
      let list = p.parseExpr()
      p.expectKw("as")
      result.addPart QueryPart(kind: qpUnwind, list: list,
                              varName: p.takeIdent("a variable"))
    elif p.atKw("create"):
      discard p.advance()
      p.parseCreate(result)
    elif p.atKw("set"):
      discard p.advance()
      p.parseSet(result)
    elif p.atKw("remove"):
      discard p.advance()
      p.parseRemove(result)
    elif p.atKw("delete"):
      discard p.advance()
      p.parseDelete(result, false)
    elif p.atKw("detach"):
      ## `DETACH` is only ever `DETACH DELETE` in this slice; a bare DETACH
      ## is a syntax error rather than a guess.
      discard p.advance()
      p.expectKw("delete")
      p.parseDelete(result, true)
    elif p.atKw("merge"):
      discard p.advance()
      p.parseMerge(result)
    elif p.atKw("foreach") or p.atKw("load") or p.atKw("union"):
      rejectWrite(result, p.cur)
    elif p.atKw("call"):
      p.parseTextCall(result)
    else:
      p.failHere("expected MATCH, RETURN, WITH, UNWIND, WHERE or OPTIONAL MATCH")

# -------------------------------------------------------------- rendering

proc render*(e: Expr): string =
  ## A one-line rendering of an expression, for error messages ("cannot use
  ## X in this position") and for `columns` names. Deliberately not a
  ## round-trippable pretty-printer: it only has to be unambiguous enough to
  ## read in a message.
  case e.kind
  of ekLit:
    case e.lit.kind
    of vkNull: "null"
    of vkBool: (if e.lit.b: "true" else: "false")
    of vkInt: $e.lit.i
    of vkFloat: $e.lit.f
    of vkString, vkBytes: "'" & e.lit.s & "'"
    of vkVector: "vector[" & $e.lit.dims.len & "]"
    of vkList: "[" & $e.lit.items.len & " elements]"
    of vkMap: "{" & $e.pairs.len & " keys}"
    of vkNode: "node " & $e.lit.id
    of vkEdge: "edge " & $e.lit.id
    of vkPath: "path " & $e.lit.path.nodes.len & " nodes"
  of ekVar: e.name
  of ekParam: "$" & e.name
  of ekProp: render(e.target) & "." & e.name
  of ekIndex: render(e.target) & "[" & render(e.index) & "]"
  of ekUnary: e.op & render(e.target)
  of ekBinary, ekCompare: render(e.items[0]) & " " & e.op & " " & render(e.items[1])
  of ekAnd, ekOr, ekXor: render(e.items[0]) & " " & e.op & " " & render(e.items[1])
  of ekNot: "NOT " & render(e.target)
  of ekIsNull: render(e.target) & (if e.negated: " IS NOT NULL" else: " IS NULL")
  of ekList: "[" & $e.items.len & " elements]"
  of ekMap: "{" & $e.pairs.len & " keys}"
  of ekFunc:
    var args: seq[string] = @[]
    for a in e.items: args.add render(a)
    e.name & "(" & (if e.isDistinct: "DISTINCT " else: "") & args.join(", ") & ")"
  of ekExists: "EXISTS { ... }"
  of ekCountStar: "*"

proc render*(p: Pattern): string =
  for i, e in p.elems:
    if e.isNode:
      result.add "(" & e.node.varName & (if e.node.label.len > 0: ":" & e.node.label else: "") & ")"
    else:
      result.add "-[" & e.rel.varName & (if e.rel.types.len > 0: ":" & e.rel.types.join("|") else: "") & "]->"