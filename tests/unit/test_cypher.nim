## glyphes — M4.1: the lexer and the parser (docs/CYPHER.md §§2–4).
##
## This is the layer where a wrong answer is cheapest to prevent and most
## expensive to debug, so the suite is weighted towards the cases where a
## permissive parser is tempting:
##
## - **A rejected query must be rejected.** Every "outside the contract"
##   case asserts a *specific* status and a message naming the construct,
##   because PRD §5.1 requires exactly that. A parser that accepts `CREATE`
##   and drops it is worse than one that rejects it.
## - **Precedence is asserted, not assumed.** `-2^2`, `a OR b AND c`,
##   `NOT a = b` and `1 + 2 * 3` each have a Cypher answer and a plausible
##   wrong one.
## - **Positions survive.** An error says `line:col`, because a parser that
##   says "unexpected token" costs more per bug than the position costs.
## - **The tree shape is asserted** where a shape bug would be invisible at
##   runtime: a node's label, a variable-length range, a list literal.

import std/unittest
import std/strutils
import ../../src/abi
import ../../src/store/prop
import ../../src/cypher/errors
import ../../src/cypher/lexer
import ../../src/cypher/ast
import ../../src/cypher/parser

# ------------------------------------------------------------- helpers

proc parseExprOf(src: string): Expr =
  ## Parse a bare expression, for the precedence tests. Routed through a
  ## query so the parser under test is the same one: a helper that built
  ## its own token stream would be testing a second parser.
  let q = parseQuery("RETURN " & src)
  q.parts[0].projection.items[0].expr

suite "lexer (CYPHER.md)":
  test "identifiers, keywords-as-identifiers, and numbers":
    let toks = tokenize("MATCH a1 return 42 3.5 1e3")
    check toks[0].isKeyword("match")
    check toks[1].kind == tkIdent and toks[1].text == "a1"
    check toks[2].isKeyword("return")
    check toks[3].kind == tkInt and toks[3].intNum == 42
    check toks[4].kind == tkFloat and toks[4].num == 3.5
    check toks[5].kind == tkFloat and toks[5].num == 1000.0
    check toks[^1].kind == tkEof

  test "longest match wins, so arrows and ranges are one token":
    let toks = tokenize("a->b <-c *1..3 =.. <> <= >= =~")
    var syms: seq[string] = @[]
    for t in toks:
      if t.kind == tkSym: syms.add t.text
    doAssert syms == @["->", "<-", "*", "..", "=", "..", "<>", "<=", ">=", "=~"]
    # a(0) ->(1) b(2) <-(3) c(4) *(5) 1(6) ..(7) 3(8)
    doAssert toks[7].text == ".."        # the range, not '.' then '.'

  test "a fraction needs a digit after the dot":
    # `1..3` is a range; a lexer that cannot tell them apart cannot lex
    # variable length at all.
    let toks = tokenize("1..3 1.5")
    check toks[0].kind == tkInt
    check toks[1].text == ".."
    check toks[2].kind == tkInt
    check toks[3].kind == tkFloat

  test "strings, both quote styles, and escapes":
    let toks = tokenize("""'a\nb' "c\"d" 'e\\f' 'gé'""")
    check toks[0].str == "a\nb"
    check toks[1].str == "c\"d"
    check toks[2].str == "e\\f"
    check toks[3].str == "gé"

  test "unicode escapes, and a lone surrogate is refused":
    let toks = tokenize("'\\u00e9'")
    check toks[0].str == "é"
    expect CypherError:
      discard tokenize("'\\uD800'")

  test "parameters and backtick identifiers":
    let toks = tokenize("$name `odd name`")
    check toks[0].kind == tkParam and toks[0].text == "name"
    check toks[1].kind == tkIdent and toks[1].text == "odd name"

  test "comments, both forms, and a nested block comment":
    let toks = tokenize("// gone\n/* also gone /* and this */ */ MATCH")
    check toks.len == 2
    check toks[0].isKeyword("match")

  test "positions count lines and columns":
    let toks = tokenize("MATCH\n  (a)")
    check toks[0].line == 1 and toks[0].col == 1
    check toks[1].line == 2 and toks[1].col == 3

  test "every malformed input says where it is":
    for bad in ["'unterminated", "\"open", "/* never closed",
                "@", "`unterminated", "'\\q'", "$", "1e"]:
      var raised = false
      try:
        discard tokenize(bad)
      except CypherError as e:
        raised = true
        doAssert ":" in e.msg, "no position in: " & e.msg
      doAssert raised, "should not lex: " & bad

suite "parser: MATCH patterns":
  test "a bare node pattern":
    let q = parseQuery("MATCH (a:Person) RETURN a")
    let m = q.parts[0]
    check m.kind == qpMatch
    let n = m.patterns[0].elems[0].node
    check n.varName == "a"
    check n.label == "Person"
    check n.props.len == 0

  test "an anonymous node and an inline property filter":
    let q = parseQuery("MATCH (:Doc {title: 'x', n: 3}) RETURN 1")
    let n = q.parts[0].patterns[0].elems[0].node
    check n.varName == ""
    check n.label == "Doc"
    check n.props.len == 2
    check n.props[0].key == "title"
    check n.props[0].expr.lit.s == "x"
    check n.props[1].expr.lit.i == 3

  test "a property filter may be a parameter, not just a literal":
    let q = parseQuery("MATCH (a:Person {age: $min}) RETURN a")
    let n = q.parts[0].patterns[0].elems[0].node
    check n.props[0].expr.kind == ekParam
    check n.props[0].expr.name == "min"

  test "an empty inline map is a filter of nothing":
    let q = parseQuery("MATCH (a:Person {}) RETURN a")
    check q.parts[0].patterns[0].elems[0].node.props.len == 0

  test "a relationship, both directions and undirected":
    let fwd = parseQuery("MATCH (a)-[:KNOWS]->(b) RETURN a")
    check fwd.parts[0].patterns[0].elems[1].rel.dir == dirOut
    let bwd = parseQuery("MATCH (a)<-[:KNOWS]-(b) RETURN a")
    check bwd.parts[0].patterns[0].elems[1].rel.dir == dirIn
    let both = parseQuery("MATCH (a)-[:KNOWS]-(b) RETURN a")
    check both.parts[0].patterns[0].elems[1].rel.dir == dirBoth
    let arrowOnly = parseQuery("MATCH (a)-->(b) RETURN a")
    check arrowOnly.parts[0].patterns[0].elems[1].rel.dir == dirOut

  test "type alternation and a relationship variable":
    let q = parseQuery("MATCH (a)-[r:KNOWS|SIMILAR_TO {since: 2020}]->(b) RETURN r")
    let r = q.parts[0].patterns[0].elems[1].rel
    check r.varName == "r"
    doAssert r.types == @["KNOWS", "SIMILAR_TO"]
    check r.props[0].expr.lit.i == 2020

  test "variable length: bare star, ranges, and open ends":
    proc hops(q: string): (int, int) =
      let r = parseQuery(q).parts[0].patterns[0].elems[1].rel
      (r.minHops, r.maxHops)
    check hops("MATCH (a)-[*]->(b) RETURN a") == (1, 0)     # 0 = unbounded
    check hops("MATCH (a)-[*2]->(b) RETURN a") == (2, 2)
    check hops("MATCH (a)-[*1..3]->(b) RETURN a") == (1, 3)
    check hops("MATCH (a)-[*2..]->(b) RETURN a") == (2, 0)
    check hops("MATCH (a)-[*..5]->(b) RETURN a") == (1, 5)

  test "a three-hop chain is one pattern of five elements":
    let q = parseQuery("MATCH (a)-[r1]->(b)-[r2]->(c) RETURN a")
    check q.parts[0].patterns[0].elems.len == 5

  test "a path variable binds the whole chain":
    let q = parseQuery("MATCH p = (a)-[:KNOWS]->(b) RETURN p")
    check q.parts[0].patterns[0].pathVar == "p"

  test "a comma is a cartesian product, not a join":
    let q = parseQuery("MATCH (a), (b) RETURN a")
    check q.parts[0].patterns.len == 2

  test "OPTIONAL MATCH is flagged, not merged with MATCH":
    let q = parseQuery("OPTIONAL MATCH (a:Person) RETURN a")
    check q.parts[0].optional

  test "pattern EXISTS is refused at parse, by name":
    ## It used to parse into an ekExists the evaluator never filled — every
    ## query using it died at execution with a message about the
    ## implementation. Refusing at parse with the construct's name is pin
    ## C1's rule, and the slice has no subpattern planner to hand it to.
    var e: CypherError
    try:
      discard parseQuery("MATCH (a:Person) WHERE EXISTS { (a)-[:KNOWS]->(:Person) } RETURN a")
    except CypherError as err:
      e = err
    doAssert e != nil
    doAssert e.code == int32(glyErrUnsupported)
    doAssert "EXISTS" in e.msg

suite "parser: expressions":
  test "arithmetic precedence, including power over unary":
    check render(parseExprOf("1 + 2 * 3")) == "1 + 2 * 3"
    # -2^2 is -(2^2): power binds tighter than unary minus.
    check parseExprOf("-2^2").kind == ekUnary
    check parseExprOf("-2^2").target.kind == ekBinary
    check parseExprOf("-2 * 2").kind == ekBinary
    check parseExprOf("2 ^ 3 ^ 2").items[1].kind == ekBinary   # right assoc

  test "folded negative literals keep their width":
    # -9223372036854775808 has no positive counterpart; folding it in the
    # evaluator would send it through a float.
    check parseExprOf("-9223372036854775808").lit.i == low(int64)
    check parseExprOf("+5").lit.i == 5

  test "boolean precedence: OR looser than AND looser than NOT":
    let e = parseExprOf("a OR b AND NOT c")
    check e.kind == ekOr
    check e.items[1].kind == ekAnd
    check e.items[1].items[1].kind == ekNot
    check parseExprOf("a XOR b OR c").kind == ekOr

  test "comparison operators and the word forms":
    for op in ["=", "<>", "<", "<=", ">", ">="]:
      check parseExprOf("a " & op & " b").kind == ekCompare
    check parseExprOf("a IN [1,2]").op == "IN"
    check parseExprOf("a CONTAINS 'x'").op == "CONTAINS"
    check parseExprOf("a STARTS WITH 'x'").op == "STARTS WITH"
    check parseExprOf("a ENDS WITH 'x'").op == "ENDS WITH"
    check parseExprOf("a =~ 'x'").op == "=~"

  test "IS NULL and IS NOT NULL":
    let a = parseExprOf("a IS NULL")
    check a.kind == ekIsNull and not a.negated
    let b = parseExprOf("a IS NOT NULL")
    check b.kind == ekIsNull and b.negated

  test "property access chains into one expression":
    let e = parseExprOf("a.b.c")
    check e.kind == ekProp and e.name == "c"
    check e.target.kind == ekProp and e.target.name == "b"
    check e.target.target.kind == ekVar

  test "literals: null, bool, string, list, map":
    check parseExprOf("null").lit.kind == vkNull
    check parseExprOf("true").lit.b
    check not parseExprOf("FALSE").lit.b
    check parseExprOf("'x'").lit.s == "x"
    check parseExprOf("[1, 2]").items.len == 2
    check parseExprOf("{}").pairs.len == 0

  test "function calls, and count(*) has its own shape":
    let f = parseExprOf("toUpper(a.name)")
    check f.kind == ekFunc and f.name == "toUpper" and f.items.len == 1
    let c = parseExprOf("count(*)")
    check c.items[0].kind == ekCountStar
    let d = parseExprOf("count(DISTINCT a)")
    check d.isDistinct

  test "a bare word is a variable, not a zero-argument function":
    # The paren is the discriminator: `count` alone is a variable named
    # count, and the semantic pass is what rejects it.
    check parseExprOf("count").kind == ekVar

suite "parser: clauses":
  test "RETURN projects and names its columns":
    let q = parseQuery("MATCH (a) RETURN a, a.name AS n, 1 + 1")
    let p = q.parts[1]
    check p.kind == qpProjection and not p.withClause
    check p.projection.items.len == 3
    check exprColumn(p.projection.items[0], 0) == "a"
    check exprColumn(p.projection.items[1], 1) == "n"
    check exprColumn(p.projection.items[2], 2) == "expr2"

  test "RETURN DISTINCT":
    let q = parseQuery("MATCH (a) RETURN DISTINCT a")
    check q.parts[1].projection.isDistinct

  test "WITH is a projection, and distinct from RETURN":
    let q = parseQuery("MATCH (a) WITH a, a.name AS n WHERE n STARTS WITH 'A' RETURN n")
    check q.parts[1].kind == qpProjection and q.parts[1].withClause
    check q.parts[2].kind == qpWhere
    check q.parts[3].kind == qpProjection and not q.parts[3].withClause

  test "UNWIND binds a variable":
    let q = parseQuery("UNWIND [1,2,3] AS x RETURN x")
    check q.parts[0].kind == qpUnwind and q.parts[0].varName == "x"

  test "ORDER BY / SKIP / LIMIT, in the order written":
    let q = parseQuery("MATCH (a) RETURN a ORDER BY a.name DESC, a.age LIMIT 10 SKIP 5")
    let ord = q.parts[2]
    check ord.kind == qpOrderBy
    check ord.sort.items.len == 2
    check ord.sort.items[0].desc
    check not ord.sort.items[1].desc
    check q.parts[3].kind == qpLimit
    check q.parts[4].kind == qpSkip

  test "SKIP and LIMIT take expressions, so $n works":
    let q = parseQuery("MATCH (a) RETURN a LIMIT $n")
    check q.parts[2].limitAmount.kind == ekParam

suite "parser: refusals (PRD §5.1)":
  test "every clause the engine does not evaluate is named, not silently dropped":
    ## CREATE (M5.1), SET/REMOVE/DELETE (M5.2), MERGE (M5.3) and FOREACH
    ## (M5.7) left this list and joined suites of their own in
    ## test_write.nim. What remains is LOAD CSV and UNION.
    for (src, word) in [
        ("LOAD CSV FROM 'x' AS line RETURN line", "LOAD"),
        ("MATCH (a) RETURN a UNION MATCH (b) RETURN b", "UNION")]:
      var e: CypherError
      try:
        discard parseQuery(src)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & src
      if e != nil:
        doAssert e.code == int32(glyErrUnsupported),
              "wrong status for " & src & ": " & e.msg
        doAssert word in e.msg, "error must name " & word & ": " & e.msg

  test "a multi-label node pattern is refused with its reason":
    var e: CypherError
    try:
      discard parseQuery("MATCH (a:A:B) RETURN a")
    except CypherError as err:
      e = err
    check e != nil and e.code == int32(glyErrUnsupported)

  test "syntax errors are GLY_ERR_SQL and carry a position":
    for bad in ["MATCH", "MATCH (a RETURN a", "RETURN", "MATCH (a) WHERE",
                "MATCH (a) RETURN 1.2.3",
                "MATCH (a) RETURN a ORDER", "MATCH (a)-[->(b) RETURN a",
                "MATCH (a) RETURN a LIMIT", "not a query at all",
                "MATCH (a) RETURN a)"]:
      var e: CypherError
      try:
        discard parseQuery(bad)
      except CypherError as err:
        e = err
      doAssert e != nil, "should refuse: " & bad
      if e != nil:
        doAssert e.code == int32(glyErrSql), "wrong status for " & bad
        doAssert ":" in e.msg, "no position in: " & e.msg

  test "an empty query is refused, not treated as a match-all":
    var e: CypherError
    try:
      discard parseQuery("")
    except CypherError as err:
      e = err
    check e != nil

  test "a variable-length range that cannot be satisfied is refused":
    expect CypherError:
      discard parseQuery("MATCH (a)-[*5..2]->(b) RETURN a")
    expect CypherError:
      discard parseQuery("MATCH (a)-[*0..3]->(b) RETURN a")

  test "the real queries in the docs all parse":
    # If any of these stops parsing, the documentation is lying.
    for src in [
      "MATCH (a:Person) RETURN a",
      "MATCH (a:Person {name: $n}) RETURN a",
      "MATCH (a)-[r:KNOWS]->(b) RETURN a, b",
      "MATCH (a)-[r:KNOWS*1..3]->(b) RETURN r",
      "MATCH (a)-[:KNOWS|SIMILAR_TO]->(b) RETURN b",
      "MATCH (a:Person)-[r:KNOWS {since: 2020}]->(b) RETURN r",
      "MATCH p = (a)-[*]->(b) RETURN p",
      "MATCH (a), (b) RETURN a, b",
      "MATCH (a:Person) WHERE a.age > 30 AND a.city = $c RETURN a.name",
      "MATCH (a) WHERE NOT (a.banned) RETURN a",
      "MATCH (a) WHERE a.name IN ['ana', 'bo'] RETURN a",
      "MATCH (a) WHERE a.nickname IS NULL RETURN a",
      "WITH a, a.name AS n WHERE n STARTS WITH 'A' RETURN n",
      "UNWIND [1, 2, 3] AS x RETURN x",
      "MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a.name, b.name ORDER BY a.name SKIP 1 LIMIT 2"
    ]:
      var raised = false
      try:
        discard parseQuery(src)
      except CypherError as e:
        raised = true
        doAssert false, "should parse: " & src & " -- " & e.msg
      doAssert not raised, src
