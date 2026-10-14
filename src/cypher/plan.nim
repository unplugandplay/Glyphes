## glyphes — the planner (PRD §5.3, EXEC.md §4)
##
## Greedy, on purpose, and the reason is in the PRD: "no cost model in 0.1,
## pinned". A planner that guesses badly is a common cause of a slow embedded
## database, and one that guesses *differently every run* is worse than one
## that guesses badly. These rules make the same choice for the same query
## every time, which is what makes a plan explainable to the person who
## wrote it.
##
## ## Rules, in order, first match wins (EXEC.md §4.1)
##
##   1. Label with >= 32 members -> `ScanByLabel`
##   2. Label + equality on an indexed property -> `IndexSeek`
##   3. Indexed property with `=`, `<`, `<=`, `>`, `>=`, `IN` -> `IndexSeek`
##   4. `CALL db.idx.vector/text` on this variable -> `VectorScan` / `TextScan`
##   5. otherwise -> `ScanAll`
##
## Rule 1 before rule 2 is deliberate, not an oversight: a label index is a
## contiguous array scan, which beats a seek that resolves to the same set.
## The 32-member threshold is empirical.
##
## **Rules 2 to 4 are written here as rules with nothing behind them yet.**
## Indices arrive at M6 (`INDEX.md`), so the code says so rather than
## omitting the rules — a rule that does not exist cannot be tested, and one
## added later is one nobody has read. What M4 does *not* do is fall through
## silently: `MATCH (a:Person {email: $e})` plans as a scan plus a filter,
## which is correct, just not fast, and `integrity` of the answer is not in
## question.
##
## ## Scope, stated rather than discovered
##
## M4 plans exactly:
##
##     MATCH <one pattern> [WHERE …] [UNWIND … AS x] [WITH … [WHERE …]]
##     [RETURN …] [ORDER BY …] [SKIP n] [LIMIT n]
##
## and refuses, by name: a comma-separated `MATCH (a), (b)` (a real cross
## product needs a join operator, and EXEC.md §2 does not have one), a
## second `MATCH` after a `WITH` (a semi-join), `OPTIONAL MATCH`, variable
## length, and every aggregate. Each is one named error rather than a plan
## that quietly returns the wrong number of rows.

import std/[sets, tables]
import ../store/store
import ../index/index
import ../index/range
import ./errors
import ../errors
import ../abi
import ./ast
import ./ctx
import ./ops
import ./expr

type
  Plan* = object
    root*: Operator
    columns*: seq[string]

const
  ## EXEC.md §4.1. Below this a label's id list is short enough that walking
  ## it costs less than resolving a seek to the same set.
  LabelScanThreshold* = 32

proc typeCodeOf(ctx: QueryCtx, name: string): int32 =
  ## 0 means "any type", which is how a pattern with no `:TYPE` is spelled.
  ## Not a magic constant in the store: type codes start at 1, so 0 is
  ## already "none".
  ctx.store.relTypes.lookup(name)

proc labelMemberCount(ctx: QueryCtx, label: string): int =
  ## No local for the member table: `let` copies it (ops.nim,
  ## `newScanByLabel`, has the story), and this runs once per prepare.
  let code = ctx.store.labels.lookup(label)
  if code == 0:
    return 0
  if code.int > ctx.snap.members.len:
    return 0
  ctx.snap.members[code.int - 1].len

proc chooseScan(ctx: QueryCtx, np: NodePattern): Operator =
  ## EXEC.md §4.1 rules 1 and 5, delegated to `ops.scanFor` — the same
  ## decision MERGE's match half makes, in one place. Rules 2 to 4 land with
  ## the indices at M6.
  scanFor(ctx, np)

proc inlinePropFilter(varName, key: string, value: Expr): Expr =
  ## `{age: 30}` becomes `var.age = 30`. A predicate, not an operator:
  ## EXEC.md §4.3 puts it above the scan, where the evaluator can see the
  ## variable, rather than inside it where it would have to be re-derived.
  binary(ekCompare, "=", propExpr(varExpr(varName), key), value)

proc buildPatternFrom(ctx: QueryCtx, pat: var Pattern, seed: Operator,
                      headVar: string): Operator =
  ## `buildPattern` with the caller saying what the chain starts from: an
  ## empty `headVar` means "scan the first node", and a name means "that node
  ## is already bound in the incoming row". OPTIONAL MATCH needs the second
  ## form (its right side is correlated with the left), and a second copy of
  ## the Expand loop is how the two would drift.
  if pat.pathVar.len > 0:
    unsupported("path binding (MATCH p = (a)-[*]->(b)) lands at M5")
  ## Anonymous chain nodes get an internal name before anything is planned.
  ## Without this, `MATCH ()-[:R]->()` planned an Expand whose start
  ## variable was "", the scan bound nothing under that name, and the Expand
  ## passed every row through untouched: one row, nothing in it, no error.
  ## That is the worst shape a query bug can have — it looked like a graph
  ## with no relationships. The names start with `_`, which Cypher's
  ## identifier rule forbids (an identifier must begin with a letter), so
  ## they cannot collide with anything the caller wrote.
  var anon = 0
  for i in 0 ..< pat.elems.len:
    if pat.elems[i].isNode and pat.elems[i].node.varName.len == 0:
      ## Indexed, not `for el in …`: the loop variable is a copy, and a
      ## field write on a copy of a variant object is the kind of thing Nim
      ## refuses to do silently.
      pat.elems[i].node.varName = "_anon" & $anon
      inc anon
  ## Nothing is skipped when the head is pre-bound: element 1 is a
  ## *relationship*, and the first Expand starts from the bound name. There
  ## is nothing to bind for element 0 because the row already carries it.
  var chain = (if headVar.len > 0: seed else: chooseScan(ctx, pat.elems[0].node))
  for i in 1 ..< pat.elems.len:
    let rel = pat.elems[i]
    if rel.isNode:
      continue
    let prev = pat.elems[i - 1]
    let far = pat.elems[i + 1]
    if not prev.isNode or not far.isNode:
      continue
    let r = rel.rel
    ## 0 = any type, -1 = a type nothing carries. Same distinction as the
    ## label: a lookup of 0 must not silently mean "no filter".
    var code = 0'i32
    for t in r.types:
      code = typeCodeOf(ctx, t)
      if code == 0:
        code = -1'i32
      break
    if r.types.len > 1:
      ## An alternation `[:KNOWS|SIMILAR_TO]` needs a set, and M4's Expand
      ## carries one type code. Refused rather than approximated with the
      ## first alternative, which would be a wrong answer for the second.
      unsupported("relationship type alternation ([:A|B]) lands at M5")
    var boundVar = prev.node.varName
    var endVar = far.node.varName
    ## An undirected pattern with one side named expands from the side that
    ## is named; with neither, from the left, which is the side the scan
    ## just produced.
    if r.dir == dirBoth and boundVar.len == 0 and endVar.len > 0:
      swap(boundVar, endVar)
    ## The child is the chain so far, which is what makes a three-hop
    ## pattern three rows deep without a join operator: each Expand's input
    ## is the Expand before it, and each one adds its endpoint to the row.
    let step =
      if r.varLen:
        ## EXEC.md §2.2 expands `*1..3` into one Expand per hop count — but
        ## only where an edge cannot repeat. A walk of `*1..3` over a cycle
        ## goes out and comes back along the same edge, which is a path
        ## Cypher does not have (CYPHER.md §2.1), so a variable-length step
        ## is its own operator: it enumerates whole walks and remembers
        ## which edges each one used.
        newVarLen(ctx, chain, boundVar, r.varName, endVar, r.dir, code,
                  r.minHops, r.maxHops)
      else:
        newExpand(ctx, boundVar, r.varName, endVar, r.dir, code)
    step.child = chain
    chain = step
  result = chain

proc buildPattern(ctx: QueryCtx, pat: var Pattern): Operator =
  ## One chain: a scan for the first node, then one Expand per relationship.
  ## The Expand is what joins — it binds both endpoints from one row, which
  ## is why there is no join operator (EXEC.md §2).
  result = buildPatternFrom(ctx, pat, nil, "")

proc newOneRow*(ctx: QueryCtx): Operator =
  ## A source that produces exactly one empty row, for `RETURN 1 + 1`.
  ## A dedicated kind rather than `ScanAll` over an empty store: "the store
  ## happens to be empty" is a property of the data, and a query whose row
  ## count depends on it is not a query.
  Operator(kind: okOneRow, ctx: ctx)

proc sortKeyExpr(item: SortItem, columns: seq[string]): Expr =
  ## `ORDER BY a.age` after `RETURN a.age` is the column named `a.age`.
  ##
  ## Sort sits *above* the projection (it has to: `ORDER BY n` refers to an
  ## alias, which only exists after the projection), so by then the row holds
  ## the projected columns and no longer holds `a` as a node. Resolving the
  ## key to its column name here is what makes both spellings work — the
  ## alias and the property path — and without it every key evaluates to
  ## null, every pair compares equal, and the sort silently keeps the scan's
  ## order.
  let name =
    if item.expr.kind == ekVar: item.expr.name
    elif item.expr.kind == ekProp and item.expr.target.kind == ekVar:
      item.expr.target.name & "." & item.expr.name
    else: ""
  if name.len == 0 or name notin columns:
    ## Not a plain column reference: keep the expression, so `ORDER BY a.age
    ## + 1` still works as long as its inputs are in scope.
    return item.expr
  varExpr(name)

proc copyPattern(pat: Pattern): Pattern =
  ## A copy the planner may rename. Anonymous nodes get internal names when
  ## the chain is built, and the OPTIONAL MATCH builder builds one chain per
  ## row — on the *shared* pattern the second row would number its anonymous
  ## nodes from zero again and collide with the first row's.
  result = pat
  result.elems = newSeq[PatternElement](pat.elems.len)
  for i in 0 ..< pat.elems.len:
    result.elems[i] = pat.elems[i]

proc optionalBuilder(ctx: QueryCtx, pat: Pattern,
                     cond: Expr): proc (row: Row): Operator {.closure.} =
  ## The correlated right side of an OPTIONAL MATCH, as a plan built per row.
  ##
  ## Whether the pattern is correlated or free is a property of *this* row:
  ## `OPTIONAL MATCH (a)-[:R]->(b)` is correlated for a row that carries `a`
  ## and a cross product for one that does not (which is exactly what
  ## happens after another optional match null-filled `a`). Deciding it in
  ## the planner would have to guess, and guessing "correlated" would expand
  ## an unbound name into nothing.
  result = proc (row: Row): Operator =
    var p = copyPattern(pat)
    var chain: Operator
    let head = p.elems[0].node
    if head.varName.len > 0 and row.lookup(head.varName)[0]:
      let feed = newInputRow(ctx)
      feedRow(feed, row)
      chain = buildPatternFrom(ctx, p, feed, head.varName)
    else:
      chain = buildPattern(ctx, p)
      for el in p.elems:
        if not el.isNode or el.node.varName.len == 0:
          continue
        for entry in el.node.props:
          chain = newFilter(ctx, chain,
                            inlinePropFilter(el.node.varName, entry.key, entry.expr))
    if cond != nil:
      ## The optional pattern's own WHERE is *inside* the join, not above
      ## it. Above, a row that matched and then failed the predicate would be
      ## null-extended and returned — a node that has the relationship and
      ## then pretends not to.
      chain = newFilter(ctx, chain, cond)
    result = chain


proc flipOp(op: string): string =
  ## The comparator with its operands swapped, for `30 = n.age`.
  case op
  of "=": "="
  of "<": ">"
  of ">": "<"
  of "<=": ">="
  of ">=": "<="
  else: ""

proc seekCandidates(ctx: QueryCtx, part: QueryPart,
                    nodeVars: seq[string]): seq[SeekKey] =
  ## Every conjunct of the match's `WHERE` that a range index could answer,
  ## in source order, preceded by the pattern's own inline properties.
  ##
  ## Source order and not "best" order because EXEC.md §4.1 says so: with
  ## two indexed predicates and no cardinalities, the first one wins, and a
  ## cost-based choice would have to guess. A conjunct is taken only when
  ## its variable is the node this pattern binds, because an index on
  ## `:Person(age)` cannot answer `WHERE other.age = 30`.
  if ctx.indices == nil or part.patterns.len == 0:
    return @[]
  var found = newSeq[SeekKey]()
  ## A value side the index can be keyed by: a literal *or* a parameter.
  ## `WHERE n.age = $age` is the spelling almost every query uses — the
  ## model layer, the importer, and every benchmark in this project write
  ## parameters — and it planned as a full scan while the identical literal
  ## predicate planned as a seek. I5 never caught it because I5 measures the
  ## index directly, never through a query: the same predicate ran at
  ## 235/s as a parameter against 51 164/s as a literal (DEVLOG, "the
  ## literal gate").
  proc isValue(e: Expr): bool = e.kind == ekLit or e.kind == ekParam

  ## The head node's inline properties, and first: `MATCH (n:Person
  ## {age: 30})` is the more specific predicate of the two, and its filter
  ## still runs above the seek either way, so making it a candidate cannot
  ## change an answer — only which nodes are examined. This was the second
  ## half of the same defect: the inline spelling ran at 84/s against
  ## 17 606/s for the `WHERE` spelling on 2·10^4 indexed nodes, which made
  ## every edge statement a full scan. The M11 edge-load benchmark is what
  ## finally made that visible (881 edges/s, DEVLOG "the literal gate").
  let headEl = part.patterns[0].elems[0]
  if headEl.isNode and headEl.node.varName.len > 0:
    for entry in headEl.node.props:
      if isValue(entry.expr):
        found.add SeekKey(varName: headEl.node.varName, prop: entry.key,
                          op: "=", value: evalLiteral(ctx, entry.expr))

  proc walk(e: Expr) =
    if e == nil:
      return
    if e.kind == ekAnd:
      for item in e.items:
        walk(item)
      return
    ## `n.age = 30` and `30 = n.age` are the same query; only the first
    ## spelling is read, because reading the second needs the comparator's
    ## inverse table for six operators to save a scan in a query nobody
    ## writes.
    if e.kind != ekCompare:
      return
    var left = e.items[0]
    var right = e.items[1]
    if isValue(left) and right.kind == ekProp:
      let tmp = left
      left = right
      right = tmp
      let flipped = flipOp(e.op)
      if flipped.len == 0:
        return
      found.add SeekKey(varName: left.target.name, prop: left.name,
                        op: flipped, value: evalLiteral(ctx, right))
      return
    if left.kind != ekProp:
      return
    if right.kind == ekList and e.op == "IN":
      var vs: seq[Value] = @[]
      for item in right.items:
        vs.add evalLiteral(ctx, item)
      found.add SeekKey(varName: left.target.name, prop: left.name,
                        op: "IN", values: vs)
      return
    if not isValue(right):
      return
    for op in ["=", "<", "<=", ">", ">="]:
      if e.op == op:
        found.add SeekKey(varName: left.target.name, prop: left.name,
                          op: op, value: evalLiteral(ctx, right))
        return
  walk(part.matchCond)
  ## Only predicates on the variable this pattern binds.
  var keep: seq[SeekKey] = @[]
  for key in found:
    if key.varName in nodeVars:
      keep.add key
  return keep



proc plan*(ctx: QueryCtx, q: Query): Plan =
  var seed: Operator = nil
  var columns: seq[string] = @[]
  var matchSeen = false
  var optionalSeen = false
  var tail: seq[QueryPart] = @[]

  var skipNext = false
  for i, part in q.parts:
    if skipNext:
      skipNext = false
      continue
    case part.kind
    of qpMatch:
      if part.optional:
        ## OPTIONAL MATCH is the one join 0.1 has, and it is left-outer:
        ## every row the left side produced comes out, matched or null-filled.
        if part.patterns.len != 1:
          unsupported("a comma-separated OPTIONAL MATCH lands at M5")
        if matchSeen and optionalSeen:
          ## One per query (CYPHER.md §2.2): a second one is not merely
          ## rarer, it is a second left-outer over an already-left-outer
          ## row, whose null rows interact with the pattern in ways that are
          ## easy to get subtly wrong and expensive to pin.
          unsupported("a second OPTIONAL MATCH clause in one query")
        if not matchSeen:
          ## `OPTIONAL MATCH (a) RETURN a` with nothing on the left is a
          ## full scan with a null case that cannot occur — legal, but only
          ## as a plain match, and refusing it says "add a MATCH" instead of
          ## silently behaving like one.
          unsupported("OPTIONAL MATCH as the first clause (nothing to its left)")
        let patVars = boundVariables(part.patterns[0])
        let cond = part.matchCond
        seed = newOptional(ctx, seed, patVars, optionalBuilder(ctx, part.patterns[0], cond))
        optionalSeen = true
        matchSeen = true
        continue
      if matchSeen:
        ## Two MATCH clauses is a join; with a `WITH` between them it is a
        ## semi-join, which is a different operator.
        unsupported("a second MATCH clause (a join) lands at M5")
      if seed != nil:
        ## A MATCH after a retrieval is a join between the hits and the
        ## pattern: uncorrelated variables make it a cartesian product,
        ## which §2 refuses, and a correlated one (`WHERE d = doc`) is a
        ## semi-join the operator set does not have. The composed form —
        ## filters pushed into a retrieval — lands with the vector family
        ## at M6.3, where a walk has something to push into.
        ## The composed traversal (CYPHER.md §4's example) is filtered
        ## with WHERE on the yielded variable — the pushdown — not with a
        ## pattern join. A MATCH here binds fresh variables and is either
        ## a cartesian product or a semi-join; the operator set has
        ## neither. Named, so the caller is pointed at WHERE, not at a
        ## milestone.
        unsupported("a MATCH after a retrieval (a join): filter with " &
                    "WHERE on the yielded variable instead")
      if part.patterns.len != 1:
        unsupported("a comma-separated MATCH (a cartesian product) lands at M5")
      let pat = part.patterns[0]
      ## EXEC.md §4.1 rules 2 and 3, ahead of the label-scan rule. A seek is
      ## a *candidate* generator: the predicate still runs above it (below
      ## the chain), so a stale or wrong index can lose a row but cannot
      ## invent one. That asymmetry is the point — an accelerator that could
      ## change the answer would be a second implementation of `WHERE`.
      var headVars: seq[string] = @[]
      for el in pat.elems:
        if el.isNode and el.node.varName.len > 0:
          headVars.add el.node.varName
      var seeked = false
      for key in seekCandidates(ctx, part, headVars):
        if seeked:
          break                     ## first indexed predicate wins (§4.1)
        let head = pat.elems[0].node
        let ix = ctx.indices.find(if head.label.len > 0: head.label else: "", key.prop)
        if ix == nil or not ix.usable or not seekKeyable(key):
          continue
        ## A literal the index cannot key — a bool, a list, `null` — must
        ## not seek. `seekEq` on such a key answers with nothing, and
        ## nothing is *fewer* rows than the scan finds: the one direction
        ## the filter above cannot repair. The scan is the answer; the
        ## index was only ever a shortcut for the keys it can hold.
        var ids = seekIds(ctx, ix, key)
        ## An index with nothing in it must not replace a scan with an empty
        ## answer: an index created before the data existed is a normal state
        ## (INDEX.md §5), and a seek over it is correct only because the
        ## registry backfills. Guarding on non-empty here would make a
        ## legitimately empty result indistinguishable from a broken one, so
        ## the seek is used and the invariant is tested instead.
        discard ids
        let code = (if head.label.len > 0: ctx.store.labels.lookup(head.label)
                    else: 0'i32)
        ## The seek is the chain's *head node*, not the whole pattern. It
        ## used to be assigned to `seed` and nothing else, so every
        ## relationship in the pattern was dropped whenever the planner
        ## seeked: `MATCH (a:Person)-[:KNOWS]->(b:Person) WHERE a.id = 0`
        ## answered with the seek row alone, `b` unbound, and no error —
        ## one row with a null where the traversal's rows should be. The
        ## wrong answer was also *faster*, so nothing measured it.
        ## Building the pattern from the seek keeps the Expands.
        seed = buildPatternFrom(ctx, part.patterns[0],
                                newIndexSeek(ctx, head.varName, ids, code, ix.name),
                                head.varName)
        seeked = true
      if not seeked:
        seed = buildPattern(ctx, part.patterns[0])
      for el in pat.elems:
        if not el.isNode or el.node.varName.len == 0:
          continue
        for entry in el.node.props:
          seed = newFilter(ctx, seed,
                           inlinePropFilter(el.node.varName, entry.key, entry.expr))
      if part.matchCond != nil:
        seed = newFilter(ctx, seed, part.matchCond)
      matchSeen = true

    of qpWhere:
      seed = newFilter(ctx, seed, part.cond)

    of qpTextCall:
      ## A retrieval is a source: it produces rows from an index rather than
      ## filtering rows that already exist, so it cannot sit on top of a
      ## seed. What composes with it is everything *above* — WHERE, WITH,
      ## RETURN — which is the same shape a scan has, minus the pattern.
      if seed != nil:
        unsupported("a CALL after another clause (a join)")
      ## Resolve the query value at prepare: a parameter or a literal.
      var qval = Value(kind: vkNull)
      case part.queryExpr.kind
      of ekParam:
        if not ctx.params.hasKey(part.queryExpr.name):
          fail(int32(glyErrSql),
               "missing parameter $" & part.queryExpr.name &
               " (AGAINST needs it before prepare)")
        qval = ctx.params[part.queryExpr.name]
      of ekLit:
        qval = part.queryExpr.lit
      of ekList:
        var items: seq[Value] = @[]
        for item in part.queryExpr.items:
          items.add item.lit
        qval = Value(kind: vkList, items: items)
      else:
        ## The parser only admits ekParam, ekLit and number lists here
        ## (parseTextCall), so this is a constructor bug rather than a
        ## query problem.
        fail(int32(glyErrSql),
             "query expression of kind " & $ord(part.queryExpr.kind) &
             " reached the planner")
      ## The pushed-down filter (INDEX.md §4.3): conjuncts of a following
      ## WHERE that reference only the yielded node are evaluated *during*
      ## the walk, so ef is spent on live rows instead of filtered-out
      ## ones. What remains above stays a plain filter — a conjunct over
      ## `score` or another variable cannot be answered per candidate.
      var pushed: seq[Expr] = @[]
      var rest: seq[Expr] = @[]
      var consumedWhere = false
      if i + 1 < q.parts.len and q.parts[i + 1].kind == qpWhere:
        for c in conjuncts(q.parts[i + 1].cond):
          var used: seq[string] = @[]
          collectVars(c, used)
          var onlyDoc = used.len > 0
          for u in used:
            if u != part.yieldNode:
              onlyDoc = false
          if onlyDoc and part.yieldNode.len > 0:
            pushed.add c
          else:
            rest.add c
        consumedWhere = true
      if part.isVec:
        let qvec = asFloatVec(qval)
        if qvec.len == 0:
          unsupported("AGAINST a vector needs a vector or a list of numbers; $" &
                      part.queryExpr.name & " is neither")
        seed = newVectorSearch(ctx, part.indexName, qvec,
                               part.yieldNode, part.yieldScore, pushed)
      else:
        if qval.kind != vkString:
          unsupported("AGAINST needs a string for a text index, got " &
                      $ord(qval.kind))
        seed = newTextSearch(ctx, part.indexName, qval.s,
                             part.yieldNode, part.yieldScore)
      if consumedWhere:
        if rest.len > 0:
          var cond = rest[0]
          for r in rest[1 ..^ 1]:
            cond = Expr(kind: ekAnd, items: @[cond, r])
          seed = newFilter(ctx, seed, cond)
        skipNext = true

    of qpCreate:
      ## `CREATE` with nothing before it still needs a row to act on: one
      ## empty row, so `CREATE (n) RETURN n` is one node rather than no
      ## rows at all. The projection below would do the same thing a part
      ## later; doing it here keeps the operator's contract simple (one
      ## row in, one row out) and means `CREATE` composes with MATCH the
      ## same way every other clause does.
      if seed == nil:
        seed = newOneRow(ctx)
      seed = newCreate(ctx, seed, part.createPatterns)

    of qpMerge:
      if seed == nil:
        seed = newOneRow(ctx)
      seed = newMerge(ctx, seed, part)

    of qpSet, qpRemove, qpDelete:
      ## Every write clause needs a row to act on, for the same reason
      ## CREATE does: `SET a.x = 1` with nothing before it has one empty
      ## row, and with a MATCH before it has one row per match. The clause's
      ## own shape lives in its constructor.
      if seed == nil:
        seed = newOneRow(ctx)
      case part.kind
      of qpSet:
        seed = newSet(ctx, seed, part.setItems)
      of qpRemove:
        seed = newRemove(ctx, seed, part.removeItems)
      else:
        seed = newDelete(ctx, seed, part.deleteVars, part.detach)

    of qpUnwind:
      if seed == nil:
        ## `UNWIND [1,2] AS x RETURN x` with no MATCH: one row in, the list
        ## out. Same fallback as a projection with nothing to project from.
        seed = newOneRow(ctx)
      seed = newUnwind(ctx, seed, part.list, part.varName)

    of qpProjection:
      var aggregating = false
      for item in part.projection.items:
        if isAggregateExpr(item.expr):
          aggregating = true
      if seed == nil:
        if aggregating:
          ## `RETURN count(*)` with nothing to read: the answer is 0, and
          ## only if the input here is *empty*. The one-row seed exists so
          ## that `RETURN 1 + 1` has something to project; feeding a
          ## projection with an aggregate that same row would make
          ## `count(*)` say 1 about an empty graph — the implicit row is a
          ## row that does not exist.
          seed = newUnwind(ctx, newOneRow(ctx), listExpr(@[]), "")
        else:
          ## A projection with nothing to project from — `RETURN 1 + 1`.
          ## One row, from a one-element list: a dedicated operator would be
          ## a kind whose whole job is to answer true once, and `Unwind`
          ## over `[null]` already does that.
          seed = newOneRow(ctx)
      var cols: seq[string] = @[]
      for i in 0 ..< part.projection.items.len:
        cols.add exprColumn(part.projection.items[i], i)
      if part.withCond != nil:
        seed = newFilter(ctx, seed, part.withCond)
      ## The one decision that makes this a projection or a grouping, already
      ## answered above. Nothing else changes — the output columns, the
      ## aliases, and ORDER BY above all work the same either way.
      seed = (if aggregating: newAggregate(ctx, seed, part.projection.items, cols)
              else: newProject(ctx, seed, part.projection.items, cols))
      ## DISTINCT goes *above* the projection, not below it: it hashes the
      ## output columns, and Cypher's `RETURN DISTINCT` is over the output.
      ## Below the projection it would have no column names to hash and every
      ## row would share one key.
      if part.projection.isDistinct:
        seed = newDistinct(ctx, seed, cols)
      columns = cols

    of qpOrderBy, qpSkip, qpLimit:
      ## Deferred: the tail is attached in query order after the projection,
      ## because `RETURN … ORDER BY … LIMIT 10` has to sort before it
      ## truncates — the difference between "the 10 largest" and "10 of them,
      ## sorted".
      tail.add part

  for part in tail:
    case part.kind
    of qpOrderBy:
      var spec = part.sort
      for i in 0 ..< spec.items.len:
        spec.items[i].expr = sortKeyExpr(spec.items[i], columns)
      seed = newSort(ctx, seed, spec, ctx.sortSpillRows, ctx.spillDir)
    of qpSkip:
      let v = evaluate(ctx, Row(), part.skipAmount)
      if v.kind != vkInt:
        parseFail("SKIP needs an integer")
      seed = newSkip(ctx, seed, v.i)
    of qpLimit:
      let v = evaluate(ctx, Row(), part.limitAmount)
      if v.kind != vkInt:
        parseFail("LIMIT needs an integer")
      seed = newLimit(ctx, seed, v.i)
    else:
      discard

  if seed == nil:
    parseFail("the query has no clause that produces rows")
  result = Plan(root: seed, columns: columns)