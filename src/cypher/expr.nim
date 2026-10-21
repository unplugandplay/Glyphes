## glyphes — expression evaluation (CYPHER.md §2.3)
##
## The whole reason this file is careful is that Cypher's booleans are
## three-valued and every language it borrows syntax from has two. The three
## rules, stated once so the rest of the file can be read as mechanical:
##
##   1. **`null` is not `false`.** A comparison with `null` yields `null`,
##      and `null` is not truthy, so `WHERE n.nickname = 'ana'` excludes the
##      nodes whose `nickname` is null. This is the single most common
##      source of confusion in Cypher and it is pinned.
##   2. **AND/OR are three-valued.** `null AND false` is `false`;
##      `null OR true` is `true`. Short-circuiting may only skip work when
##      the answer cannot change — `false AND x` is `false` whatever `x` is.
##   3. **A missing binding is `null`, not an error.** `a.name` where `a` has
##      no `name` property is null. The *variable* being unknown is an error,
##      and the semantic pass catches that at prepare time.
##
## Arithmetic promotes int to float rather than the other way round: an
## integer division that silently produced a float would be a wrong answer
## for a count, and one that truncated would be a wrong answer for money.

## `=~` needs the standard library's `re`, which is in `lib/impure`
## because it wraps PCRE. That is a second ABI dependency (the
## engine links pcre) and CYPHER.md §2.3 specifies RE2 syntax, so
## this is the one place where glyphes' regex behaviour is Nim's
## rather than openCypher's. Recorded rather than hidden: a
## pattern that means one thing in the TCK and another here is a
## bug report waiting for a name.
import std/[algorithm, math, sets, strutils, math, tables]
import re
import ../abi
import ../store/store
import ../store/prop
import ./errors
import ./ast
import ./ast
import ./ctx

type
  Eval* = object
    ## Per-statement evaluation state. Parameters only: the row and the
    ## context are passed explicitly so an operator cannot accidentally
    ## read a different statement's row.
    ctx*: QueryCtx
    row*: Row
    ## Set by `EXISTS { … }`, which evaluates a pattern against the row's
    ## current bindings rather than from a fresh scan.
    depth*: int

proc typeName*(v: Value): string =
  ## The type's name, in one place. The refusal messages, `typeof()`, and
  ## the contract in CYPHER.md §6 all use these words, so a caller can
  ## match on them and a new type is a case here rather than a string in
  ## every operator.
  case v.kind
  of vkNull: "NULL"
  of vkBool: "BOOLEAN"
  of vkInt: "INTEGER"
  of vkFloat: "FLOAT"
  of vkString: "STRING"
  of vkBytes: "BYTES"
  of vkVector: "VECTOR"
  of vkList: "LIST"
  of vkMap: "MAP"
  of vkNode: "NODE"
  of vkEdge: "RELATIONSHIP"
  of vkPath: "PATH"
  of vkDate: "DATE"

proc typeOfValue*(ctx: QueryCtx; v: Value): string =
  ## `typeof()`'s answer. A node's **label** is its type and a
  ## relationship's **type name** is its type — pin C13, one label per
  ## node — and the structural names above are the fallback for a node or
  ## an edge whose type cannot be read (dead, or unlabelled).
  case v.kind
  of vkNode:
    let l = labelOfNode(ctx, v.id)
    (if l.len > 0: l else: "NODE")
  of vkEdge:
    let t = typeOfEdge(ctx, v.id)
    (if t.len > 0: t else: "RELATIONSHIP")
  else:
    typeName(v)

const
  MaxEvalDepth* = 64
  ## Guards `EXISTS { EXISTS { … } }` and a pathological map/list nesting.
  ## A query that exceeds it gets a named error rather than a stack
  ## overflow inside the host process.

proc eval*(e: Eval, expr: Expr): Value {.gcsafe.}

proc evaluate*(ctx: QueryCtx, row: Row, expr: Expr): Value
  ## Folds an argument once per row; the aggregates below are the first
  ## caller that needs it outside the evaluator itself.

proc truthy(v: Value): bool {.inline.} =
  ## Cypher: only `true` is true. Not `v.b`, not "not null".
  v.kind == vkBool and v.b

proc numOf(v: Value, dest: var float64): bool =
  ## Numeric extraction with int→float promotion. `out` is a float even for
  ## an integer input, and callers that need the int-ness check `v.kind`.
  case v.kind
  of vkInt:
    dest = float64(v.i)
    true
  of vkFloat:
    dest = v.f
    true
  else:
    false

proc intOf(v: Value, dest: var int64): bool =
  case v.kind
  of vkInt:
    dest = v.i
    true
  of vkFloat:
    ## Only an exactly integral float converts. `toInteger(2.5)` is an error
    ## in Cypher, and rounding here would make `WHERE n = 2` match 2.5.
    if v.f == floor(v.f) and v.f >= -9.2e18 and v.f <= 9.2e18:
      dest = int64(v.f)
      true
    else:
      false
  else:
    false

# ------------------------------------------------------------- comparisons

proc compareValues(a, b: Value): (int, bool) =
  ## `(ordering, comparable)`. Numbers compare across int/float; strings
  ## compare bytewise, which is what openCypher does for `<` on strings;
  ## booleans order false < true. Anything else — a node against a number,
  ## null against anything — is not comparable, and the caller turns that
  ## into `null` rather than false, per rule 1.
  if a.kind == vkNull or b.kind == vkNull:
    return (0, false)
  if a.kind in {vkInt, vkFloat} and b.kind in {vkInt, vkFloat}:
    ## Exact when both sides are integers. Routing every comparison through
    ## a float64 loses the low bits above 2^53, and
    ## `9007199254740993 > 9007199254740992` — two ids apart by one —
    ## answered false. The promotion stays for mixed int/float, where a
    ## common space is the only option.
    if a.kind == vkInt and b.kind == vkInt:
      return (cmp(a.i, b.i), true)
    var x, y: float64
    discard numOf(a, x)
    discard numOf(b, y)
    let ord = (if x < y: -1 elif x > y: 1 else: 0)
    return (ord, true)
  if a.kind == vkDate and b.kind == vkDate:
    return (cmp(a.d, b.d), true)
  if a.kind in {vkString, vkBytes} and b.kind in {vkString, vkBytes}:
    return (cmp(a.s, b.s), true)
  if a.kind == vkBool and b.kind == vkBool:
    return (cmp(a.b, b.b), true)
  (0, false)

proc toCypherString(v: Value): string =
  ## The rendering `toString()` and string `+` share. Bools and nulls render
  ## as Cypher spells them, not as Nim does.
  case v.kind
  of vkNull: "null"
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: $v.f
  of vkString, vkBytes: v.s
  of vkDate: dateText(v.d)
  else: ""

proc logicFail(op: string, l, r: Value) {.noreturn.} =
  cypherFail(int32(glyErrSql),
    op & " needs two booleans, not " & typeName(l) & " and " & typeName(r))

proc logicFailUnary(op: string, v: Value) {.noreturn.} =
  cypherFail(int32(glyErrSql),
    op & " needs a boolean, not " & typeName(v))

proc eqValues*(a, b: Value): Value =
  if a.kind == vkNull or b.kind == vkNull:
    return Value(kind: vkNull)
  ## CYPHER.md C5/C8: int and float are never `=`. An int and a float that
  ## hold the same number are different types with different semantics
  ## (overflow, precision), and `3.0 = 3` answering true is how a boundary
  ## bug hides inside a WHERE. Cross-kind equality is false, same as any
  ## other kind mismatch; only ordering (cmpValues) mixes them, because a
  ## sort needs a total order and equality does not.
  if a.kind != b.kind:
    return Value(kind: vkBool, b: false)
  case a.kind
  of vkNull: Value(kind: vkNull)
  of vkInt, vkFloat:
    ## Same-kind numbers compare by value. This arm used to be unreachable
    ## (the cross-kind numeric branch returned first); since C5 made
    ## int/float equality cross-kind-false, same-kind equality lands here,
    ## which is exactly why the arm exists instead of a dead `false`.
    if a.kind == vkInt:
      Value(kind: vkBool, b: a.i == b.i)
    else:
      Value(kind: vkBool, b: a.f == b.f)
  of vkBool: Value(kind: vkBool, b: a.b == b.b)
  of vkString, vkBytes: Value(kind: vkBool, b: a.s == b.s)
  of vkDate: Value(kind: vkBool, b: a.d == b.d)
  of vkList:
    if a.items.len != b.items.len:
      return Value(kind: vkBool, b: false)
    for i in 0 ..< a.items.len:
      let r = eqValues(a.items[i], b.items[i])
      if r.kind == vkNull or not r.b:
        return Value(kind: vkBool, b: false)
    Value(kind: vkBool, b: true)
  of vkMap:
    if a.pairs.len != b.pairs.len:
      return Value(kind: vkBool, b: false)
    for (k, v) in a.pairs:
      var other: Value
      var found = false
      for (k2, v2) in b.pairs:
        if k == k2:
          other = v2
          found = true
          break
      if not found:
        return Value(kind: vkBool, b: false)
      let r = eqValues(v, other)
      if r.kind == vkNull or not r.b:
        return Value(kind: vkBool, b: false)
    Value(kind: vkBool, b: true)
  of vkNode, vkEdge: Value(kind: vkBool, b: a.id == b.id)
  of vkPath:
    if a.path.nodes.len != b.path.nodes.len:
      return Value(kind: vkBool, b: false)
    for i in 0 ..< a.path.nodes.len:
      if a.path.nodes[i] != b.path.nodes[i]:
        return Value(kind: vkBool, b: false)
    Value(kind: vkBool, b: true)
  of vkVector:
    if a.dims.len != b.dims.len:
      return Value(kind: vkBool, b: false)
    for i in 0 ..< a.dims.len:
      if a.dims[i] != b.dims[i]:
        return Value(kind: vkBool, b: false)
    Value(kind: vkBool, b: true)

# ------------------------------------------------------------- accessors

proc propertyOf(ctx: QueryCtx, target: Value, key: string): Value {.gcsafe.} =
  ## A **date** answers its components here rather than in a function:
  ## `d.year` is not a stored key of anything, and looking it up in the
  ## property dictionary would answer null for every date — the shape of
  ## bug that reads as "the property is missing" rather than "the type is
  ## not what you think".
  if target.kind == vkDate:
    let (y, m, d) = civilOf(target.d)
    case key
    of "year": return Value(kind: vkInt, i: int64(y))
    of "month": return Value(kind: vkInt, i: int64(m))
    of "day": return Value(kind: vkInt, i: int64(d))
    else:
      cypherFail(int32(glyErrSql),
        "a date has year, month and day, not '" & key & "'")
  case target.kind
  of vkNode:
    var v: Value
    if ctx.readNodeProp(target.id, key, v): v else: Value(kind: vkNull)
  of vkEdge:
    var v: Value
    if ctx.readEdgeProp(target.id, key, v): v else: Value(kind: vkNull)
  of vkMap:
    for (k, v) in target.pairs:
      if k == key:
        return v
    Value(kind: vkNull)
  else:
    ## `1.name` is null rather than an error: Cypher gives null for a
    ## property of a non-node, and an error here would make every
    ## `optional.property` a special case for the caller to catch.
    Value(kind: vkNull)

proc keysOf(ctx: QueryCtx, target: Value): Value {.gcsafe.} =
  var names: seq[Value] = @[]
  case target.kind
  of vkNode:
    if ctx.nodeAlive(target.id):
      for k in ctx.propKeysOf(target.id, true):
        names.add Value(kind: vkString, s: k)
  of vkEdge:
    if ctx.edgeAlive(target.id):
      for k in ctx.propKeysOf(target.id, false):
        names.add Value(kind: vkString, s: k)
  of vkMap:
    for (k, _) in target.pairs:
      names.add Value(kind: vkString, s: k)
  else:
    discard
  Value(kind: vkList, items: names)

proc labelsOf(ctx: QueryCtx, target: Value): Value {.gcsafe.} =
  if target.kind != vkNode:
    return Value(kind: vkList, items: @[])
  let name = ctx.labelOfNode(target.id)
  if name.len == 0:
    return Value(kind: vkList, items: @[])
  Value(kind: vkList, items: @[Value(kind: vkString, s: name)])

proc typeOf(ctx: QueryCtx, target: Value): Value {.gcsafe.} =
  if target.kind != vkEdge:
    return Value(kind: vkNull)
  Value(kind: vkString, s: ctx.typeOfEdge(target.id))

# ------------------------------------------------------------- arithmetic

proc arith(op: string, a, b: Value): Value =
  if a.kind == vkNull or b.kind == vkNull:
    return Value(kind: vkNull)
  if op == "+":
    ## Cypher's `+` overloads by left operand: string + anything
    ## concatenates (rendering the right side the way toString does), and
    ## list + list concatenates. `"a" + 1` is `"a1"`, not an error — the
    ## error is what the first probe of this file produced, and it made
    ## every label-building expression (`'n' + n.id`) a query failure.
    if a.kind == vkString:
      return Value(kind: vkString, s: a.s & toCypherString(b))
    if b.kind == vkString:
      return Value(kind: vkString, s: toCypherString(a) & b.s)
    if a.kind == vkList and b.kind == vkList:
      return Value(kind: vkList, items: a.items & b.items)
  var x, y: float64
  if not numOf(a, x) or not numOf(b, y):
    ## `+` is the one arithmetic operator with more than one shape, and
    ## its message says so: `1 + true` is refused for being none of them,
    ## not for being "not a number" — a string and a list are numbers to
    ## nobody and valid to `+`.
    if op == "+":
      cypherFail(int32(glyErrSql),
        "+ needs two numbers, two strings or two lists, not " &
        typeName(a) & " and " & typeName(b))
    cypherFail(int32(glyErrSql),
      op & " needs numbers, not " & typeName(a) & " and " & typeName(b))
  ## Integers stay integers. `1 + 1` is `2`, not `2.0`: promoting here would
  ## make every count a float on its way to the host, and a count that
  ## renders as 2.0 is a wrong answer however you dress it up.
  let bothInts = a.kind == vkInt and b.kind == vkInt
  if op == "+":
    return (if bothInts: Value(kind: vkInt, i: a.i + b.i)
            else: Value(kind: vkFloat, f: x + y))
  if op == "-":
    return (if bothInts: Value(kind: vkInt, i: a.i - b.i)
            else: Value(kind: vkFloat, f: x - y))
  if op == "*":
    return (if bothInts: Value(kind: vkInt, i: a.i * b.i)
            else: Value(kind: vkFloat, f: x * y))
  if op == "/":
    ## Division by zero is null in Cypher, not infinity and not an error:
    ## `1/0` in a query is a modelling mistake, and a query that raises
    ## halfway through a traversal loses every row it had already produced.
    if y == 0.0:
      return Value(kind: vkNull)
    ## Integer division truncates toward zero, which is Cypher's rule and
    ## Nim's `div`.
    if bothInts:
      return Value(kind: vkInt, i: a.i div b.i)
    return Value(kind: vkFloat, f: x / y)
  if op == "%":
    if y == 0.0:
      return Value(kind: vkNull)
    ## Cypher's `%` is fmod, which truncates toward zero, not floor:
    ## `-7 % 3` is -1 in Cypher. The int branch below follows `div` and was
    ## already correct; the float branch used `floor`, which made
    ## `-7.0 % 3.0` answer 2.0 — the two branches disagreed about the same
    ## mathematical question, and the comment described the answer the code
    ## did not give.
    if bothInts:
      return Value(kind: vkInt, i: a.i - (a.i div b.i) * b.i)
    return Value(kind: vkFloat, f: x - trunc(x / y) * y)
  if op == "^":
    return Value(kind: vkFloat, f: pow(x, y))
  cypherFail(int32(glyErrSql), "unknown operator " & op)

# ------------------------------------------------------------- functions

proc tryFloat(s: string): float64 =
  ## NaN rather than an exception: `toInteger("x")` is null, and the
  ## alternative is a try/except inside an `if` condition, which Nim does
  ## not allow.
  try:
    parseFloat(s)
  except ValueError:
    NaN

proc regexOf(pattern: string, compiled: var Regex): bool =
  ## `=~` is RE2 syntax per CYPHER.md §2.3. Nim's `re` wraps PCRE2, so a
  ## pattern that compiles here may not be RE2 — documented as a known
  ## difference rather than papered over.
  ##
  ## `compiled` is an out-param rather than a returned `Regex` because a
  ## caller cannot use a `Regex` that was never assigned, and `new(result)`
  ## on a `ref RegexDesc` allocates before the pattern is known to be
  ## valid. A failed compile leaves it nil and the caller answers null.
  try:
    compiled = re(pattern)
    true
  except RegexError:
    false

proc flipDirs(dirs: seq[uint8]): seq[uint8] =
  ## Reversing a path flips every hop's direction, because a hop that went
  ## src→dst now goes dst→src.
  for d in dirs:
    result.add (if d == 0'u8: 1'u8 else: 0'u8)

# --------------------------------------------------- shortest paths (M6.4)

type
  PathStatus* = enum
    psFound, psNoPath, psTooDeep

proc neighboursOf(ctx: QueryCtx; at: int64; typeCode: int32):
    seq[(int64, int64, uint8)] =
  ## `(edge id, far node, direction)` for one node, both directions.
  ## `dirs` is 0 when the edge was walked src→dst and 1 the other way —
  ## the same byte `PathVal` stores, so the rebuild needs no second
  ## convention.
  for eid in ctx.outEdges(at):
    let (_, dst, et) = ctx.edgeEnds(eid)
    if typeCode != 0 and et != typeCode:
      continue
    if not ctx.nodeAlive(dst):
      continue
    result.add (eid, dst, 0'u8)
  for eid in ctx.inEdges(at):
    let (src, _, et) = ctx.edgeEnds(eid)
    if typeCode != 0 and et != typeCode:
      continue
    if not ctx.nodeAlive(src):
      continue
    result.add (eid, src, 1'u8)

proc shortestPathOf*(ctx: QueryCtx; fromId, toId: int64; rtype: string;
                     maxDepth: int): (PathStatus, PathVal) =
  ## Breadth-first, both directions, with a visited set: a cycle must not
  ## make it loop, and the first time a node is reached is the shortest
  ## way to it.
  ##
  ## Three outcomes, and the third is the one that matters:
  ## **found**, **no path** (the frontier emptied — an honest `null`), and
  ## **too deep** (the search hit `maxDepth` with nodes still to explore).
  ## Answering `null` for the third would be a lie — the path may exist
  ## and simply be longer — so the caller refuses it by name, which is
  ## pin C18.
  ##
  ## The walk is undirected. "How far apart are these two things" is the
  ## question the function answers, and a direction is a detail of the
  ## edge, not of the distance; a caller that wants a directed walk has
  ## `MATCH … -[*]->` for it.
  var typeCode = 0'i32
  if rtype.len > 0:
    typeCode = ctx.store.relTypes.lookup(rtype)
    ## A type nothing carries has no path: the planner's -1 distinction,
    ## one layer down. Without it a typo would walk every edge.
    if typeCode == 0:
      return (psNoPath, PathVal())
  if fromId == toId:
    return (psFound, PathVal(nodes: @[fromId]))
  var parents = initTable[int64, (int64, int64, uint8)]()
  var seen = initHashSet[int64]()
  seen.incl fromId
  var frontier: seq[int64] = @[fromId]
  for _ in 1 .. maxDepth:
    var next: seq[int64] = @[]
    for at in frontier:
      for (eid, far, dir) in neighboursOf(ctx, at, typeCode):
        if far in seen:
          continue
        seen.incl far
        parents[far] = (at, eid, dir)
        if far == toId:
          var nodes: seq[int64] = @[toId]
          var edges: seq[int64] = @[]
          var dirs: seq[uint8] = @[]
          var cur = toId
          while cur != fromId:
            let (prev, pe, pd) = parents[cur]
            edges.add pe
            dirs.add pd
            nodes.add prev
            cur = prev
          nodes.reverse()
          edges.reverse()
          dirs.reverse()
          return (psFound,
                  PathVal(nodes: nodes, edges: edges, dirs: dirs))
        next.add far
    if next.len == 0:
      return (psNoPath, PathVal())
    frontier = next
  (psTooDeep, PathVal())

proc callFunc(e: Eval, name: string, args: seq[Value]): Value {.gcsafe.} =
  let lower = toLowerAscii(name)
  let n = args.len
  case lower
  of "id":
    if n != 1:
      cypherFail(int32(glyErrSql), "id() takes one argument")
    if args[0].kind in {vkNode, vkEdge}:
      return Value(kind: vkInt, i: args[0].id)
    return Value(kind: vkNull)
  of "labels":
    if n != 1: cypherFail(int32(glyErrSql), "labels() takes one argument")
    e.ctx.labelsOf(args[0])
  of "type":
    if n != 1: cypherFail(int32(glyErrSql), "type() takes one argument")
    e.ctx.typeOf(args[0])
  of "keys":
    if n != 1: cypherFail(int32(glyErrSql), "keys() takes one argument")
    e.ctx.keysOf(args[0])
  of "properties":
    if n != 1: cypherFail(int32(glyErrSql), "properties() takes one argument")
    case args[0].kind
    of vkNode, vkEdge:
      let keys = e.ctx.keysOf(args[0])
      var pairs: seq[(string, Value)] = @[]
      for k in keys.items:
        pairs.add (k.s, propertyOf(e.ctx, args[0], k.s))
      Value(kind: vkMap, pairs: pairs)
    of vkMap:
      args[0]
    else:
      Value(kind: vkMap, pairs: @[])
  of "tostring":
    if n != 1: cypherFail(int32(glyErrSql), "toString() takes one argument")
    ## Same rendering as string `+` (toCypherString): two spellings of one
    ## rule, or the two drift apart the first time someone fixes one.
    let v = args[0]
    if v.kind == vkNull:
      Value(kind: vkNull)
    elif v.kind in {vkBool, vkInt, vkFloat, vkString, vkBytes, vkDate}:
      Value(kind: vkString, s: toCypherString(v))
    elif v.kind == vkNode:
      Value(kind: vkString, s: "node " & $v.id)
    elif v.kind == vkEdge:
      Value(kind: vkString, s: "edge " & $v.id)
    else:
      cypherFail(int32(glyErrSql), "toString() cannot render " & $v.kind)
  of "tointeger":
    if n != 1: cypherFail(int32(glyErrSql), "toInteger() takes one argument")
    var asInt: int64
    ## A string goes through its number first, so `toInteger("42")` works
    ## and `toInteger("x")` is null rather than an error.
    if args[0].kind == vkString:
      var asFloat: float64
      if numOf(Value(kind: vkFloat, f: tryFloat(args[0].s)), asFloat) and
         intOf(Value(kind: vkFloat, f: asFloat), asInt):
        return Value(kind: vkInt, i: asInt)
      return Value(kind: vkNull)
    if intOf(args[0], asInt):
      return Value(kind: vkInt, i: asInt)
    Value(kind: vkNull)
  of "tofloat":
    if n != 1: cypherFail(int32(glyErrSql), "toFloat() takes one argument")
    var x: float64
    if numOf(args[0], x):
      return Value(kind: vkFloat, f: x)
    if args[0].kind == vkString:
      try:
        return Value(kind: vkFloat, f: parseFloat(args[0].s))
      except ValueError:
        return Value(kind: vkNull)
    Value(kind: vkNull)
  of "abs":
    if n != 1: cypherFail(int32(glyErrSql), "abs() takes one argument")
    var x: float64
    if not numOf(args[0], x):
      return Value(kind: vkNull)
    if args[0].kind == vkInt:
      Value(kind: vkInt, i: (if x < 0: -args[0].i else: args[0].i))
    else:
      Value(kind: vkFloat, f: abs(x))
  of "size", "length":
    if n != 1: cypherFail(int32(glyErrSql), lower & "() takes one argument")
    let v = args[0]
    case v.kind
    of vkNull: Value(kind: vkNull)
    of vkString, vkBytes: Value(kind: vkInt, i: v.s.len)
    of vkList: Value(kind: vkInt, i: v.items.len)
    of vkMap: Value(kind: vkInt, i: v.pairs.len)
    of vkVector: Value(kind: vkInt, i: v.dims.len)
    of vkPath: Value(kind: vkInt, i: v.path.nodes.len)
    else: Value(kind: vkNull)
  of "shortestpath", "shortestpathlength":
    ## `shortestPath(a, b [, type [, maxDepth]])` — the path between two
    ## nodes as a value; `shortestPathLength(...)` — its length in hops.
    ##
    ## A *function*, not a pattern: the openCypher spelling is
    ## `shortestPath((a)-[*]-(b))`, which is path binding, and the engine
    ## refuses path binding (CYPHER.md §2.6). The endpoints here are
    ## values the caller already has, which makes the function the honest
    ## form of the same question.
    if n < 2 or n > 4:
      cypherFail(int32(glyErrSql), lower & "() takes two to four arguments")
    if args[0].kind != vkNode or args[1].kind != vkNode:
      cypherFail(int32(glyErrSql),
        lower & "() needs two nodes, not " & typeName(args[0]) &
        " and " & typeName(args[1]))
    var rtype = ""
    if n >= 3:
      if args[2].kind != vkString:
        cypherFail(int32(glyErrSql),
          lower & "() needs a relationship type as a string, not " &
          typeName(args[2]))
      rtype = args[2].s
    var maxDepth = 16
    if n >= 4:
      if args[3].kind != vkInt:
        cypherFail(int32(glyErrSql),
          lower & "() needs a whole maxDepth, not " & typeName(args[3]))
      maxDepth = int(args[3].i)
      if maxDepth < 1 or maxDepth > 1024:
        cypherFail(int32(glyErrSql),
          lower & "() needs a maxDepth between 1 and 1024")
    let (status, path) = shortestPathOf(e.ctx, args[0].id, args[1].id,
                                        rtype, maxDepth)
    case status
    of psFound:
      if lower == "shortestpath":
        Value(kind: vkPath, path: path)
      else:
        Value(kind: vkInt, i: int64(path.edges.len))
    of psNoPath:
      Value(kind: vkNull)
    of psTooDeep:
      cypherFail(int32(glyErrSql),
        lower & "() hit maxDepth " & $maxDepth &
        " without an answer; raise the bound")
  of "coalesce":
    if n == 0: cypherFail(int32(glyErrSql), "coalesce() needs at least one argument")
    for a in args:
      if a.kind != vkNull:
        return a
    Value(kind: vkNull)
  of "head", "last":
    if n != 1: cypherFail(int32(glyErrSql), lower & "() takes one argument")
    if args[0].kind != vkList:
      return Value(kind: vkNull)
    if args[0].items.len == 0:
      return Value(kind: vkNull)
    if lower == "head": args[0].items[0] else: args[0].items[^1]
  of "tolower", "toupper":
    if n != 1: cypherFail(int32(glyErrSql), lower & "() takes one argument")
    if args[0].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkString,
          s: (if lower == "tolower": toLowerAscii(args[0].s) else: toUpperAscii(args[0].s)))
  of "trim":
    if n != 1: cypherFail(int32(glyErrSql), "trim() takes one argument")
    if args[0].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkString, s: args[0].s.strip())
  of "date":
    ## `date('2026-10-21')`. One string in, one date out; `date(null)` is
    ## null, and a date passed in comes back unchanged, so `date(x)` is
    ## idempotent the way the standard's cast is.
    if n != 1: cypherFail(int32(glyErrSql), "date() takes one argument")
    if args[0].kind == vkNull:
      return Value(kind: vkNull)
    if args[0].kind == vkDate:
      return args[0]
    if args[0].kind != vkString:
      cypherFail(int32(glyErrSql),
        "date() needs a 'YYYY-MM-DD' string, not " & typeName(args[0]))
    var days: int64
    if not parseDateText(args[0].s, days):
      cypherFail(int32(glyErrSql),
        "date(): '" & args[0].s & "' is not a YYYY-MM-DD date")
    Value(kind: vkDate, d: days)
  of "typeof":
    if n != 1: cypherFail(int32(glyErrSql), "typeof() takes one argument")
    Value(kind: vkString, s: typeOfValue(e.ctx, args[0]))
  of "startswith":
    if n != 2: cypherFail(int32(glyErrSql), "startsWith() takes two arguments")
    if args[0].kind != vkString or args[1].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkBool, b: args[0].s.startsWith(args[1].s))
  of "endswith":
    if n != 2: cypherFail(int32(glyErrSql), "endsWith() takes two arguments")
    if args[0].kind != vkString or args[1].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkBool, b: args[0].s.endsWith(args[1].s))
  of "contains":
    if n != 2: cypherFail(int32(glyErrSql), "contains() takes two arguments")
    if args[0].kind != vkString or args[1].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkBool, b: args[0].s.contains(args[1].s))
  of "replace":
    if n != 3: cypherFail(int32(glyErrSql), "replace() takes three arguments")
    if args[0].kind != vkString:
      return Value(kind: vkNull)
    Value(kind: vkString, s: args[0].s.replace(args[1].s, args[2].s))
  of "substring":
    if n < 2: cypherFail(int32(glyErrSql), "substring() takes two or three arguments")
    if args[0].kind != vkString:
      return Value(kind: vkNull)
    var start: int64
    if not intOf(args[1], start):
      return Value(kind: vkNull)
    var count = args[0].s.len - start.int
    if n == 3:
      var c: int64
      if not intOf(args[2], c):
        return Value(kind: vkNull)
      count = c.int
    ## Cypher's `substring` is zero-based with an inclusive length, which is
    ## not what Nim's `substr(s, first, last)` does (one-based, and `last`
    ## inclusive). Converting here rather than at the call site is why
    ## `substring('abcdef', 1, 3)` is `bcd`.
    if start.int < 0 or start.int > args[0].s.len or count < 0:
      return Value(kind: vkNull)
    if start.int + count.int > args[0].s.len:
      count = args[0].s.len - start.int
    Value(kind: vkString, s: args[0].s[start.int ..< start.int + count.int])
  of "nodes", "edges":
    ## `nodes(p)` and `edges(p)` over a path. `relationships(p)` is the
    ## name CYPHER.md lists for edges; both spellings are accepted because
    ## both appear in real queries and neither is a different operation.
    if n != 1: cypherFail(int32(glyErrSql), lower & "() takes one argument")
    if args[0].kind != vkPath:
      return Value(kind: vkList, items: @[])
    ## `nodes(p)` and `edges(p)` return the same list of references under
    ## two tags, so the loop is written once and the tag chosen per element
    ## — a `case` inside an object constructor cannot select a discriminant
    ## whose branch shares a field with another.
    var items: seq[Value] = @[]
    if lower == "nodes":
      for id in args[0].path.nodes:
        items.add Value(kind: vkNode, id: id)
    else:
      for id in args[0].path.edges:
        items.add Value(kind: vkEdge, id: id)
    Value(kind: vkList, items: items)
  of "relationships":
    if n != 1: cypherFail(int32(glyErrSql), "relationships() takes one argument")
    if args[0].kind != vkPath:
      return Value(kind: vkList, items: @[])
    var items: seq[Value] = @[]
    for id in args[0].path.edges:
      items.add Value(kind: vkEdge, id: id)
    Value(kind: vkList, items: items)
  of "reverse":
    if n != 1: cypherFail(int32(glyErrSql), "reverse() takes one argument")
    if args[0].kind == vkPath:
      let p = args[0].path
      var nodes = newSeq[int64](p.nodes.len)
      for i in 0 ..< p.nodes.len:
        nodes[p.nodes.len - 1 - i] = p.nodes[i]
      ## A one-node path has no edges and therefore no directions to flip.
      var newDirs: seq[uint8] = @[]
      if p.dirs.len > 0:
        newDirs = flipDirs(p.dirs)
      Value(kind: vkPath, path: PathVal(nodes: nodes, edges: p.edges,
                                        dirs: newDirs))
    elif args[0].kind == vkList:
      var rev: seq[Value] = @[]
      for i in countdown(args[0].items.high, 0):
        rev.add args[0].items[i]
      Value(kind: vkList, items: rev)
    else:
      Value(kind: vkNull)
  of "range":
    ## A named error rather than null: "no such function" and "returned
    ## null" are different problems and conflating them is how a typo
    ## becomes a silent empty result set.
    ## `range(a, b)` is inclusive at both ends; `range(a, b, step)` steps by
    ## `step` and stops before passing `b`. Both halves matter: an exclusive
    ## range is off by one at every boundary, which is the kind of bug a
    ## benchmark built on top of it would hide by being self-consistent.
    if args.len < 2 or args.len > 3:
      cypherFail(int32(glyErrSql), "range() takes two or three numbers")
    for a in args:
      if a.kind != vkInt and a.kind != vkFloat:
        cypherFail(int32(glyErrSql), "range() takes numbers, got " & $a.kind)
    let lo0 = (if args[0].kind == vkInt: args[0].i else: int64(args[0].f))
    let hi0 = (if args[1].kind == vkInt: args[1].i else: int64(args[1].f))
    let step =
      if args.len == 3:
        (if args[2].kind == vkInt: args[2].i else: int64(args[2].f))
      else:
        ## Cypher's rule: with no step, the range runs *toward* the end. A
        ## fixed +1 would make `range(3, 1)` empty rather than `[3, 2, 1]`,
        ## which is both wrong and the sort of wrong nobody notices — the
        ## list is empty and an empty list looks like a filter that matched
        ## nothing.
        (if hi0 < lo0: -1'i64 else: 1'i64)
    if step == 0:
      cypherFail(int32(glyErrSql), "range() with a step of 0 never ends")
    let lo = lo0
    let hi = hi0
    ## A cap, because the list is materialised: `range(1, 1000000000)` is a
    ## typo that would otherwise be an out-of-memory kill rather than a
    ## message naming the function.
    const RangeCap = 10_000_000'i64
    if abs(hi - lo) div max(1'i64, abs(step)) > RangeCap:
      unsupported("range() of more than " & $RangeCap &
                  " elements (it builds the list in memory)")
    var items: seq[Value] = @[]
    var n = lo
    while (if step > 0: n <= hi else: n >= hi):
      items.add Value(kind: vkInt, i: n)
      n += step
    return Value(kind: vkList, items: items)
  else:
    ## A named error rather than null: "no such function" and "returned
    ## null" are different problems and conflating them is how a typo
    ## becomes a silent empty result set.
    cypherFail(int32(glyErrUnsupported), "unknown function " & name & "()")

# ------------------------------------------------------------- evaluation

proc evalProperty(e: Eval, target: Expr, key: string): Value =
  let t = e.eval(target)
  if t.kind == vkNull:
    return t
  propertyOf(e.ctx, t, key)

proc patternHolds*(ctx: QueryCtx; row: Row; pat: Pattern): bool =
  ## Does this path hold for this row?
  ##
  ## Depth-first with backtracking over the adjacency. Every *named* node
  ## is already bound, so a hop only has to check that the far end is the
  ## node the row names. An **anonymous** node constrains nothing but
  ## liveness — `(a)-[:KNOWS]->()` asks "does a know someone?", which the
  ## adjacency answers without binding anything, and binding nothing is
  ## exactly what makes this a filter rather than a semi-join.
  ##
  ## The relationship's type is resolved per call rather than at plan
  ## time, because a pattern predicate lives inside an expression and an
  ## expression has no plan of its own. It costs one dictionary lookup per
  ## predicate per row; the alternative — resolving it in the planner and
  ## threading a code through `Pattern` — would give one pattern two
  ## representations, and they would drift.
  proc walk(i: int; at: int64): bool =
    if i >= pat.elems.len:
      return true
    let r = pat.elems[i].rel
    let node = pat.elems[i + 1].node
    var code = 0'i32
    if r.types.len > 0:
      code = ctx.store.relTypes.lookup(r.types[0])
      ## An unknown type matches nothing — the planner's -1, for the same
      ## reason: a typo must be an empty answer, never "any relationship".
      if code == 0:
        return false
    var edges: seq[int64]
    case r.dir
    of dirIn:
      edges = ctx.inEdges(at)
    of dirOut:
      edges = ctx.outEdges(at)
    of dirBoth:
      edges = ctx.outEdges(at)
      for e in ctx.inEdges(at):
        edges.add e
    for eid in edges:
      let (src, dst, et) = ctx.edgeEnds(eid)
      if code != 0 and et != code:
        continue
      let other = (if src == at: dst else: src)
      if not ctx.nodeAlive(other):
        continue
      if node.varName.len > 0:
        let (found, v) = row.lookup(node.varName)
        if not found or v.kind != vkNode or v.id != other:
          continue
      if walk(i + 2, other):
        return true
    false

  if pat.elems.len < 3 or pat.elems[0].node.varName.len == 0:
    return false
  let (found, v) = row.lookup(pat.elems[0].node.varName)
  if not found or v.kind != vkNode:
    return false
  walk(1, v.id)

proc eval(e: Eval, expr: Expr): Value =
  if e.depth > MaxEvalDepth:
    cypherFail(int32(glyErrLimit), "expression nested deeper than " & $MaxEvalDepth)
  case expr.kind
  of ekLit:
    return expr.lit
  of ekVar:
    let (found, v) = e.row.lookup(expr.name)
    if found: v else: Value(kind: vkNull)
  of ekParam:
    if e.ctx.params.hasKey(expr.name):
      e.ctx.params[expr.name]
    else:
      ## A missing parameter is null, not an error: a JSON object is allowed
      ## to be incomplete and Cypher's answer for an absent value is null.
      Value(kind: vkNull)
  of ekProp:
    return e.evalProperty(expr.target, expr.name)
  of ekIndex:
    let t = e.eval(expr.target)
    let idx = e.eval(expr.index)
    if t.kind == vkMap:
      if idx.kind != vkString:
        return Value(kind: vkNull)
      for (k, v) in t.pairs:
        if k == idx.s:
          return v
      return Value(kind: vkNull)
    if t.kind == vkList:
      var i: int64
      if not intOf(idx, i):
        return Value(kind: vkNull)
      ## Negative indexing from the end, as openCypher defines it.
      let at = (if i < 0: t.items.len.int + i.int else: i.int)
      if at < 0 or at >= t.items.len:
        return Value(kind: vkNull)
      return t.items[at]
    Value(kind: vkNull)
  of ekUnary:
    let v = e.eval(expr.target)
    if v.kind == vkNull:
      return v
    var x: float64
    if not numOf(v, x):
      return Value(kind: vkNull)
    if expr.op == "-":
      if v.kind == vkInt: Value(kind: vkInt, i: -v.i)
      else: Value(kind: vkFloat, f: -x)
    else:
      v
  of ekBinary:
    let a = e.eval(expr.items[0])
    let b = e.eval(expr.items[1])
    arith(expr.op, a, b)
  of ekCompare:
    let a = e.eval(expr.items[0])
    let b = e.eval(expr.items[1])
    if expr.op == "IN":
      if b.kind == vkNull:
        return Value(kind: vkNull)
      if b.kind != vkList:
        cypherFail(int32(glyErrSql),
          "IN needs a list on its right side, not " & typeName(b))
      ## Cypher's `IN` folds equality over the list under three-valued
      ## logic: `2 IN [1, null]` is *null* — an equality the engine could
      ## not answer might have matched, so `NOT (2 IN [1, null])` must not
      ## be true — while `null IN []` is *false*, because an empty list is a
      ## known answer. The first draft answered both backwards: it returned
      ## null for the empty list and false for the null element, swapping
      ## the one case that is known for the one that is not.
      if b.items.len == 0:
        return Value(kind: vkBool, b: false)
      var sawNull = a.kind == vkNull
      for item in b.items:
        let r = eqValues(a, item)
        if r.kind == vkBool and r.b:
          return Value(kind: vkBool, b: true)
        if r.kind == vkNull or item.kind == vkNull:
          sawNull = true
      if sawNull:
        return Value(kind: vkNull)
      return Value(kind: vkBool, b: false)
    if expr.op == "CONTAINS" or expr.op == "STARTS WITH" or
       expr.op == "ENDS WITH":
      if a.kind == vkNull or b.kind == vkNull:
        return Value(kind: vkNull)
      if a.kind == vkList:
        for item in a.items:
          if eqValues(item, b).kind == vkBool:
            let m = eqValues(item, b)
            if m.b:
              return Value(kind: vkBool, b: true)
        return Value(kind: vkBool, b: false)
      if a.kind != vkString or b.kind != vkString:
        cypherFail(int32(glyErrSql),
          expr.op & " needs two strings, not " & typeName(a) & " and " & typeName(b))
      return e.callFunc(toLowerAscii(expr.op).replace(" ", ""), @[a, b])
    if expr.op == "=~":
      if a.kind == vkNull or b.kind == vkNull:
        return Value(kind: vkNull)
      if a.kind != vkString or b.kind != vkString:
        cypherFail(int32(glyErrSql),
          "=~ needs two strings, not " & typeName(a) & " and " & typeName(b))
      var rx: Regex
      if not regexOf(b.s, rx):
        cypherFail(int32(glyErrSql), "invalid regular expression: " & b.s)
      return Value(kind: vkBool, b: match(a.s, rx))
    if expr.op == "=":
      return eqValues(a, b)
    if expr.op == "<>":
      let r = eqValues(a, b)
      if r.kind == vkNull:
        return r
      return Value(kind: vkBool, b: not r.b)
    let (ord, ok) = compareValues(a, b)
    if not ok:
      ## Null propagates (pin C6); a non-null pair the engine cannot order
      ## is a type error by name (pin C17). Answering null for `1 < 'a'`
      ## would drop the row and look like "no matches".
      if a.kind == vkNull or b.kind == vkNull:
        return Value(kind: vkNull)
      cypherFail(int32(glyErrSql),
        expr.op & " needs two comparable values, not " & typeName(a) &
        " and " & typeName(b))
    case expr.op
    of "<": Value(kind: vkBool, b: ord < 0)
    of "<=": Value(kind: vkBool, b: ord <= 0)
    of ">": Value(kind: vkBool, b: ord > 0)
    of ">=": Value(kind: vkBool, b: ord >= 0)
    else:
      cypherFail(int32(glyErrSql), "unknown comparison " & expr.op)
  of ekAnd:
    ## Three-valued: `false AND anything` is false without evaluating the
    ## right side, `true AND x` is x. A non-boolean, non-null operand is a
    ## query error, Cypher's rule: `1 AND 1` is not `true`, and a silent
    ## `true` here would smuggle an int predicate past a WHERE.
    ##
    ## The type check runs as soon as *both* sides have been evaluated,
    ## before either side's value decides the answer: `1 AND false` is
    ## ill-typed whichever answer the short-circuit would give, and
    ## answering `false` for it would be a query error dressed as an
    ## answer (pin C17). The left side's own short-circuit still skips the
    ## right side entirely, which is the documented rule — a value that is
    ## never evaluated cannot be type-checked.
    let l = e.eval(expr.items[0])
    if l.kind == vkBool and not l.b:
      return Value(kind: vkBool, b: false)
    let r = e.eval(expr.items[1])
    if l.kind != vkBool and l.kind != vkNull:
      logicFail(expr.op, l, r)
    if r.kind != vkBool and r.kind != vkNull:
      logicFail(expr.op, l, r)
    if r.kind == vkBool and not r.b:
      return Value(kind: vkBool, b: false)
    if l.kind == vkNull or r.kind == vkNull:
      return Value(kind: vkNull)
    Value(kind: vkBool, b: true)
  of ekOr:
    ## The same order as AND, for the same reason: `1 OR true` answers
    ## `true` mathematically, and is a type error nonetheless.
    let l = e.eval(expr.items[0])
    if l.kind == vkBool and l.b:
      return Value(kind: vkBool, b: true)
    let r = e.eval(expr.items[1])
    if l.kind != vkBool and l.kind != vkNull:
      logicFail(expr.op, l, r)
    if r.kind != vkBool and r.kind != vkNull:
      logicFail(expr.op, l, r)
    if r.kind == vkBool and r.b:
      return Value(kind: vkBool, b: true)
    if l.kind == vkNull or r.kind == vkNull:
      return Value(kind: vkNull)
    Value(kind: vkBool, b: false)
  of ekXor:
    ## Three-valued with no short-circuit: XOR needs both sides. `1 XOR 0`
    ## used to read the bool field off an int and take the row down with
    ## it; the type check is the fix, the null propagation the semantics.
    let l = e.eval(expr.items[0])
    let r = e.eval(expr.items[1])
    if l.kind == vkNull or r.kind == vkNull:
      return Value(kind: vkNull)
    if l.kind != vkBool or r.kind != vkBool:
      logicFail(expr.op, l, r)
    Value(kind: vkBool, b: l.b != r.b)
  of ekNot:
    let v = e.eval(expr.target)
    if v.kind == vkNull:
      return v
    if v.kind != vkBool:
      logicFailUnary("NOT", v)
    Value(kind: vkBool, b: not v.b)
  of ekIsNull:
    let v = e.eval(expr.target)
    let isNull = v.kind == vkNull
    Value(kind: vkBool, b: (if expr.negated: not isNull else: isNull))
  of ekList:
    var items: seq[Value] = @[]
    for item in expr.items:
      items.add e.eval(item)
    Value(kind: vkList, items: items)
  of ekMap:
    var pairs: seq[(string, Value)] = @[]
    for (k, v) in expr.pairs:
      pairs.add (k, e.eval(v))
    Value(kind: vkMap, pairs: pairs)
  of ekFunc:
    if expr.name.toLowerAscii in AggregateNames:
      ## Same as `count(*)`: an aggregate that survived substitution means
      ## the plan did not treat this projection as a grouping.
      cypherFail(int32(glyErrSql),
                 "the aggregate " & expr.name & "() reached the evaluator outside an aggregation")
    var args: seq[Value] = @[]
    for a in expr.items:
      args.add e.eval(a)
    e.callFunc(expr.name, args)
  of ekCountStar:
    ## Reaching the evaluator at all means the plan failed to recognise an
    ## aggregation — the Aggregate operator substitutes these away before
    ## anything evaluates. The message says *that* rather than blaming the
    ## query, because at this point the query is fine and the plan is not.
    cypherFail(int32(glyErrSql), "count(*) reached the evaluator outside an aggregation")
  of ekExists:
    ## Filled in by the operator that owns the pattern (ops.nim), which has
    ## the plan. Reaching the evaluator means the plan lost the subquery.
    cypherFail(int32(glyErrSql), "EXISTS { … } has no pattern bound")
  of ekPatternPred:
    ## A pattern over already-bound variables is a *filter*, not a bind:
    ## the scope check has refused any variable nobody bound, so all that
    ## is left is the walk.
    Value(kind: vkBool, b: patternHolds(e.ctx, e.row, expr.pattern))

proc quoteJson*(s: string): string =
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc valueJson*(v: Value): string =
  ## A `Value` as JSON, for the two places that need one: a list or map
  ## cell's payload (below), and the conformance runner's expected rows.
  ## One function so a runner's expectations and the engine's cells cannot
  ## disagree about what a value looks like — a runner that rendered values
  ## its own way would report a pass for a cell the host reads as something
  ## else, which is the failure mode a conformance suite exists to catch.
  case v.kind
  of vkNull:
    result = "null"
  of vkBool:
    result = (if v.b: "true" else: "false")
  of vkInt:
    result = $v.i
  of vkFloat:
    result = $v.f
  of vkString, vkBytes:
    result = quoteJson(v.s)
  of vkNode, vkEdge:
    result = $v.id
  of vkDate:
    ## The standard's spelling, as a JSON string: a date is not a number,
    ## and a conformance row that rendered it as one would be testing the
    ## wrong thing.
    result = quoteJson(dateText(v.d))
  of vkList:
    result = "["
    for i, item in v.items:
      if i > 0: result.add ","
      result.add valueJson(item)
    result.add "]"
  of vkMap:
    result = "{"
    for i, (k, item) in v.pairs:
      if i > 0: result.add ","
      result.add quoteJson(k) & ":" & valueJson(item)
    result.add "}"
  of vkVector:
    ## Components, not a bare null: the aggregate DISTINCT key is this
    ## rendering (`count(DISTINCT n.emb)` collapsed every same-length
    ## vector to one entry), and a text host reading a vector now sees its
    ## numbers rather than a null that reads as an absent value. The binary
    ## `GLY_VECTOR` accessor is unchanged.
    result = "["
    for i, d in v.dims:
      if i > 0: result.add ","
      result.add $d
    result.add "]"
  of vkPath:
    ## A path has no JSON spelling the ABI offers, and the runner never
    ## expects one: paths are refused at parse in this slice.
    result = "null"

proc isAggregateExpr*(e: Expr): bool {.gcsafe.} =
  ## Whether this expression contains an aggregate call. The question the
  ## planner asks to decide "projection or grouping", and the semantic pass
  ## asks to keep aggregates out of WHERE.
  case e.kind
  of ekCountStar:
    true
  of ekFunc:
    if e.name.toLowerAscii in AggregateNames:
      return true
    for item in e.items:
      if isAggregateExpr(item):
        return true
    false
  of ekProp, ekUnary:
    isAggregateExpr(e.target)
  of ekBinary, ekCompare, ekAnd, ekOr, ekXor:
    for item in e.items:
      if isAggregateExpr(item):
        return true
    false
  of ekNot, ekIsNull, ekExists:
    isAggregateExpr(e.target)
  of ekIndex:
    isAggregateExpr(e.target) or isAggregateExpr(e.index)
  of ekList:
    for item in e.items:
      if isAggregateExpr(item):
        return true
    false
  else:
    false

proc collectAggregates*(e: Expr, found: var seq[Expr]) {.gcsafe.} =
  ## Every aggregate call in this expression, left to right, depth first.
  ##
  ## The order is the contract: `substAggregates` walks in the same order
  ## and takes the values off this list, so the nth value goes to the nth
  ## call site. Anything fuzzier — matching by rendered text, or a hash per
  ## call — would eventually pair `count(*)` in one item with the value of
  ## `count(*)` in another, and the bug would look like a wrong number
  ## rather than a wrong pairing.
  case e.kind
  of ekCountStar:
    found.add e
  of ekFunc:
    if e.name.toLowerAscii in AggregateNames:
      found.add e
    else:
      for item in e.items:
        collectAggregates(item, found)
  of ekProp, ekUnary, ekNot, ekIsNull, ekExists:
    collectAggregates(e.target, found)
  of ekBinary, ekCompare, ekAnd, ekOr, ekXor:
    for item in e.items:
      collectAggregates(item, found)
  of ekIndex:
    collectAggregates(e.target, found)
    collectAggregates(e.index, found)
  of ekList:
    for item in e.items:
      collectAggregates(item, found)
  else:
    discard

proc substAggregates*(e: Expr, values: seq[Value], k: var int): Expr =
  ## A copy of `e` with every aggregate call replaced by the value it
  ## evaluated to over this group.
  ##
  ## Substitution rather than "the evaluator knows its group": an evaluator
  ## that could reach upward into its operator would make *every* expression
  ## evaluation depend on where it runs, and `WHERE count(*) > 1` would
  ## quietly become legal. With substitution the aggregate calls are gone
  ## before evaluation, so a stray one in the wrong clause still fails.
  result = new(Expr)
  ## Copied field by field rather than by `result = e` and then patching:
  ## a shallow copy would share the child `items` seq, and writing a
  ## substituted child into it would edit the *original* projection — which
  ## is shared by every statement that parsed the same text.
  result.kind = e.kind
  result.op = e.op
  result.name = e.name
  result.line = e.line
  result.col = e.col
  result.isDistinct = e.isDistinct
  result.lit = e.lit
  result.uval = e.uval
  result.negated = e.negated
  case e.kind
  of ekCountStar:
    result = lit(values[k]); inc k
  of ekFunc:
    if e.name.toLowerAscii in AggregateNames:
      result = lit(values[k]); inc k
    else:
      for item in e.items:
        result.items.add substAggregates(item, values, k)
  of ekProp, ekUnary, ekNot, ekIsNull, ekExists:
    result.target = if e.target == nil: nil else: substAggregates(e.target, values, k)
  of ekBinary, ekCompare, ekAnd, ekOr, ekXor:
    for item in e.items:
      result.items.add substAggregates(item, values, k)
  of ekIndex:
    result.target = substAggregates(e.target, values, k)
    result.index = substAggregates(e.index, values, k)
  of ekList:
    for item in e.items:
      result.items.add substAggregates(item, values, k)
  else:
    discard

proc isCountStarCall(call: Expr): bool {.gcsafe.} =
  ## The parser spells `count(*)` as the call `count` with one argument that
  ## is the `*` — there is no bare `count(*)` node, so this pair of tests is
  ## what the clause means throughout.
  call.kind == ekFunc and call.items.len == 1 and
    call.items[0].kind == ekCountStar

proc aggregateValue*(ctx: QueryCtx, call: Expr, rows: seq[Row]): Value =
  ## One aggregate over one group's rows. The second argument is the whole
  ## group, because an aggregate is the only expression in the language whose
  ## value depends on how many rows it saw.
  let name = (if call.kind == ekCountStar: "count" else: call.name.toLowerAscii)
  if name notin AggregateNames:
    cypherFail(int32(glyErrSql), "not an aggregate")

  if call.kind == ekCountStar or isCountStarCall(call):
    ## `count(*)` counts rows, including rows whose other columns are all
    ## null. The difference from `count(x)` is the whole reason both exist.
    return Value(kind: vkInt, i: int64(rows.len))

  ## Evaluate the argument on every row. Not a column lookup: `count(n.age)`
  ## is not "the column called n.age" — the row binds `n` to a *node*, and
  ## `n.age` is a property read that happens to be spelled like a dotted
  ## path. Evaluating also means `count(n.age * 2)` works, which a
  ## name-based implementation would have refused for no stated reason.
  var present: seq[Value] = @[]
  if call.items.len == 0:
    ## An aggregate with no argument: `count()` is a row count, and every
    ## other aggregate has nothing to fold, which the branches below answer
    ## from an empty `present`.
    discard
  else:
    for r in rows:
      let v = evaluate(ctx, r, call.items[0])
      if v.kind != vkNull:
        present.add v

  if call.isDistinct:
    ## `DISTINCT` is a property of the aggregate, not of one of them, so it
    ## is applied once to the values here. Handling it per-aggregate would
    ## mean remembering it in six branches, and the sixth one added later
    ## would be the one that forgot.
    ##
    ## First occurrence wins, which keeps the *order* of the values stable —
    ## and `collect(DISTINCT …)` returns them in that order, so a caller who
    ## wants a sorted list still has to sort it themselves, as in Cypher.
    var seen = initHashSet[string]()
    var deduped: seq[Value] = @[]
    for v in present:
      let k = valueJson(v)
      if k notin seen:
        seen.incl k
        deduped.add v
    present = deduped

  case name
  of "count":
    return Value(kind: vkInt, i: int64(present.len))
  of "collect":
    ## Order preserved, duplicates kept unless DISTINCT was asked for above —
    ## so `collect` is the only aggregate whose *list* is the answer, and the
    ## reason a caller who wants a set writes DISTINCT explicitly.
    return Value(kind: vkList, items: present)
  of "min", "max":
    ## The type check comes *before* the fold, not inside it: `max(x)` over a
    ## single list value would otherwise compare nothing and hand back the
    ## list, which is the shape a caller least expects — Cypher's rule is
    ## that the values must be orderable, whatever their number.
    for v in present:
      case v.kind
      of vkInt, vkFloat, vkString, vkBool:
        discard
      else:
        cypherFail(int32(glyErrSql),
                   name & "() needs orderable values, got " & $v.kind)
    if present.len == 0:
      return Value(kind: vkNull)
    var best: Value = present[0]
    for j in 1 ..< present.len:
      let item: Value = present[j]
      let (ord, ok) = compareValues(item, best)
      if not ok:
        cypherFail(int32(glyErrSql),
                   name & "() cannot compare " & $item.kind & " with " & $best.kind)
      if (if name == "min": ord < 0 else: ord > 0):
        best = item
    return best
  of "sum", "avg":
    if present.len == 0:
      ## Cypher's answers: `sum` of nothing is 0, `avg` of nothing is null.
      ## One is a total, the other a mean over no values — and the reason
      ## they are not the same branch is that a caller summing a column
      ## wants 0 while a caller averaging it wants "no such value".
      return (if name == "sum": Value(kind: vkInt, i: 0) else: Value(kind: vkNull))
    var total = 0.0
    var allInt = true
    for v in present:
      if v.kind != vkInt and v.kind != vkFloat:
        cypherFail(int32(glyErrSql), name & "() needs numbers, got " & $v.kind)
      if v.kind == vkFloat:
        allInt = false
      total += (if v.kind == vkInt: float64(v.i) else: v.f)
    if name == "avg":
      return Value(kind: vkFloat, f: total / float64(present.len))
    ## An integer sum stays an integer. Summing into a float would make
    ## `sum([1,2,3])` print 6.0 and lose exactness above 2^53, which is
    ## exactly the range where a caller reaching for SUM is counting things.
    if allInt:
      var asInt = 0'i64
      for v in present:
        asInt += v.i
      return Value(kind: vkInt, i: asInt)
    return Value(kind: vkFloat, f: total)
  of "stdev":
    if present.len < 2:
      ## Sample standard deviation divides by n-1, which needs two values.
      ## With one value nothing varies, and 0 says that; null would have
      ## meant "not enough data" and sent the caller looking for a guard.
      return Value(kind: vkFloat, f: 0.0)
    var total = 0.0
    for v in present:
      if v.kind != vkInt and v.kind != vkFloat:
        cypherFail(int32(glyErrSql), "stdev() needs numbers, got " & $v.kind)
      total += (if v.kind == vkInt: float64(v.i) else: v.f)
    let mean = total / float64(present.len)
    var sq = 0.0
    for v in present:
      let d = (if v.kind == vkInt: float64(v.i) else: v.f) - mean
      sq += d * d
    return Value(kind: vkFloat, f: sqrt(sq / float64(present.len - 1)))
  else:
    cypherFail(int32(glyErrSql), "unknown aggregate " & name & "()")

proc propertyOf*(e: Eval, target: Value, key: string): Value =
  propertyOf(e.ctx, target, key)

proc evaluate*(e: Eval, expr: Expr): Value = e.eval(expr)

proc evaluateAt*(ctx: QueryCtx, row: Row, expr: Expr): Value =
  ## The form operators use. One `Eval` per statement, not per row: the
  ## only mutable state is the depth counter, and a fresh one per row would
  ## allocate on the hot path.
  Eval(ctx: ctx, row: row).eval(expr)

proc evaluate*(ctx: QueryCtx, row: Row, expr: Expr): Value =
  evaluateAt(ctx, row, expr)

## Exported because operators need the same rule the evaluator uses: only
## `true` is true, and `null` is not.
proc isTrue*(v: Value): bool = truthy(v)

proc collectVars*(e: Expr, into: var seq[string]) =
  ## Every variable an expression reads. Order does not matter; duplicates
  ## are harmless because the check is membership.
  case e.kind
  of ekVar:
    into.add e.name
  of ekProp, ekUnary:
    collectVars(e.target, into)
  of ekBinary, ekCompare, ekAnd, ekOr, ekXor:
    for item in e.items:
      collectVars(item, into)
  of ekNot, ekIsNull:
    collectVars(e.target, into)
  of ekIndex:
    collectVars(e.target, into)
    collectVars(e.index, into)
  of ekList:
    for item in e.items:
      collectVars(item, into)
  of ekMap:
    for (_, v) in e.pairs:
      collectVars(v, into)
  of ekFunc:
    for item in e.items:
      collectVars(item, into)
  of ekExists, ekPatternPred:
    ## A predicate's named variables are *reads*: the scope check refuses
    ## one that nobody bound, which is the whole rule.
    for name in boundVariables(e.pattern):
      into.add name
  else:
    discard

proc conjuncts*(e: Expr): seq[Expr] =
  ## The AND-flattening the vector pushdown splits a WHERE with. A nested
  ## AND tree becomes its leaves; anything else is one conjunct. OR is
  ## deliberately *not* flattened — `a OR b` cannot be answered per
  ## candidate by evaluating halves separately.
  if e.kind == ekAnd:
    for item in e.items:
      for c in conjuncts(item):
        result.add c
  else:
    result = @[e]
