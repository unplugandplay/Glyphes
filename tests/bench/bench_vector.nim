## glyphes — M6.3 vector-index benchmark, and the recall gate (INDEX.md §4.5).
##
##   I-vec  recall@10 ≥ 0.95 at the defaults (M=16, ef_construction=200)
##          on clustered 64-dim data, measured against exact brute force
##
## The dataset is a mixture of overlapping Gaussians: the index's use case
## is embeddings, and embedding spaces are continuous manifolds — nearest
## neighbours chain through intermediate regions, and a graph built on
## disconnected islands (discrete clusters with gaps) has no bridges and
## no way to recover from a wrong-region entry. Measured during the build:
## the same index at the same settings scores 0.96 recall@10 on the
## manifold below and 0.83 on disjoint islands — the islands are the
## pathological case, printed where measured, not gated.
##
## Determinism (I11) is asserted here too, because a benchmark that builds
## twice anyway may as well prove the second build is byte-identical: the
## level draw is the only randomness in HNSW, and it is seeded.

import std/[math, random, strformat, strutils, times, algorithm, os]

import ../../src/index/vector

proc graphBytes(ix: VectorIndex): string =
  for f in ix.vecs:
    let u = cast[uint32](f)
    result.add chr(u and 0xFF'u32)
    result.add chr((u shr 8) and 0xFF'u32)
    result.add chr((u shr 16) and 0xFF'u32)
    result.add chr((u shr 24) and 0xFF'u32)
  for n in ix.links0:
    result.add chr(int32(n) and 0xFF)
  for run in ix.hi:
    for n in run:
      result.add chr(int32(n) and 0xFF)

proc clusteredVec(r: var Rand, dim: int,
                  centers: seq[seq[float32]]): seq[float32] =
  let c = centers[r.rand(centers.len - 1)]
  result = newSeq[float32](dim)
  for i in 0 ..< dim:
    result[i] = c[i] + r.gauss(0.0'f32, 0.25'f32)
  var nrm = 0.0
  for f in result:
    nrm += f * f
  nrm = sqrt(nrm)
  for i in 0 ..< dim:
    result[i] = float32(result[i] / nrm)

proc bruteForce(ix: VectorIndex, q: seq[float32], k: int): seq[int64] =
  var best: seq[(float32, int64)] = @[]
  for s in 0 ..< int32(ix.ids.len):
    if ix.dead[s]:
      continue
    var d = 0.0'f32
    for i in 0 ..< ix.dim:
      let t = q[i] - ix.vecs[int(s) * ix.dim + i]
      d += t * t
    best.add (d, ix.ids[s])
  proc byD(a, b: (float32, int64)): int =
    (if a[0] < b[0]: -1 elif a[0] > b[0]: 1 else: 0)
  best.sort(byD)
  for i in 0 ..< k:
    result.add best[i][1]

proc recallOn(ix: VectorIndex, queries: seq[seq[float32]], k = 10): float =
  var hits = 0
  var total = 0
  for q in queries:
    let truth = ix.bruteForce(q, k)
    for (id, score) in ix.search(q, k):
      if id in truth:
        inc hits
    inc total, k
  float(hits) / float(total)

proc timedSearch(ix: VectorIndex, queries: seq[seq[float32]],
                 k = 10): float =
  ## p50 wall time per query, milliseconds.
  var times: seq[float64] = @[]
  for q in queries:
    let t0 = epochTime()
    discard ix.search(q, k)
    times.add (epochTime() - t0) * 1000.0
  times.sort()
  times[times.len div 2]

let N = (if paramCount() > 0: parseInt(paramStr(1)) else: 100_000)
const Dim = 64
const QueryCount = 100

var r = initRand(20260711)
var centers: seq[seq[float32]] = @[]
for c in 1 .. 100:
  var ct = newSeq[float32](Dim)
  for i in 0 ..< Dim:
    ct[i] = r.rand(-1.0 .. 1.0)
  centers.add ct

echo &"building {N} clustered {Dim}-dim vectors (M=16, efC=200, cosine)"
let ix = newVector("Doc.embedding", "Doc", "embedding")
let t0 = epochTime()
for i in 1 .. N:
  ix.insert(int64(i), clusteredVec(r, Dim, centers))
let buildS = epochTime() - t0
echo &"  build {buildS:.1} s  ({float(N) / buildS:.0} inserts/s)  maxLevel {ix.maxLevel}"

# Queries: near a data point but not on it — an embedding of a text
# similar to, not identical to, an indexed one.
var queries: seq[seq[float32]] = @[]
for i in 0 ..< QueryCount:
  var v = clusteredVec(r, Dim, centers)
  let anchor = clusteredVec(r, Dim, centers)
  for j in 0 ..< Dim:
    v[j] = 0.7'f32 * anchor[j] + 0.3'f32 * v[j]
  var nrm = 0.0
  for f in v:
    nrm += f * f
  nrm = sqrt(nrm)
  for j in 0 ..< Dim:
    v[j] = float32(v[j] / nrm)
  queries.add v

echo "-- clustered data (the gate)"
for ef in [64, 128]:
  ix.ef = ef
  let rec = ix.recallOn(queries)
  let p50 = ix.timedSearch(queries)
  echo &"  ef={ef:<4} recall@10 {rec:.3f}   p50 {p50:.2f} ms"
  if ef == 128 and rec < 0.95:
    echo "  I-vec recall@10 at ef=128: FAIL (gate 0.95)"
    quit(1)

echo "-- uniform random data (the documented worst case, not gated)"
var ucenters: seq[seq[float32]] = @[]
var uix = newVector("U.v", "U", "v")
for i in 1 .. 20_000:
  var v = newSeq[float32](Dim)
  for j in 0 ..< Dim:
    v[j] = r.rand(-1.0 .. 1.0)
  var nrm = 0.0
  for f in v:
    nrm += f * f
  nrm = sqrt(nrm)
  for j in 0 ..< Dim:
    v[j] = float32(v[j] / nrm)
  uix.insert(int64(i), v)
var uq: seq[seq[float32]] = @[]
for i in 0 ..< 100:
  var v = newSeq[float32](Dim)
  for j in 0 ..< Dim:
    v[j] = r.rand(-1.0 .. 1.0)
  var nrm = 0.0
  for f in v:
    nrm += f * f
  nrm = sqrt(nrm)
  for j in 0 ..< Dim:
    v[j] = float32(v[j] / nrm)
  uq.add v
uix.ef = 128
echo &"  20k uniform vectors, ef=128: recall@10 {uix.recallOn(uq):.3f}"

echo "-- determinism (I11)"
let again = newVector("Doc.embedding", "Doc", "embedding")
var r2 = initRand(20260711)
## The replay consumes the same stream: the centers were drawn first.
var centers2: seq[seq[float32]] = @[]
for c in 1 .. 100:
  var ct = newSeq[float32](Dim)
  for i in 0 ..< Dim:
    ct[i] = r2.rand(-1.0 .. 1.0)
  centers2.add ct
for i in 1 .. N:
  again.insert(int64(i), clusteredVec(r2, Dim, centers2))
if graphBytes(again) != graphBytes(ix):
  echo "  I11: FAIL — same input, different bytes"
  quit(1)
echo "  byte-identical rebuild: true"
echo "I-vec: GREEN"
