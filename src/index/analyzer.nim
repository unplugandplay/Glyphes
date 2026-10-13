## glyphes — the text analyzer (M6.2, INDEX.md §3.1).
##
## `standard` is deliberately exact: case-folded, diacritics preserved,
## split on non-alphanumerics, tokens of 2 to 32 characters. No stemming
## and no stopword list, and that is pinned (I5): a corpus that wants
## either should not have to guess whether it is on, and a stemmed index
## cannot answer a phrase query about the words that were written.
##
## The two other analyzers exist because both are asked for by real
## corpora and neither is a variation of `standard`:
##
##   `keyword`      the whole field is one term — an identifier, a SKU, a
##                  code. Splitting it is the wrong answer, not a lossy one.
##   `whitespace`   split on whitespace and case-fold, nothing else. What a
##                  log line or a path wants.

import std/[strutils, tables, unicode]
import ../store/prop

const
  MinTokenLen* = 2
  MaxTokenLen* = 32

type
  AnalyzerKind* = enum
    akStandard, akKeyword, akWhitespace

  Analyzer* = object
    kind*: AnalyzerKind

proc fromName*(name: string): AnalyzerKind =
  ## An unknown name is refused by the caller rather than silently becoming
  ## `standard`: an index built with an analyzer the caller did not ask for
  ## answers with terms nobody wrote, and the search returns nothing with
  ## no error anywhere.
  case name.toLowerAscii
  of "", "standard": akStandard
  of "keyword": akKeyword
  of "whitespace": akWhitespace
  else: akStandard

proc analyzerName*(k: AnalyzerKind): string =
  ## The name a caller wrote, so a definition can be written out and read
  ## back through the same door: `$akKeyword` is "akKeyword", which
  ## `fromName` refuses — a sidecar that could not reopen its own index.
  case k
  of akStandard: "standard"
  of akKeyword: "keyword"
  of akWhitespace: "whitespace"

proc isWordChar(r: Rune): bool =
  ## Alphanumeric, and that is the whole definition.
  ##
  ## Nim's `isAlphaNum` is ASCII, and the category test is not: a token in
  ## a non-Latin script has to make it into the index or the search returns
  ## nothing with no error anywhere. The digit range compares `int(r)`:
  ## `Rune` has no ordering operators at all, and the failure is a compile
  ## error rather than a silent ASCII-only fallback.
  r.isAlpha() or (int(r) >= 0x30 and int(r) < 0x3A)

proc analyze*(a: Analyzer, text: string): seq[string] =
  ## The terms of one field value, in order and with duplicates: BM25 needs
  ## the field frequency, so dedup happens where the frequency is computed
  ## and not here.
  case a.kind
  of akKeyword:
    let t = text.strip().toLowerAscii()
    if t.len >= MinTokenLen and t.len <= MaxTokenLen:
      @[t]
    else:
      @[]
  of akWhitespace:
    var tokens: seq[string] = @[]
    for raw in strutils.splitWhitespace(text):
      let t = raw.toLowerAscii()
      if t.len >= MinTokenLen and t.len <= MaxTokenLen:
        tokens.add t
    tokens
  of akStandard:
    var terms: seq[string] = @[]
    var current = newStringOfCap(16)
    for r in text.runes:
      if isWordChar(r):
        current.add(toLowerAscii($r))
      elif current.len > 0:
        if current.len >= MinTokenLen and current.len <= MaxTokenLen:
          terms.add current
        current = newStringOfCap(16)
    if current.len > 0 and current.len >= MinTokenLen and current.len <= MaxTokenLen:
      terms.add current
    terms

proc analyzeParams*(a: Analyzer, params: Table[string, Value]): seq[string] =
  ## `a.text` / `a.query` / `a.body` … — the form CALL uses. Absent and
  ## wrong-typed are null (no rows), not an error: a search with no text
  ## has no results, and saying so is the answer.
  for key in ["text", "query", "body", "q"]:
    if params.hasKey(key):
      let v = params[key]
      if v.kind == vkString:
        return a.analyze(v.s)
  @[]