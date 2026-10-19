## The TCK subset runner (docs/TESTING.md §5, gate C1).
##
##   nimble tck
##
## Reads tests/conformance/tck_subset.txt, runs every `in` row against
## tests/fixtures/social.glyph through the same statement path a host uses,
## checks every `out` row refuses *by name*, and writes
## tests/conformance/tck_report.md.
##
## Three rules the runner implements literally, because a conformance suite
## that bends them measures nothing:
##
##   1. The subset file is the denominator. It is read, never edited here.
##   2. An `out` row is never counted as a pass. It is checked for *naming*
##      its construct and reported separately — a refusal that stops naming
##      is a regression in the error path, which is pin C1's promise.
##   3. Exit non-zero below 95% of `in` rows, so `nimble gate` fails.

import std/os
import std/strutils
import std/tables
import std/times
import ../../src/abi
import ../../src/store/store
import ../../src/database
import ../../src/cypher/errors
import ../../src/cypher/execute
import ../../src/cypher/params
import ../../src/txn/txn

const
  InContract = "in"
  OutOfContract = "out"
  GateRate = 0.95           ## C1, docs/CYPHER.md §7

type
  Entry = object
    id: string
    inContract: bool
    sql: string
    expect: string
    paramJson: string
    target: string            ## "fixture" (read) or "write" (disposable)

proc parseSubset(path: string): seq[Entry] =
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.split('\t')
    if parts.len < 4:
      stderr.writeLine "subset line is not four fields: ", raw
      quit(1)
    var sql = parts[2]
    var paramJson = ""
    ## ` -- {json}` carries parameters; everything before it is the query.
    let sep = sql.find(" -- ")
    if sep >= 0:
      paramJson = sql[sep + 4 .. ^1].strip()
      sql = sql[0 ..< sep].strip()
    ## A fifth column says where the row runs. Write rows cannot use the
    ## committed fixture — they would make the suite's denominator depend on
    ## how many times it has been run — so they get a disposable in-memory
    ## graph seeded by `seedWriteStore`.
    let target = if parts.len >= 5: parts[4].strip() else: "fixture"
    result.add Entry(id: parts[0], inContract: parts[1] == InContract,
                     sql: sql, expect: parts[3].strip(), paramJson: paramJson,
                     target: target)

proc seedWriteStore(): GraphStore =
  ## Two `:Seed` nodes, so a write row can say "each seed" and mean it: one
  ## seed would make a per-row write indistinguishable from a single write.
  ##
  ## Called **per write row**, not once for the suite. The first version
  ## seeded once and let the rows accumulate — which made the subset
  ## order-dependent: a row that deleted `:Made` silently emptied every row
  ## after it, and reordering the file (which nothing forbids) would change
  ## results. A conformance subset whose denominator moves when you sort it
  ## is not a denominator. Each row now creates whatever it needs.
  let s = newStore()
  let tx = txn.begin(s, nil, 1)
  for v in [1'i64, 2'i64]:
    let n = tx.createNode("Seed")
    discard tx.setNodeProp(n, "v", Value(kind: vkInt, i: v))
  discard tx.commit()
  s

proc runEntry(store: GraphStore, writer: GraphStore, e: Entry): (bool, string) =
  ## `store` reads, `writer` is where write rows run. One transaction per
  ## row, committed after the drain — so a write row's effect is visible to
  ## the next row, which is how a language suite is allowed to be stateful
  ## and still deterministic.
  var params = initTable[string, Value]()
  if e.paramJson.len > 0:
    params = parseParamsJson(e.paramJson)
  ## Both the prepare and the drain are inside the catch: a refusal is not
  ## only at parse time. `noSuchFn(1)` parses, plans, and is refused when
  ## the projection evaluates it, so a runner that only guarded `prepare`
  ## would crash on the first function the slice refuses rather than
  ## reporting it.
  var st: Statement
  var actual = ""
  ## A `write:` row's fifth column carries the *verifying* query, not the
  ## write's own projection. The reason is pin C4: a statement's reads never
  ## see its own writes, so `CREATE (n:X {v: 1}) RETURN n.v` answers null in
  ## glyphes where openCypher answers 1 — a documented deviation (see
  ## CYPHER.md §0.1), and one a write row cannot paper over by asserting the
  ## null. Verifying in a *later* statement tests what actually matters:
  ## whether the write landed.
  var tx: WriteTransaction
  ## `write` runs the statement on the write store and compares *its own*
  ## rows (which works since M5.2 gave a statement transactional visibility);
  ## `write:<verify>` runs it, commits, and compares the verify query.
  let onWriter = e.target == "write" or e.target.startsWith("write:")
  let withVerify = e.target.startsWith("write:")
  if onWriter:
    tx = txn.begin(writer, nil, 2)
  try:
    st = prepare(if onWriter: writer else: store, e.sql, params,
                 if onWriter: tx else: nil)
    defer: st.close()
    actual = "["
    var first = true
    while st.step():
      if not first: actual.add ","
      first = false
      actual.add rowJson(st.current, st.columns)
    actual.add "]"
  except CypherError as err:
    if onWriter and tx != nil:
      discard tx.rollback()
    if e.inContract:
      return (false, "unexpected refusal: " & err.msg)
    ## Out of contract: the refusal must *name* the construct (pin C1).
    if e.expect in err.msg:
      return (true, "refused: " & err.msg)
    return (false, "refused but did not name '" & e.expect & "': " & err.msg)
  if onWriter:
    ## Always closed: the next row begins its own transaction, and the
    ## store allows one writer. The verify query — when there is one — runs
    ## after the commit, which is the point of verifying in a later
    ## statement.
    discard tx.commit()
    if withVerify:
      let verify = e.target["write:".len .. ^1]
      var vst = prepare(writer, verify)
      actual = "["
      var vfirst = true
      while vst.step():
        if not vfirst: actual.add ","
        vfirst = false
        actual.add rowJson(vst.current, vst.columns)
      actual.add "]"
      vst.close()

  if e.inContract:
    if actual == e.expect:
      return (true, actual)
    return (false, "expected " & e.expect & " got " & actual)
  ## An `out` row that ran is a failure: the construct is inside the
  ## contract now and the subset file has not caught up, which is a decision
  ## to record rather than a pass to bank.
  (false, "ran instead of refusing: " & actual)

proc main() =
  let root = currentSourcePath.parentDir.parentDir.parentDir
  let subsetPath = root / "tests" / "conformance" / "tck_subset.txt"
  let fixture = root / "tests" / "fixtures" / "social.glyph"
  if not fileExists(subsetPath):
    stderr.writeLine "missing ", subsetPath
    quit(1)
  ## Either file is a valid fixture state: the generator commits once and
  ## `close` does not checkpoint, so a fresh fixture is WAL-only and a
  ## checkpointed one has the snapshot. Checking for the snapshot alone
  ## would fail on exactly the fixture the generator produces.
  if not fileExists(fixture) and not fileExists(fixture & "-wal"):
    stderr.writeLine "missing ", fixture & " — run `nimble fixture` first"
    quit(1)

  let entries = parseSubset(subsetPath)
  let db = openDatabase(fixture, GLY_OPEN_READONLY)
  defer: db.close()


  let t0 = epochTime()
  var passed = 0
  var failed = 0
  var outOk = 0
  var outBad = 0
  var lines: seq[string] = @[]
  for e in entries:
    ## A fresh write store per write row, so rows are independent.
    let (ok, detail) = runEntry(db.store, seedWriteStore(), e)
    if e.inContract:
      if ok:
        inc passed
        lines.add "| " & e.id & " | pass | |"
      else:
        inc failed
        lines.add "| " & e.id & " | **FAIL** | " & detail & " |"
    else:
      if ok:
        inc outOk
        lines.add "| " & e.id & " | out of contract | names `" & e.expect & "` |"
      else:
        inc outBad
        lines.add "| " & e.id & " | **FAIL** | " & detail & " |"

  let inTotal = passed + failed
  let rate = if inTotal == 0: 0.0 else: float(passed) / float(inTotal)

  ## The report is written every run, pass or fail. A committed report that
  ## only moves when someone remembers to move it is a report nobody reads.
  ## It carries no timing: an elapsed row made the committed file differ
  ## after every run — a gate that dirties the tree is a gate people
  ## `git checkout` over — and the time is printed to stdout by the task
  ## itself.
  var report = "# TCK subset report\n\n"
  report.add "Generated by `nimble tck` from "
  report.add "[tck_subset.txt](tck_subset.txt).\n\n"
  report.add "| Metric | Value |\n|---|---|\n"
  report.add "| In contract | " & $inTotal & " |\n"
  report.add "| Passed | " & $passed & " |\n"
  report.add "| Failed | " & $failed & " |\n"
  report.add "| Pass rate | " & $(rate * 100).formatFloat(ffDecimal, 1) & " % |\n"
  report.add "| C1 gate | " & $(GateRate * 100).formatFloat(ffDecimal, 0) & " % |\n"
  report.add "| Out of contract, refused by name | " & $outOk & " |\n"
  report.add "| Out of contract, **not** refused correctly | " & $outBad & " |\n\n"
  report.add "Out-of-contract rows are **not** counted as passes (TESTING.md "
  report.add "rule 2). They are the implementation queue: a row that runs "
  report.add "instead of refusing is a construct that left the contract and "
  report.add "whose subset entry needs an explicit decision (rule 4).\n\n"
  report.add "## Entries\n\n| # | Result | Detail |\n|---|---|---|\n"
  for l in lines:
    report.add l & "\n"
  writeFile(root / "tests" / "conformance" / "tck_report.md", report)

  stdout.writeLine "in contract: ", passed, "/", inTotal, "  (",
                  $(rate * 100).formatFloat(ffDecimal, 1), "%, gate ",
                  $(GateRate * 100).formatFloat(ffDecimal, 0), "%)"
  stdout.writeLine "out of contract: ", outOk, " refused by name, ", outBad,
                  " wrong"
  if failed > 0 or outBad > 0 or rate < GateRate:
    stdout.writeLine "C1: RED"
    quit(1)
  stdout.writeLine "C1: GREEN"

main()