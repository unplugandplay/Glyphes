## glyphes — the statement lifecycle (EXEC.md §1, ABI.md B3)
##
## `prepare` parses, checks and plans; `step` pulls one row; `close`
## releases. Nothing here holds a result set, and nothing here copies a row
## the caller has not asked for.
##
## **The snapshot is taken in `prepare` and released in `close`** (TXN.md
## §2). That is the whole reason a `PropView`'s arena offsets are safe to
## read: `beginRead` holds the store mutex until `endRead`, and the commit's
## merge takes the same mutex, so the arena cannot move under a live
## statement. The price is TXN.md §4's recorded deviation — readers serialise
## — and the rule that falls out of it: **a statement must not be held open
## across a same-thread commit**, because the mutex is not reentrant and that
## deadlocks. `Database#transaction` on a handle with a live statement is that
## bug, and it is why `RUBY.md` closes statements in `ensure`.
##
## The semantic pass runs at prepare, not at step. A query that references an
## unknown variable should fail before a single row is produced, not on the
## first row that happens to reach the predicate — and a prepare that returns
## an error costs nothing, while a step that returns one halfway through a
## stream has already produced rows the caller is holding.

import std/[os, tables, strutils]
import ../store/store
import ../index/index
import ../abi
import ../store/prop
import ./errors
import ./ast
import ./parser
import ./ctx
import ../txn/txn
import ./ops
import ./expr
import ./plan
import ./params

type
  Statement* = ref object
    ## One prepared query. Single-use: `step` until false, then `close`. A
    ## re-execute is a second `prepare`, which is what makes the snapshot
    ## rule easy to state.
    ctx*: QueryCtx
    root*: Operator
    columns*: seq[string]
    sql*: string
    params*: Table[string, Value]
    closed*: bool
    exhausted*: bool
    rowsProduced*: int64
    ## The row the last `step` produced. Owned here, borrowed by the caller
    ## (ABI.md B3): it dies with `close`, and the boundary copies out of it
    ## during `step`.
    current*: Row
    ## Statement-owned strings that the current row's cells point into.
    ## Replaced on every `step`, which is exactly the lifetime ABI.md B3
    ## promises: a cell is valid until the next `step` or `close`.
    texts*: seq[string]

# --------------------------------------------------------- semantic checks

proc rejectAggregate(e: Expr) =
  ## An aggregate is legal in exactly one place: the projection of a RETURN
  ## or a WITH, where it *is* the grouping. Everywhere else it is refused
  ## here, by name, because the alternative is a number that looks right —
  ## `WHERE count(*) > 1` evaluated per row is always false, which is a
  ## silently empty result rather than an error, and an empty result is the
  ## kind of bug that ships.
  if e.kind == ekCountStar:
    unsupported("an aggregate outside RETURN or WITH, where it has no rows to fold")
  if e.kind == ekFunc and e.name.toLowerAscii in AggregateNames:
    unsupported("the aggregate " & e.name & "() outside RETURN or WITH, " &
                "where it has no rows to fold")
  case e.kind
  of ekProp, ekUnary:
    rejectAggregate(e.target)
  of ekBinary, ekCompare, ekAnd, ekOr, ekXor:
    for item in e.items:
      rejectAggregate(item)
  of ekNot, ekIsNull:
    rejectAggregate(e.target)
  of ekIndex:
    rejectAggregate(e.target)
    rejectAggregate(e.index)
  of ekList:
    for item in e.items:
      rejectAggregate(item)
  of ekMap:
    for (_, v) in e.pairs:
      rejectAggregate(v)
  of ekFunc:
    for item in e.items:
      rejectAggregate(item)
  else:
    discard

proc checkWriteTarget(name: string, scope: seq[string], clause: string) =
  if name notin scope:
    parseFail(clause & " target " & name & " is not defined by any MATCH")

proc semanticCheck(q: Query) =
  ## One pass over the parts, in order, tracking what is in scope. Cypher's
  ## scoping is simple enough that this is a list, and the failure it
  ## prevents — `MATCH (a) RETURN b` returning an all-null column instead of
  ## an error — is the most expensive kind of query bug to find later.
  var scope: seq[string] = @[]
  for part in q.parts:
    case part.kind
    of qpMatch:
      ## MATCH's own WHERE lands here, not on a separate part, so it needs the
      ## same aggregate refusal the standalone WHERE clause gets.
      if part.matchCond != nil:
        rejectAggregate(part.matchCond)
      for pat in part.patterns:
        ## A path binding (`MATCH p = (…)`) is refused by the planner,
        ## which names the construct. The semantic pass must not see it as
        ## an unbound variable first: "p is not defined by any MATCH" is a
        ## diagnosis about the wrong thing, and pin C1 wants the refusal to
        ## name what was refused.
        if pat.pathVar.len > 0 and pat.pathVar notin scope:
          scope.add pat.pathVar
        for name in boundVariables(pat):
          if name notin scope:
            scope.add name
      if part.matchCond != nil:
        var used: seq[string] = @[]
        collectVars(part.matchCond, used)
        for name in used:
          if name notin scope:
            parseFail("variable " & name & " is not defined by any MATCH")
    of qpWhere:
      rejectAggregate(part.cond)
      var used: seq[string] = @[]
      collectVars(part.cond, used)
      for name in used:
        if name notin scope:
          parseFail("variable " & name & " is not defined by any MATCH")
    of qpTextCall:
      ## A retrieval binds what it yields, in order, before anything after
      ## it sees the scope: `WHERE score > 0.5` two lines down is checked
      ## against the names this clause put in scope, exactly as a MATCH's
      ## pattern variables are.
      if part.yieldNode.len > 0 and part.yieldNode notin scope:
        scope.add part.yieldNode
      if part.yieldScore.len > 0 and part.yieldScore notin scope:
        scope.add part.yieldScore
    of qpSet:
      ## Every target must already be bound: `SET x.a = 1` with no `x` is a
      ## typo, and finding out at the first row (or never, if the read phase
      ## produced no rows) is the kind of late failure a query language
      ## should not have.
      for item in part.setItems:
        checkWriteTarget(item.target.varName, scope, "SET")
    of qpRemove:
      for target in part.removeItems:
        checkWriteTarget(target.varName, scope, "REMOVE")
    of qpForeach:
      ## The loop's variable is bound *inside* the clause and taken back
      ## out afterwards: a `SET` or a `RETURN` after the FOREACH that
      ## names it is a typo, and it should be refused at prepare time
      ## rather than fail at run time on the first row.
      ##
      ## `existed` matters: a `FOREACH (n IN …)` whose variable is already
      ## bound shadows it inside the loop and must leave the outer binding
      ## alone afterwards, so the scope is restored, not emptied.
      let existed = part.foreachVar in scope
      if not existed:
        scope.add part.foreachVar
      for item in part.foreachSet:
        checkWriteTarget(item.target.varName, scope, "SET")
      for target in part.foreachRemove:
        checkWriteTarget(target.varName, scope, "REMOVE")
      if not existed:
        let at = scope.find(part.foreachVar)
        if at >= 0:
          scope.delete(at)
    of qpDelete:
      for name in part.deleteVars:
        checkWriteTarget(name, scope, "DELETE")
    of qpCreate:
      ## A CREATE *binds*: every variable its patterns name is in scope from
      ## here on. Without this arm `CREATE (m:Made {v: 1}) RETURN m.v` —
      ## the shape of every write that checks its own work — is refused for
      ## naming a variable "not defined by any MATCH", which is both wrong
      ## and, for a caller, baffling: the query they wrote bound it.
      ##
      ## Its own arm rather than a shared `of qpCreate, qpMerge`: a Nim
      ## variant object lets a branch read only its own fields, so an arm
      ## covering two kinds may not mention either one's fields.
      for pat in part.createPatterns:
        for name in boundVariables(pat):
          if name notin scope:
            scope.add name
    of qpMerge:
      ## MERGE binds the same way, and its ON CREATE / ON MATCH actions are
      ## checked against the scope the MERGE just established.
      for pat in part.mergePatterns:
        for name in boundVariables(pat):
          if name notin scope:
            scope.add name
      for item in part.onCreateSet:
        checkWriteTarget(item.target.varName, scope, "ON CREATE SET")
      for item in part.onMatchSet:
        checkWriteTarget(item.target.varName, scope, "ON MATCH SET")
      for target in part.onCreateRemove:
        checkWriteTarget(target.varName, scope, "ON CREATE REMOVE")
      for target in part.onMatchRemove:
        checkWriteTarget(target.varName, scope, "ON MATCH REMOVE")
    of qpUnwind:
      if part.varName notin scope:
        scope.add part.varName
    of qpProjection:
      for item in part.projection.items:
        ## No rejection here: an aggregate in RETURN or WITH is the feature.
        var used: seq[string] = @[]
        collectVars(item.expr, used)
        for name in used:
          if name notin scope:
            parseFail("variable " & name & " is not defined by any MATCH")
      if part.withClause:
        ## A WITH replaces the scope with what it projects.
        scope = @[]
        for i, item in part.projection.items:
          let name = exprColumn(item, i)
          if name notin scope:
            scope.add name
      else:
        ## A RETURN keeps the source scope and *adds* its columns: the tail
        ## (ORDER BY) sits above the projection, where both are addressable
        ## — the alias because the projection produced it, the source
        ## variable because the projection row carries its bindings through
        ## (ops.nim, okProject). Only ORDER BY reads the union; a later
        ## clause that sees scope here would be a second MATCH, which the
        ## slice refuses before this pass runs.
        for i, item in part.projection.items:
          let name = exprColumn(item, i)
          if name notin scope:
            scope.add name
    of qpOrderBy:
      ## ORDER BY runs against the *projected* columns, so its expressions
      ## are checked against the scope as it stands after the projection.
      for item in part.sort.items:
        var used: seq[string] = @[]
        collectVars(item.expr, used)
        for name in used:
          if name notin scope:
            parseFail("ORDER BY refers to undefined variable " & name)
    else:
      discard

# ------------------------------------------------------------- lifecycle

proc prepare*(store: GraphStore, sql: string,
              params: Table[string, Value] = initTable[string, Value](),
              writer: WriteTransaction = nil, spillRows = 0,
              spillDir = "", indices: Indexes = nil): Statement =
  ## Parse, check, plan, and take the read snapshot. This is where a query
  ## is allowed to fail; after it returns, `step` cannot.
  ##
  ## `writer` is nil for a read statement. A write statement takes the
  ## transaction that will carry its writes; the statement does not commit
  ## or roll it back, because who owns the transaction is the caller's
  ## decision (the autocommit door commits on success, a Ruby `db.exec`
  ## inside a `db.transaction` block leaves that block to commit).
  new(result)
  result.sql = sql
  result.params = params
  let parsed = parseQuery(sql)
  semanticCheck(parsed)

  new(result.ctx)
  result.ctx.store = store
  result.ctx.indices = indices
  result.ctx.writer = writer
  result.ctx.stmtId = nextStmtId()
  ## The sort budget comes from the caller, not from a constant here: a
  ## benchmark that wants to prove spilling must be able to *ask* for it
  ## with a budget its data actually exceeds.
  result.ctx.sortSpillRows = spillRows
  result.ctx.spillDir = (if spillDir.len > 0: spillDir
                         else: getTempDir())
  ## One snapshot for the statement's whole life. See the header comment:
  ## this is what makes property reads safe, and what makes holding a
  ## statement across a same-thread commit a deadlock.
  result.ctx.snap = beginRead(store)
  result.ctx.params = params

  ## From here to the end of prepare, a failure must release the snapshot
  ## before the statement ref is dropped. There is no destructor to do it:
  ## `endRead` is the only thing that decrements the reader count, and a
  ## count stuck above zero parks every future `beginWrite` on this store
  ## forever. Everything the planner refuses (path binding, variable
  ## length, alternation, a second MATCH) raises inside `plan`, which is
  ## exactly the queries a caller is told to expect a clean error for.
  try:
    let planned = plan(result.ctx, parsed)
    result.root = planned.root
    result.columns = planned.columns
  except CatchableError as e:
    endRead(result.ctx.snap)
    result.ctx.snap = nil
    raise e
  result.current = initRow(len(result.columns))

proc prepare*(store: GraphStore, sql: string,
              writer: WriteTransaction): Statement =
  ## The write form, for callers with no parameters: `prepare(s, sql, tx)`
  ## reads better than threading an empty table through to reach the
  ## transaction, and the two forms differ in nothing else.
  prepare(store, sql, initTable[string, Value](), writer)

proc step*(st: Statement): bool =
  ## Pull one row. False at end of stream, and false forever after.
  if st.closed or st.exhausted:
    return false
  if not st.root.next():
    st.exhausted = true
    return false
  ## Copy the root's row into the statement's own. The root's `current` is
  ## reused on the next `step`, and ABI.md B3 makes the caller borrow until
  ## the *next* step — so the copy is what lets a caller hold two rows and
  ## compare them, at the cost of one row copy per row.
  st.current = copyRow(st.root.current)
  inc st.rowsProduced
  true

proc close*(st: Statement) =
  ## Idempotent: an error path that closes and a `defer` that closes again
  ## must not release the read lock twice, or the next merge would run with
  ## readers still inside the published arrays.
  if st.closed:
    return
  st.closed = true
  ## Before dropping the plan: a sort's spilled runs live on the operators,
  ## and `st.root = nil` is the last moment they can be reached.
  releaseSpills(st.root)
  st.root = nil
  if st.ctx != nil and st.ctx.snap != nil:
    endRead(st.ctx.snap)
    st.ctx.snap = nil
  st.ctx = nil

proc columns*(st: Statement): seq[string] = st.columns

proc rowsAffected*(st: Statement): int64 =
  ## Entities created, deleted or updated by this statement (TXN.md §3).
  ## Property writes do not count: `SET n.age = 1` updates one node, and
  ## an importer asking "how much landed" wants entities.
  if st.ctx == nil: 0 else: st.ctx.rowsAffected

proc collectRows*(st: Statement): seq[Row] =
  ## For the tests and for the Nim-level oracle. Deliberately *not* what the
  ## ABI uses: a caller that wants every row asks for it.
  while st.step():
    result.add copyRow(st.current)

proc rowsProduced*(st: Statement): int64 = st.rowsProduced
# ------------------------------------------------------- the cell protocol

proc cellBuffer*(st: Statement): ptr UncheckedArray[GlyCell] =
  ## The statement's cell array, grown once and reused. ABI.md B2: one FFI
  ## crossing per batch, the caller provides the array, and the engine
  ## fills it. `glyphes_stmt_step` copies into the caller's array, so this
  ## is only the staging area that keeps the conversion out of the
  ## boundary.
  nil

proc rowJson*(row: Row, columns: seq[string]): string =
  ## One result row as a JSON array, in column order. The runner compares
  ## against expectations written the same way, so column order is part of
  ## the file's format rather than an accident.
  result = "["
  for i, name in columns:
    if i > 0: result.add ","
    let (found, v) = row.lookup(name)
    result.add valueJson(if found: v else: Value(kind: vkNull))
  result.add "]"

proc toCell(v: Value, texts: var seq[string]): GlyCell =
  ## One `Value` becomes one 24-byte cell. Strings and vectors are copied
  ## into `texts`, which the statement owns; the cell points at the copy.
  ## ABI.md B3: everything a cell points at is statement memory, invalidated
  ## by the next `step` — which is exactly when `texts` is replaced.
  ##
  ## A node or an edge crosses as its id with the `GLY_NODE`/`GLY_EDGE` tag
  ## and `aux` carrying the id, because a cell has no room for anything
  ## more and the ABI's contract is identity, not a copy of the record.
  result.tag = uint32(ord(propType(v.kind)))
  result.len = 0
  result.ptr = nil
  result.aux = 0
  case v.kind
  of vkNull:
    result.tag = uint32(ord(glyNull))
  of vkBool:
    result.aux = (if v.b: 1'u64 else: 0'u64)
  of vkInt:
    result.aux = cast[uint64](v.i)
  of vkFloat:
    result.aux = cast[uint64](v.f)
  of vkString, vkBytes:
    texts.add v.s
    let s = addr texts[^1]
    if v.s.len > 0:
      result.ptr = cast[pointer](unsafeAddr (s[])[0])
    result.len = uint32(v.s.len)
  of vkVector:
    ## A vector crosses as a list of doubles in statement memory, `len`
    ## carrying the dimension. The property model stores f32; the ABI's
    ## GLY_VECTOR cell is dim-addressed, so the conversion is here rather
    ## than in the binding.
    var doubles = newSeq[float64](v.dims.len)
    for i in 0 ..< v.dims.len:
      doubles[i] = float64(v.dims[i])
    let blob = cast[ptr UncheckedArray[float64]](addr doubles[0])
    texts.setLen(texts.len + 1)
    let holder = addr texts[^1]
    holder[].setLen(doubles.len * sizeof(float64))
    copyMem(addr holder[][0], unsafeAddr blob[0], holder[].len)
    result.ptr = cast[pointer](addr holder[][0])
    result.len = uint32(v.dims.len)
  of vkList:
    ## A list crosses as a JSON array — the one format every host can walk
    ## without a second accessor set. `len` is the byte length, `ptr` the
    ## text. Rendering a value tree twice (once for the cell, once for the
    ## host's parser) is the cost of not growing the ABI for it, and lists
    ## in RETURN are rare enough that the trade is documented rather than
    ## hidden.
    texts.add valueJson(v)
    let s = addr texts[^1]
    result.ptr = cast[pointer](unsafeAddr (s[])[0])
    result.len = uint32(s[].len)
  of vkMap:
    ## Same rule as a list, as an object. Nested values render through the
    ## same function, which is why a list inside a map is as correct as a
    ## list on its own.
    texts.add valueJson(v)
    let s = addr texts[^1]
    result.ptr = cast[pointer](unsafeAddr (s[])[0])
    result.len = uint32(s[].len)
  of vkNode:
    result.tag = uint32(ord(glyNode))
    result.aux = cast[uint64](v.id)
  of vkEdge:
    result.tag = uint32(ord(glyEdge))
    result.aux = cast[uint64](v.id)
  of vkPath:
    ## Paths cross through the component accessors (ABI.md §2), so the cell
    ## carries the id lists in statement memory and `glyphes_cell_path`
    ## hands them out. `len` is the node count.
    let n = v.path.nodes.len
    var blob: string = ""
    blob.setLen(n * sizeof(int64) + max(0, n - 1) * sizeof(int64) + max(0, n - 1))
    if n > 0:
      copyMem(addr blob[0], unsafeAddr v.path.nodes[0], n * sizeof(int64))
    if n > 1:
      copyMem(addr blob[n * sizeof(int64)], unsafeAddr v.path.edges[0],
              (n - 1) * sizeof(int64))
      copyMem(addr blob[n * sizeof(int64) + (n - 1) * sizeof(int64)],
              unsafeAddr v.path.dirs[0], n - 1)
    texts.add blob
    let s = addr texts[^1]
    result.ptr = cast[pointer](unsafeAddr (s[])[0])
    result.len = uint32(n)

proc stepCells*(st: Statement, outCells: ptr UncheckedArray[GlyCell],
                cap: int, outRows: var int): int32 =
  ## Pull one row and fill `outCells[0 ..< columns.len]`.
  ##
  ## Returns `GLY_MORE` when the row is valid and more may follow, `GLY_DONE`
  ## at end of stream — the ABI's contract (ABI.md §2). One row per call, so
  ## a caller that wants batching calls in a loop; the cells are the batch
  ## unit, and the row count here is always 0 or 1.
  if st.closed or st.exhausted:
    outRows = 0
    return int32(glyDone)
  if not st.step():
    outRows = 0
    return int32(glyDone)
  if cap < st.columns.len:
    ## A cap smaller than the column count is a caller bug, reported rather
    ## than silently truncating the row — a half-filled cell array looks
    ## like a query that returned fewer columns, which is the worst kind of
    ## wrong answer.
    outRows = 0
    return int32(glyErr)
  st.texts.setLen(0)
  var i = 0
  for name in st.columns:
    let (_, v) = st.current.lookup(name)
    outCells[i] = toCell(v, st.texts)
    inc i
  outRows = 1
  return int32(glyMore)
