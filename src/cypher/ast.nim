## glyphes — the Cypher AST (CYPHER.md)
##
## A tagged-object tree, not a variant tree. The reason is not style: the
## semantic pass and the expression evaluator both walk this tree
## generically (to find variables, to evaluate a subtree), and a
## `ref object of RootObj` with a `case` over its fields costs one dispatch
## per visit where a variant costs a per-kind `case` in *every* visitor. The
## evaluation code is where the bugs live, so the AST is built to be walked.
##
## `Value` from the store is the literal type. That is deliberate: the
## property value model, the snapshot format and the ABI cell tags already
## have to agree (STORAGE.md §2.4), and giving the query layer a fourth
## value type would mean a conversion on every literal, every expression
## result and every property read — three places to get a tag wrong.
##
## Positions are kept on expressions and on clause heads so the semantic
## pass can say `line 3: variable x is not defined`, which is the difference
## between a usable error and "unknown identifier".

import ../store/prop
import ../abi

type
  ## ---------------------------------------------------------------- values

  PropEntry* = tuple[key: string, expr: Expr]
  ## A `{k: v}` entry, in a pattern or a map literal. The value is an
  ## *expression*, not a `Value`: `{age: $min}` is a pattern filter over a
  ## parameter, and flattening it to a value at parse time would lose the
  ## difference between a literal and a bound variable — which is exactly
  ## the difference between a constant-foldable predicate and one that needs
  ## the row.

  ## ----------------------------------------------------------- expressions

  ExprKind* = enum
    ekLit,       ## a literal, in `lit`
    ekVar,       ## a variable name, in `name`
    ekParam,     ## $name, in `name`
    ekProp,      ## expr.name  (expr = target, name = key)
    ekIndex,     ## expr[expr] (map lookup or list index)
    ekUnary,     ## op in `op`: "-" "+"
    ekBinary,    ## op in `op`: arithmetic and string concat
    ekCompare,   ## = <> < <= > >= CONTAINS STARTS WITH ENDS WITH =~ IN
    ekAnd, ekOr, ekXor,
    ekNot,
    ekIsNull,    ## expr IS [NOT] NULL; `not` in `negated`
    ekList,      ## [a, b, c]
    ekMap,       ## {k: v}
    ekFunc,      ## name(args...) in `name`/`items`; `isDistinct` for DISTINCT
    ekExists,    ## EXISTS { pattern }; the pattern in `pattern`
    ekCountStar  ## count(*) — its own kind, because there is no operand

  Expr* = ref object
    kind*: ExprKind
    line*, col*: int
    lit*: Value
    uval*: uint64         ## ekLit of vkInt: the unsigned magnitude, so a
                          ## folded `-9223372036854775808` survives the trip
    name*: string
    op*: string          ## the operator text, exactly as written
    negated*: bool
    isDistinct*: bool
    items*: seq[Expr]
    target*: Expr        ## ekProp / ekIndex receiver
    index*: Expr         ## ekIndex key
    pattern*: Pattern    ## ekExists
    pairs*: seq[PropEntry]

  ## -------------------------------------------------------------- patterns

  Direction* = enum
    dirOut, dirIn, dirBoth

  NodePattern* = object
    varName*: string     ## empty = anonymous
    label*: string       ## empty = any label
    props*: seq[PropEntry]
    line*, col*: int

  RelPattern* = object
    varName*: string
    types*: seq[string]  ## empty = any type; `|` alternation
    props*: seq[PropEntry]
    dir*: Direction
    minHops*: int        ## 1 for a plain relationship
    maxHops*: int        ## 0 = unbounded, as in `*`
    varLen*: bool        ## written with `*`, whatever the range says: `*2..2`
                          ## is a two-hop walk with relationship uniqueness,
                          ## not a plain relationship — and min == max could
                          ## not tell the two apart
    line*, col*: int

  PatternElement* = object
    case isNode*: bool
    of true: node*: NodePattern
    of false: rel*: RelPattern

  Pattern* = object
    pathVar*: string     ## `MATCH p = (...)`; empty otherwise
    elems*: seq[PatternElement]

  ## --------------------------------------------------------------- clauses

  SetItem* = object
    ## One assignment. `isMap` with `mapValue` set is `SET a = {…}` or
    ## `SET a += {…}`; `merge` says which. A property assignment is
    ## `SET a.x = expr`.
    target*: PropRef
    expr*: Expr              ## property assignment; empty for the map form
    mapValue*: Expr          ## the map literal for the map form
    isMap*: bool
    merge*: bool

  PropRef* = object
    ## A target: a variable bound to a node or an edge, plus a property
    ## key. Deeper paths (`a.x.y`) are refused rather than walked.
    varName*: string
    key*: string

  SortItem* = object
    expr*: Expr
    desc*: bool

  ReturnItem* = object
    expr*: Expr
    alias*: string       ## `AS name`; empty when absent
    line*, col*: int

  SortSpec* = object
    items*: seq[SortItem]

  Projection* = object
    items*: seq[ReturnItem]
    isDistinct*: bool

  QueryPartKind* = enum
    qpMatch, qpWhere, qpProjection, qpUnwind, qpOrderBy, qpSkip, qpLimit,
    ## M5 write clauses. Same ordering convention: they appear in the part
    ## list in source order, and the planner turns each into an operator
    ## that acts on the rows flowing through it.
    qpCreate, qpSet, qpRemove, qpDelete, qpForeach,
    qpMerge,                       ## M5.3: match, or create when no match
    qpTextCall                     ## M6.2: CALL db.idx.text … YIELD …

  QueryPart* = ref object
    case kind*: QueryPartKind
    of qpMatch:
      optional*: bool           ## OPTIONAL MATCH
      patterns*: seq[Pattern]
      matchCond*: Expr          ## MATCH ... WHERE
    of qpWhere:
      cond*: Expr
    of qpProjection:
      ## RETURN and WITH are the same shape; `withClause` is what makes them
      ## different clauses downstream (a WITH is an aggregation boundary
      ## and changes the scope of everything after it).
      withClause*: bool
      projection*: Projection
      withCond*: Expr           ## WITH ... WHERE
    of qpUnwind:
      list*: Expr
      varName*: string
    of qpOrderBy:
      sort*: SortSpec
    of qpSkip:
      skipAmount*: Expr         ## an expression, so SKIP $n works
    of qpLimit:
      limitAmount*: Expr
    of qpCreate:
      ## `CREATE (a:X {…})-[:R]->(b) , (c)`. The patterns are the *same*
      ## shape MATCH parses, because the grammar is the same — what differs
      ## is what they mean: MATCH's pattern filters, CREATE's binds and
      ## writes. A pattern property here is a value to store, not a
      ## predicate (CYPHER.md §3.1).
      ##
      ## Named `createPatterns`, not `patterns`: a Nim variant object
      ## cannot carry the same field name in two branches, and this one
      ## exists only because `qpMatch` got there first.
      createPatterns*: seq[Pattern]
    of qpSet:
      ## `SET a.x = 1, b.y = 2` and the map forms `SET a = {…}` /
      ## `SET a += {…}`. The two shapes are one operator with a flag,
      ## because they are one operation with two spellings: Cypher.md §3.2
      ## pins the difference between replace and merge as silent data loss
      ## when confused, which is exactly why both are explicit here.
      setItems*: seq[SetItem]
    of qpRemove:
      ## `REMOVE a.x, b.y`. Its own part rather than a `SET` with null:
      ## setting a property to null *stores* a null, and removing it takes
      ## the key away. Those are different states (CYPHER.md §3.2).
      removeItems*: seq[PropRef]
    of qpForeach:
      ## `FOREACH (n IN $nodes | SET n.x = 1)`. A write clause like SET,
      ## applied once per *element* instead of once per row — which is why
      ## its updates are the same `SetItem`s and `PropRef`s, parsed by the
      ## same code.
      ##
      ## The field names are prefixed because a Nim variant object cannot
      ## carry one field name in two branches: `qpSet` already owns
      ## `setItems`, and this branch wants the same shape with a different
      ## owner.
      foreachList*: Expr
      foreachVar*: string
      foreachSet*: seq[SetItem]
      foreachRemove*: seq[PropRef]
    of qpMerge:
      ## `MERGE (n:P {…}) ON CREATE SET … ON MATCH SET …`. The pattern is
      ## stored as patterns, and the actions as the same `SetItem`s SET
      ## uses: an `ON CREATE SET` is a SET that only runs on the create
      ## branch, and reusing the item type means one implementation of
      ## "apply this assignment to this row" rather than two.
      mergePatterns*: seq[Pattern]
      onCreateSet*: seq[SetItem]
      onCreateRemove*: seq[PropRef]
      onMatchSet*: seq[SetItem]
      onMatchRemove*: seq[PropRef]
    of qpDelete:
      ## `DELETE a, b` and `DETACH DELETE a, b`. `detach` is the whole
      ## difference and it is a flag rather than a second clause, because
      ## the two differ in one place: whether a node with relationships is
      ## an error or a cascade.
      deleteVars*: seq[string]
      detach*: bool
    of qpTextCall:
      ## `CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score` and,
      ## since M6.3, the vector form with the same shape (CYPHER.md §4). A
      ## retrieval is a *source*: it produces rows from an index rather
      ## than filtering rows that already exist, which is why it is a part
      ## and not a predicate. `queryExpr` is a parameter or a literal —
      ## the query is data, not an expression to evaluate per row, and
      ## anything else is refused at parse. The two families share one
      ## part because they share one shape; `isVec` picks the operator.
      indexName*: string
      queryExpr*: Expr
      yieldNode*: string
      yieldScore*: string       ## empty when the caller did not yield it
      isVec*: bool

  Query* = ref object
    parts*: seq[QueryPart]
    text*: string               ## the source, kept for the statement cache

  ## ------------------------------------------------------------- builders
  ##
  ## Constructors rather than inline object literals at every call site. A
  ## `Expr` has twelve fields and a caller that fills three of them should
  ## not have to know that the rest default to whatever Nim's `object`
  ## gives them — `lit` in particular must be `vkNull`, and `Value`'s
  ## variant default is not guaranteed to be that.

const
  ## The aggregate function names. Here rather than in the evaluator because
  ## three modules need it and two of them cannot import the third: the
  ## planner asks "is this projection a grouping?", the semantic pass asks
  ## "is an aggregate somewhere it is not allowed?", and the evaluator asks
  ## "is this call one that should have been substituted away?". One list,
  ## so a ninth aggregate cannot be added to one answer and not the others.
  AggregateNames* = ["count", "sum", "avg", "min", "max", "collect",
                     "stdev"]

proc lit*(v: Value): Expr =
  new(result)
  result.kind = ekLit
  result.lit = v

proc litNull*(): Expr =
  ## An explicit null literal. `lit(Value())` would also be null, but only
  ## because `ValueKind`'s first variant is null — a fact that changes the
  ## day someone reorders the enum.
  lit Value(kind: vkNull)

proc varExpr*(name: string): Expr =
  new(result)
  result.kind = ekVar
  result.name = name

proc paramExpr*(name: string): Expr =
  new(result)
  result.kind = ekParam
  result.name = name

proc propExpr*(target: Expr, key: string): Expr =
  new(result)
  result.kind = ekProp
  result.target = target
  result.name = key

proc unary*(op: string, e: Expr): Expr =
  new(result)
  result.kind = ekUnary
  result.op = op
  result.target = e

proc binary*(kind: ExprKind, op: string, l, r: Expr): Expr =
  new(result)
  result.kind = kind
  result.op = op
  result.items = @[l, r]

proc isNull*(e: Expr, negated: bool): Expr =
  new(result)
  result.kind = ekIsNull
  result.target = e
  result.negated = negated

proc listExpr*(items: seq[Expr]): Expr =
  new(result)
  result.kind = ekList
  result.items = items

proc mapExpr*(pairs: seq[PropEntry]): Expr =
  new(result)
  result.kind = ekMap
  result.pairs = pairs

proc funcCall*(name: string, args: seq[Expr]; isDistinct = false): Expr =
  new(result)
  result.kind = ekFunc
  result.name = name
  result.items = args
  result.isDistinct = isDistinct

proc countStar*(): Expr =
  new(result)
  result.kind = ekCountStar

proc existsExpr*(p: Pattern): Expr =
  new(result)
  result.kind = ekExists
  result.pattern = p

proc node*(varName, label: string; props: seq[PropEntry]): NodePattern =
  NodePattern(varName: varName, label: label,
              props: if props.len == 0: @[] else: props)

proc rel*(varName: string; types: seq[string]; dir: Direction;
          minHops = 1, maxHops = 0; props: seq[PropEntry]): RelPattern =
  RelPattern(varName: varName,
             types: if types.len == 0: @[] else: types, dir: dir,
             minHops: minHops, maxHops: maxHops,
             props: if props.len == 0: @[] else: props)

proc pattern*(pathVar: string; elems: seq[PatternElement]): Pattern =
  Pattern(pathVar: pathVar, elems: elems)

proc newQuery*(text: string): Query =
  new(result)
  result.text = text

proc addPart*(q: Query, p: QueryPart) =
  q.parts.add p

proc exprColumn*(item: ReturnItem, index: int): string =
  ## The name a projected expression gets when it has no `AS`. Cypher's rule
  ## is "the expression's text", which for a plain variable or a property
  ## access is the identifier; for anything else it is `expr{n}`, because
  ## the alternative is reconstructing source text the parser threw away.
  ## `index` is the item's position in its projection, so the names are
  ## stable per query rather than per process.
  if item.alias.len > 0:
    return item.alias
  if item.expr.kind == ekVar:
    return item.expr.name
  if item.expr.kind == ekProp and item.expr.target.kind == ekVar:
    return item.expr.target.name & "." & item.expr.name
  "expr" & $index
proc boundVariables*(pat: Pattern): seq[string] =
  ## In binding order, which is what a Filter's predicate may reference.
  ## Exported because the semantic pass and the vector pushdown both need
  ## the same definition of "bound" — one, not two.
  for el in pat.elems:
    if el.isNode:
      if el.node.varName.len > 0:
        result.add el.node.varName
    elif el.rel.varName.len > 0:
      result.add el.rel.varName
