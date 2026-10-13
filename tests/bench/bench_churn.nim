## Scratch: churn-only scaling, to find whether the *store* is quadratic
## on a delete-heavy workload (the test harness's own list management was
## one source; this isolates the store). Delete once M1 is done.

import std/random
import std/times
import std/os
import std/strutils
import ../../src/store/store

proc ms(sec: float): int64 = int64(sec * 1000)

let ops = parseInt(paramStr(1))
let s = newStore()
var rng = initRand(20261007)
var live: seq[int64] = @[]
var edges: seq[int64] = @[]

let t0 = epochTime()
for i in 0 ..< ops:
  let r = rng.rand(100)
  if r < 45 or live.len < 4:
    live.add s.createNode(if r mod 2 == 0: "N" else: "M")
  elif r < 85:
    let a = live[rng.rand(live.high)]
    let b = live[rng.rand(live.high)]
    let e = s.createEdge(a, b, "E")
    if e != 0: edges.add e
  elif r < 95:
    if edges.len > 0:
      let e = edges[rng.rand(edges.high)]
      if s.edgeExists e: discard s.deleteEdge e
  else:
    if live.len > 8:
      let n = live[rng.rand(live.high)]
      if s.nodeExists n: discard s.deleteNode(n, true)
  if i mod 50_000 == 0 and i > 0:
    stderr.writeLine "  " & $i & " ops  " & $(ms(epochTime() - t0)) & " ms"
let dt = ms(epochTime() - t0)

let tRecount = epochTime()
var walked = 0
var mismatches = 0
for n in live:
  if not s.nodeExists n: continue
  let rec = s.node(n)
  var w = 0
  var cur = rec.outHead
  while cur != 0:
    w += 1
    cur = s.edge(cur).nextOut
  if w != rec.outCount.int: inc mismatches
  w = 0
  cur = rec.inHead
  while cur != 0:
    w += 1
    cur = s.edge(cur).nextIn
  if w != rec.inCount.int: inc mismatches
  walked += w
let recountMs = ms(epochTime() - tRecount)

let tCheck = epochTime()
let findings = s.check()
let checkMs = ms(epochTime() - tCheck)
var bad = 0
for inv in findings:
  if not inv.ok: inc bad
stderr.writeLine "  recount ", recountMs, " ms (", walked, " hops, ", mismatches, " mismatches)"
stderr.writeLine "  check    ", checkMs, " ms (", findings.len, " invariants, ", bad, " failing)"
if bad > 0:
  for inv in findings:
    if not inv.ok: stderr.writeLine "    ", inv.code, " ", inv.detail
stdout.writeLine ops, " ops in ", dt, " ms  (", ops * 1000 div max(dt.int64, 1),
              " ops/s)  live=", live.len, " edges=", edges.len
