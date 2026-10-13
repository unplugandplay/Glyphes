## glyphes — the text index (M6.2, INDEX.md §3).
##
## Inverted index, BM25 scoring. The shape INDEX.md specifies: a term
## dictionary (codes, so a posting carries 4 bytes rather than a string), a
## posting list per term sorted by node id, field frequency per posting for
## scoring, and positions only where a phrase query needs them.
##
## ## Where the "documents" are
##
## One indexed node is one document, and its indexed property is the field.
## There is no document store: the text is re-read from the property at
## query time for scoring, which costs one property read per *matching*
## node rather than per indexed node. At BM25's selectivity that is the
## cheaper end of the trade, and it means the index cannot disagree with the
## store about what a node says — the class of bug where an index caches a
## copy of a field and keeps serving it after an update.
##
## ## The scores
##
## Raw BM25 with k1=1.2, b=0.75, and `score` is similarity-shaped: higher
## is better, so `ORDER BY score DESC` is correct (INDEX.md pin I6). A
## caller comparing two engines should compare numbers, not ranks, and gate
## I6 does exactly that against a reference.

import std/[algorithm, math, sets, strutils, tables]
import ../store/prop
import ./analyzer

const
  Bm25K1* = 1.2
  Bm25B* = 0.75
  ## Postings are kept sorted by node id so that an AND is a merge-walk and
  ## a phrase is a positional merge. Sorted per term rather than globally:
  ## the same trade the range index's per-block sortedness makes.
  MaxPositions* = 64          ## phrase queries on very long fields degrade to count
  SnippetTerms* = 6

type
  Posting* = object
    nodeId*: int64
    freq*: int32              ## term occurrences in the field
    positions*: seq[int32]    ## term positions, for phrases; bounded
    fieldLen*: int32          ## |D| in terms, cached so scoring needs no re-read

  TextIndex* = ref object
    name*: string
    label*: string
    property*: string
    analyzer*: AnalyzerKind
    ## term code → postings. The dictionary is shared across indexes in a
    ## registry (one code per term corpus-wide), which is why the postings
    ## here are per-index.
    postings*: Table[int32, seq[Posting]]
    docTerms*: Table[int64, seq[int32]]    ## node → its term codes
    docLen*: Table[int64, int32]            ## node → |D| in terms, so a
                                           ## remove can retract Σ|D| without
                                           ## re-reading a posting list
    totalTerms*: int64                     ## Σ|D|, for avgdl
    docCount*: int64                       ## N
    ## Pending work, folded in at merge: the same delta discipline as the
    ## range index, because a write to a text field is a write like any
    ## other and the search must see it before the commit returns.
    pending*: Table[int64, string]         ## node → new field text ("" = gone)
    pendingIds*: seq[int64]
    usable*: bool
    probes*: int64
    ## Postings visited by the last query. Every scoring path used to
    ## re-find a document's posting by scanning the whole posting list for
    ## its term — quadratic in the corpus, and invisible until the index was
    ## big enough to hurt. The counter is the regression test's oracle: a
    ## query must visit postings proportional to the lists it walks, not to
    ## (hits × list length).
    walked*: int64

proc newText*(name, label, property: string, analyzer = akStandard): TextIndex =
  TextIndex(name: name, label: label, property: property, analyzer: analyzer,
            postings: initTable[int32, seq[Posting]](),
            docTerms: initTable[int64, seq[int32]](),
            docLen: initTable[int64, int32](),
            pending: initTable[int64, string](), usable: true)

proc termCode(reg: var Table[int32, string], terms: var Table[string, int32],
              term: string): int32 =
  ## The shared dictionary. A miss assigns the next code; codes are dense
  ## and never reused, which is what lets a posting be 4 bytes.
  if terms.hasKey(term):
    return terms[term]
  let code = int32(terms.len + 1)
  terms[term] = code
  reg[code] = term
  return code

proc removeDoc(ix: TextIndex, nodeId: int64,
               docTerms: var Table[int64, seq[int32]],
               postings: var Table[int32, seq[Posting]]): bool =
  ## Drop a node's postings. A linear walk of each affected list rather than
  ## a binary search-and-splice: lists are per-term and a node touches few
  ## of them, and splicing a 10^5-entry list to remove one is the more
  ## expensive half.
  if not docTerms.hasKey(nodeId):
    return false
  ## Retract the counters here rather than in each caller: `indexDoc`
  ## replaces a document (it removes first), and a remove that forgot the
  ## retraction while the insert remembered it made N grow by one on every
  ## update — every score then drifted upward as documents were edited, and
  ## a tombstoned document kept counting toward avgdl forever.
  ix.docCount -= 1
  if ix.docLen.hasKey(nodeId):
    ix.totalTerms -= int64(ix.docLen[nodeId])
    ix.docLen.del nodeId
  for code0 in docTerms[nodeId]:
    let code = code0
    if postings.hasKey(code):
      var kept: seq[Posting] = @[]
      for p in postings[code]:
        if p.nodeId != nodeId:
          kept.add p
      if kept.len == 0:
        postings.del code
      else:
        postings[code] = kept
  return true

proc indexDoc(ix: TextIndex, nodeId: int64, text: string,
              terms: var Table[string, int32], dict: var Table[int32, string]) =
  ## Replace a node's entry with `text`. This is the whole write path for a
  ## text field, and it is a delete-then-insert: an update is not an update
  ## in an inverted index, it is a different document.
  discard removeDoc(ix, nodeId, ix.docTerms, ix.postings)
  ix.docTerms.del nodeId
  let analyzed = Analyzer(kind: ix.analyzer).analyze(text)
  if analyzed.len == 0:
    ## A field that analyzes to nothing is not a document with no terms —
    ## it is not a document. It contributes to neither N nor avgdl, so a
    ## single punctuation-only field does not drag every score toward zero.
    return
  var codes: seq[int32] = @[]
  var freqs = initTable[int32, int32]()
  var positions = initTable[int32, seq[int32]]()
  for i, term in analyzed:
    let code = termCode(dict, terms, term)
    if not freqs.hasKey(code):
      freqs[code] = 0
      positions[code] = @[]
    freqs[code] = freqs[code] + 1
    if positions[code].len < MaxPositions:
      positions[code].add int32(i)
    codes.add code
  ix.docTerms[nodeId] = codes
  ix.docLen[nodeId] = int32(analyzed.len)
  for code in freqs.keys:
    let p = Posting(nodeId: nodeId, freq: freqs[code],
                    positions: positions[code], fieldLen: int32(analyzed.len))
    if ix.postings.hasKey(code):
      var list = ix.postings[code]
      ## Sorted by node id: the AND merge and the phrase walk both assume
      ## it, and an unsorted posting list makes them answer "no match" for a
      ## document that has every term.
      var at = list.len
      for i in 0 ..< list.len:
        if list[i].nodeId > nodeId:
          at = i
          break
      list.insert(p, at)
      ix.postings[code] = list
    else:
      ix.postings[code] = @[p]
  ix.docCount += 1
  ix.totalTerms += int64(analyzed.len)

proc update*(ix: TextIndex, nodeId: int64, text: string) =
  ## The write path: queued, not applied. The registry folds the queue in
  ## `merge`, which runs inside the commit's write exclusion — the same
  ## discipline as the range index, for the same reason: a search must see
  ## committed data and must not read a half-applied delta.
  if ix.pending.hasKey(nodeId):
    ix.pending[nodeId] = text
  else:
    ix.pendingIds.add nodeId
    ix.pending[nodeId] = text

proc remove*(ix: TextIndex, nodeId: int64) =
  ## Tombstone path. A queued `update` for this node in the same transaction
  ## must not resurrect it, so the queue entry is overwritten with empty text
  ## rather than removed — deleting the key would let an already-queued set
  ## merge after the delete and leave the document in the index.
  if ix.pending.hasKey(nodeId):
    ix.pending[nodeId] = ""
  else:
    ix.pendingIds.add nodeId
    ix.pending[nodeId] = ""

proc sameTerms(ix: TextIndex, nodeId: int64, text: string,
               terms: Table[string, int32],
               dict: Table[int32, string]): bool =
  ## Whether `text` analyzes to exactly the codes already indexed for this
  ## node. The analyzer's terms, not the raw text: two spellings that fold
  ## to the same terms index the same postings, so the second one is
  ## genuinely a no-op.
  if not ix.docTerms.hasKey(nodeId):
    return false
  let analyzed = Analyzer(kind: ix.analyzer).analyze(text)
  if analyzed.len != ix.docTerms[nodeId].len:
    return false
  for i, term in analyzed:
    if not terms.hasKey(term) or terms[term] != ix.docTerms[nodeId][i]:
      return false
  discard dict
  true

proc merge*(ix: TextIndex, terms: var Table[string, int32],
            dict: var Table[int32, string]) =
  ## Fold the pending queue into the committed postings. Every queued node is
  ## re-indexed (a remove-then-insert); the cost is proportional to the
  ## document's own terms, because `indexDoc` inserts each posting at its
  ## sorted position rather than at the end of the list, so a re-index does
  ## not move surviving postings. A skip-if-unchanged optimization would need
  ## re-analyzing every queued field to notice the text is identical, which
  ## costs about as much as the re-index it avoids on the documents that
  ## did change — and the queue only ever holds nodes the transaction
  ## touched.
  for nodeId in ix.pendingIds:
    let text = ix.pending[nodeId]
    ## An unchanged field is not a new document either. The comparison is
    ## the analyzed term codes against what is already indexed — cheap,
    ## because the analysis happens anyway — and it saves a remove plus a
    ## re-insert, and the posting-list copies a remove makes. Re-setting a
    ## body to the same text is what a re-run importer does to every row.
    if text.len > 0 and ix.sameTerms(nodeId, text, terms, dict):
      continue
    if text.len == 0:
      discard removeDoc(ix, nodeId, ix.docTerms, ix.postings)
      ix.docTerms.del nodeId
    else:
      indexDoc(ix, nodeId, text, terms, dict)
  ix.pending = initTable[int64, string]()
  ix.pendingIds = @[]

proc reset*(ix: TextIndex) =
  ix.postings = initTable[int32, seq[Posting]]()
  ix.docTerms = initTable[int64, seq[int32]]()
  ix.docLen = initTable[int64, int32]()
  ix.totalTerms = 0
  ix.docCount = 0
  ix.pending = initTable[int64, string]()
  ix.pendingIds = @[]
  ix.usable = true

proc avgDocLen*(ix: TextIndex): float =
  if ix.docCount == 0: 0.0
  else: float(ix.totalTerms) / float(ix.docCount)

proc idf*(ix: TextIndex, code: int32): float =
  ## BM25's IDF with the +1 that makes it non-negative for a term in every
  ## document: `ln(1 + (N - n + 0.5)/(n + 0.5))`. With N = n the classic
  ## `ln((N-n+0.5)/(n+0.5)+1)` is ln(1) = 0, and a term every document
  ## carries would contribute nothing to every score.
  if not ix.postings.hasKey(code):
    return 0.0
  let n = float(ix.postings[code].len)
  let N = float(max(ix.docCount, 1'i64))
  ln(1.0 + (N - n + 0.5) / (n + 0.5))

proc scorePosting*(ix: TextIndex, p: Posting): float =
  ## The BM25 numerator for one (term, document) pair. The IDF is added by
  ## the caller, which is the only place that knows the term.
  let f = float(p.freq)
  let dl = float(p.fieldLen)
  let avg = max(avgDocLen(ix), 1.0)
  f * (Bm25K1 + 1.0) / (f + Bm25K1 * (1.0 - Bm25B + Bm25B * dl / avg))

type
  Hit* = object
    nodeId*: int64
    score*: float
    matched*: seq[int32]     ## which query terms this document matched

proc search*(ix: TextIndex, terms: Table[string, int32], queryTerms: seq[string],
              andAll = false, negTerms: seq[string] = @[]): seq[Hit] =
  ## Keyword search: OR by default, AND when asked, `-term` excludes.
  ##
  ## AND is evaluated as the intersection of posting lists, smallest list
  ## first (INDEX.md §3.3). That ordering is not a cost model — it is the
  ## one piece of information available without statistics, and it is always
  ## right: the smallest list is the cheapest to filter against every other.
  inc ix.probes
  result = @[]
  if queryTerms.len == 0:
    return
  var lists: seq[seq[Posting]] = @[]
  var codes: seq[int32] = @[]
  for t in queryTerms:
    if not terms.hasKey(t):
      ## A term the index has never seen. Under OR it simply matches nothing
      ## and is skipped; under AND it means *no* document can match, so the
      ## whole query is empty. Skipping it for AND would answer "every
      ## document with the other terms", which is the opposite of what AND
      ## says — the first version did exactly that and `quick AND zzzz`
      ## returned both quick documents.
      if andAll:
        return
      continue
    let code = terms[t]
    if ix.postings.hasKey(code):
      lists.add ix.postings[code]
      codes.add code
    elif andAll:
      return                        ## the term is known but no document has it
  if lists.len == 0:
    return
  if andAll:
    lists.sort(proc (a, b: seq[Posting]): int = a.len - b.len)
    var current = lists[0]
    ## A seq, not `[codes[0]]` — a single-element bracket literal in Nim is a
    ## fixed C-style array, and `add` on one is a compile error that reads as
    ## a call-site type mismatch three frames up.
    var matchedCodes: seq[int32] = @[codes[0]]
    for li in 1 ..< lists.len:
      var next: seq[Posting] = @[]
      var a = 0
      var b = 0
      while a < current.len and b < lists[li].len:
        let pa = current[a]
        let pb = lists[li][b]
        if pa.nodeId == pb.nodeId:
          next.add pa
          inc a
          inc b
        elif pa.nodeId < pb.nodeId:
          inc a
        else:
          inc b
      current = next
      matchedCodes.add codes[li]
      if current.len == 0:
        break
    ## Scoring walks each matched list once and adds into the documents the
    ## intersection kept. The first version re-found every document's
    ## posting by scanning the whole list for it — O(hits × list) — which
    ## made AND over two common terms unusable past ~10^5 documents while
    ## the intersection itself (the expensive part) was already linear.
    var survivors = initHashSet[int64]()
    for p in current:
      survivors.incl p.nodeId
    var scoreOf = initTable[int64, float]()
    for code in matchedCodes:
      for q in ix.postings[code]:
        inc ix.walked
        if q.nodeId in survivors:
          scoreOf[q.nodeId] = scoreOf.getOrDefault(q.nodeId) +
            ix.idf(code) * ix.scorePosting(q)
    for p in current:
      result.add Hit(nodeId: p.nodeId, score: scoreOf.getOrDefault(p.nodeId),
                     matched: matchedCodes)
  else:
    ## OR: every posting in every list, accumulated per document. Sorted so
    ## the union is a merge rather than a hash.
    var byNode = initTable[int64, Hit]()
    var order: seq[int64] = @[]
    for li, list in lists:
      for p in list:
        if byNode.hasKey(p.nodeId):
          var h = byNode[p.nodeId]
          h.score += ix.idf(codes[li]) * ix.scorePosting(p)
          h.matched.add codes[li]
          byNode[p.nodeId] = h
        else:
          byNode[p.nodeId] = Hit(nodeId: p.nodeId,
                                 score: ix.idf(codes[li]) * ix.scorePosting(p),
                                 matched: @[codes[li]])
          order.add p.nodeId
    for nodeId in order:
      result.add byNode[nodeId]

  ## Negation. Applied after the union, never as a filter on the postings:
  ## a negated term's list can be longer than everything else put together.
  if negTerms.len > 0:
    var excluded = initHashSet[int64]()
    for t in negTerms:
      if terms.hasKey(t) and ix.postings.hasKey(terms[t]):
        for p in ix.postings[terms[t]]:
          excluded.incl p.nodeId
    var kept: seq[Hit] = @[]
    for h in result:
      if h.nodeId notin excluded:
        kept.add h
    result = kept
  ## Descending score, then id: a stable order so two runs of the same query
  ## return the same rows, and `LIMIT 10` returns the same ten.
  result.sort(proc (a, b: Hit): int =
    if a.score != b.score:
      return (if a.score > b.score: -1 else: 1)
    (if a.nodeId < b.nodeId: -1 elif a.nodeId > b.nodeId: 1 else: 0))

proc phrase*(ix: TextIndex, terms: Table[string, int32],
             phrase: seq[string]): seq[Hit] =
  ## Documents containing the exact phrase, in order.
  ##
  ## Positions exist for this and nothing else (INDEX.md §3). The rule is a
  ## membership test, not a pairwise alignment: for each position `base` where
  ## the *first* phrase term occurs, every subsequent term must also occur at
  ## `base + i`. The first version compared the i-th stored position of one
  ## term against `base + i` of another — indexing by i instead of asking "is
  ## base+i in this set" — which matches nothing and reads as "the feature
  ## does not work" rather than as a wrong comparison.
  inc ix.probes
  result = @[]
  if phrase.len == 0:
    return
  var lists: seq[seq[Posting]] = @[]
  var codes: seq[int32] = @[]
  for t in phrase:
    if not terms.hasKey(t) or not ix.postings.hasKey(terms[t]):
      return                       ## a phrase with an absent term matches nothing
    lists.add ix.postings[terms[t]]
    codes.add terms[t]
  ## The rarest term's documents are the candidates; the phrase order itself
  ## is walked below against each candidate's full position sets, so sorting
  ## here is only about which documents to *consider*.
  var byLen = newSeq[int](lists.len)
  for i in 0 ..< lists.len:
    byLen[i] = i
  byLen.sort(proc (a, b: int): int = lists[a].len - lists[b].len)
  ## One pass per phrase term, restricted to the candidates, carrying each
  ## candidate's posting. The first version looked a candidate's positions
  ## up with a scan of that term's whole posting list — per candidate, per
  ## phrase term, plus once more to score: 2 ms at 2k documents, 80 ms at
  ## 16k, i.e. quadratic in a feature whose whole point is being usable on
  ## a corpus. The comment above this code claimed the positions were
  ## "gathered once"; they were not, and the sentence described the fix.
  var candidates = initHashSet[int64]()
  for p in lists[byLen[0]]:
    candidates.incl p.nodeId
  var postingOf: seq[Table[int64, Posting]] = newSeq[Table[int64, Posting]](phrase.len)
  for i in 0 ..< phrase.len:
    var m = initTable[int64, Posting]()
    for p in ix.postings[codes[i]]:
      inc ix.walked
      if p.nodeId in candidates:
        m[p.nodeId] = p
    postingOf[i] = m

  for cand in lists[byLen[0]]:
    ## The base positions come from the phrase's *first* term, always. The
    ## rarest list only chose which documents to consider; using its code as
    ## the anchor made a longer phrase align the wrong term's positions and
    ## matched nothing — a two-term phrase passed, which is exactly how this
    ## survives review.
    if not postingOf[0].hasKey(cand.nodeId):
      continue
    let bases = postingOf[0][cand.nodeId].positions
    if bases.len == 0:
      ## No stored positions for this term — the field was longer than
      ## `MaxPositions` and this term fell off the end. A phrase query on it
      ## cannot be answered exactly, so it is skipped rather than guessed.
      continue
    var ok = false
    for base in bases:
      var aligned = true
      for i in 1 ..< phrase.len:
        if not postingOf[i].hasKey(cand.nodeId):
          aligned = false
          break
        var found = false
        for pos in postingOf[i][cand.nodeId].positions:
          if pos == base + int32(i):
            found = true
            break
        if not found:
          aligned = false
          break
      if aligned:
        ok = true
        break
    if ok:
      var score = 0.0
      for i in 0 ..< phrase.len:
        score += ix.idf(codes[i]) * ix.scorePosting(postingOf[i][cand.nodeId])
      result.add Hit(nodeId: cand.nodeId, score: score)
  result.sort(proc (a, b: Hit): int =
    if a.score != b.score:
      return (if a.score > b.score: -1 else: 1)
    (if a.nodeId < b.nodeId: -1 elif a.nodeId > b.nodeId: 1 else: 0))

proc entryCount*(ix: TextIndex): int64 =
  var n = 0'i64
  for code in ix.postings.keys:
    n += int64(ix.postings[code].len)
  n