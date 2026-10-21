## gbasic_store.nim — the in-process door for GLYPH BASIC.
##
## The client (gbasic.nim) reaches the graph only through a
## `GbTransport` (PRD-GLYPH-BASIC.md, pin GB1). This module is one
## implementation of that door: it compiles a GLYPH QUERY statement with
## gq.nim and runs it on a `Database`, and it answers the client's
## introspection questions from the engine's own doors.
##
## The guest transport — the eZ80, over a port channel — is the other
## implementation, and it is the reason the door is a door and not a
## direct call into the store.

import std/[tables, strutils, json]
import ./gbasic
import ./gq
import ./database
import ./store/prop
import ./store/store
import ./cypher/ctx
import ./cypher/execute

proc valueText(v: Value): string =
  ## A property's value as text. A number reads as its number, a string
  ## as itself, and the rest as the engine renders them.
  case v.kind
  of vkNull: ""
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: $v.f
  of vkString, vkBytes: v.s
  else: $v.kind

proc paramInt(params: Table[string, Value], name: string): int64 =
  ## A parameter's value, as a number. The link statement's endpoints
  ## arrive as parameters (the client owns the values), so the door reads
  ## them back here.
  let key = if name.len > 0 and name[0] == '$': name[1 .. ^1] else: name
  if not params.hasKey(key):
    raise newException(GbError,
      "glyph basic: no value for '" & key & "'")
  let v = params[key]
  if v.kind == vkInt: v.i
  elif v.kind == vkNode: v.id
  else:
    raise newException(GbError,
      "glyph basic: '" & key & "' is not a node")

proc runStatement(db: Database, cypher: string,
                  params: Table[string, Value], write: bool): (seq[Row], int64) =
  ## Run a compiled statement, committing it if it wrote.
  if not write:
    let st = prepare(db.store, cypher, params)
    defer: st.close()
    return (st.collectRows(), st.rowsAffected())
  let tx = db.beginTransaction()
  var st: Statement
  try:
    st = prepare(db.store, cypher, params, tx, 0, "", db.indices)
    let rows = st.collectRows()
    let n = st.rowsAffected()
    st.close()
    discard db.commitTransaction(tx)
    return (rows, n)
  except CatchableError:
    discard db.rollbackTransaction(tx)
    raise

proc isWrite(cypher: string): bool =
  ## A statement that writes. The words are the ones the engine's own
  ## parser treats as write clauses (CYPHER.md §0.2).
  for w in ["CREATE", "MERGE", "SET ", "REMOVE", "DELETE", "DETACH"]:
    if cypher.toUpperAscii.contains(w):
      return true
  false

proc newStoreTransport*(db: Database): GbTransport =
  ## The in-process door.
  let store = db.store
  result = GbTransport()
  result.runFn = proc(gq: string, params: Table[string, Value]): GbResult =
    let program = compileGq(gq)
    when defined(gbasicDebug):
      echo "  [gq] ", gq, "  ->  ", program.cypher
    ## The client's parameters and the compiler's own live in one map:
    ## the client owns the values it passed in (`$c0` and friends) and
    ## the compiler owns the ones it made for the literals (`$p1` and
    ## friends), and the engine sees both.
    var all = params
    for k, v in program.params:
      all[k] = v
    case program.kind
    of gpkQuery:
      let (rows, n) = runStatement(db, program.cypher, all,
                                  isWrite(program.cypher))
      result.ids = @[]
      for r in rows:
        let (_, v) = r.lookup("id")
        if v.kind == vkInt: result.ids.add v.i
        elif v.kind == vkNode: result.ids.add v.id
        let (_, c) = r.lookup("n")
        if c.kind == vkInt: result.count = c.i
      result.affected = n
    of gpkLabels:
      let text = db.schemaJson(true, false, false)
      let node = parseJson(text)
      if node.hasKey("labels"):
        for l in node["labels"]:
          result.labels.add l.getStr
    of gpkLink:
      ## The link door: two ids and a type, one edge, no planner.
      let fromId = paramInt(all, program.linkFrom)
      let toId = paramInt(all, program.linkTo)
      if not store.nodeExists(fromId):
        raise newException(GbError,
          "glyph basic: no node " & $fromId)
      if not store.nodeExists(toId):
        raise newException(GbError,
          "glyph basic: no node " & $toId)
      let tx = db.beginTransaction()
      try:
        result.linkId = store.createEdge(fromId, toId, program.linkType)
        discard db.commitTransaction(tx)
      except CatchableError:
        discard db.rollbackTransaction(tx)
        raise
      result.affected = 1
  result.labelsFn = proc(): seq[string] =
    ## The labels, read from the store's dictionary rather than through
    ## the schema door: the client wants a list, and the schema's answer
    ## is a JSON document for a caller that wants one.
    for code in 1 .. store.labels.count:
      let nm = store.labels.nameOf(int32(code))
      if nm.len > 0: result.add nm
  result.typesFn = proc(): seq[string] =
    ## The relationship types, the same way the labels are read.
    for code in 1 .. store.relTypes.count:
      let nm = store.relTypes.nameOf(int32(code))
      if nm.len > 0: result.add nm
  result.propsFn = proc(id: int64): seq[(string, string)] =
    ## A node's properties, as text. The engine's own door
    ## (`glyphes_node_props`) renders them as JSON; the client wants them
    ## as pairs, and it wants them in a shape a guest's channel can
    ## carry.
    ## The node's label and its properties, read from the store: the
    ## client wants pairs, and the schema's answer is a JSON document for
    ## a caller that wants one.
    if store.nodeExists(id):
      let rec = store.node(id)
      let label = store.labels.nameOf(rec.label)
      if label.len > 0: result.add ("label", label)
    for k in store.nodePropKeys(id):
      var v = Value(kind: vkNull)
      if store.getNodeProp(id, k, v):
        result.add (k, valueText(v))
  result.edgesFn = proc(id: int64): seq[(string, int64, bool)] =
    ## The node's edges: the type, the other end, and which way it goes.
    for e in store.outEdges(id):
      let rec = store.edge(e)
      result.add (store.relTypes.nameOf(rec.etype), rec.dst, true)
    for e in store.inEdges(id):
      let rec = store.edge(e)
      result.add (store.relTypes.nameOf(rec.etype), rec.src, false)
  result.linkFn = proc(fromId: int64, rtype: string, toId: int64): int64 =
    if not store.nodeExists(fromId):
      raise newException(GbError, "glyph basic: no node " & $fromId)
    if not store.nodeExists(toId):
      raise newException(GbError, "glyph basic: no node " & $toId)
    let tx = db.beginTransaction()
    try:
      result = store.createEdge(fromId, toId, rtype)
      discard db.commitTransaction(tx)
    except CatchableError:
      discard db.rollbackTransaction(tx)
      raise
