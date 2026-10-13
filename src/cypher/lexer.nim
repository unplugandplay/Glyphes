## glyphes — the Cypher tokenizer (CYPHER.md)
##
## A hand-written scanner, not a generated one. The grammar is small enough
## that a generated lexer would be a second language to maintain, and the
## only thing it would buy — DFA tables — is worth nothing at 40 tokens.
##
## Two decisions worth stating because they are the ones a Cypher
## implementation usually gets wrong:
##
## 1. **Keywords are not a token kind.** `MATCH`, `Match` and `match` are the
##    same word, and they are also legal *identifiers* — a property called
##    `match` is not a syntax error in openCypher, it is a name the parser
##    only treats as a keyword in the one position a clause can start. So
##    the lexer emits `tkIdent` and the parser asks `isKeyword(tok, ...)`
##    where position makes it unambiguous. A keyword table here would have
##    to be undone again at every identifier.
##
## 2. **Longest match wins, and `-` is not special.** `->`, `<-`, `<=`,
##    `>=`, `<>`, `=~` and `..` are all lexed as single symbols, which means
##    the pattern `(a)-[:KNOWS]->(b)` and the range `*1..3` never need the
##    parser to look at adjacency. The cost is that `a<-3` is a syntax error
##    rather than a comparison; openCypher has the same ambiguity and
##    resolves it the same way.
##
## Numbers: integers, decimals and exponents. No hex, no octal, no digit
## separators — `CYPHER.md` does not list them, and an unlisted numeric form
## is a parse error rather than a silent guess.
##
## Every error carries a line and column. A Cypher parser that says
## "unexpected token" without a position costs more per bug than the
## position costs per line of code.

import std/[strutils, unicode]

import ./errors
import ../abi

type
  TokenKind* = enum
    tkEof, tkIdent, tkInt, tkFloat, tkString, tkParam, tkSym

  Token* = object
    kind*: TokenKind
    text*: string          ## the raw source text, for symbols and idents
    num*: float64          ## valid for tkFloat
    intNum*: int64         ## valid for tkInt, when it fits
    uval*: uint64          ## valid for tkInt, always. The magnitude is kept
                           ## unsigned because `-9223372036854775808` has no
                           ## int64 spelling: without this the smallest
                           ## int64 could not be written as a literal at all.
    str*: string           ## decoded, for tkString
    line*, col*: int       ## 1-based, for errors

  Lexer* = object
    src*: string
    pos*: int
    line*, col*: int

const
  ## Longest first. `.` is last so `..` wins over it.
  ## `+=` is here for one clause: `SET n += {…}`. It is an assignment
  ## operator nowhere else — in an expression `+=` does not exist — so
  ## lexing it as one symbol costs nothing and saves the parser a
  ## two-token lookahead on the only clause that uses it.
  Symbols* = ["->", "<-", "<=", ">=", "<>", "=~", "..", "+=",
              "(", ")", "{", "}", "[", "]", ",", ".", ":", "|",
              ";", "=", "<", ">", "+", "-", "*", "/", "%", "^", "$"]

proc initLexer*(src: string): Lexer =
  result.src = src
  result.pos = 0
  result.line = 1
  result.col = 1

proc atEnd(l: Lexer): bool {.inline.} = l.pos >= l.src.len
proc peek(l: Lexer, ahead = 0): char {.inline.} =
  let i = l.pos + ahead
  if i < l.src.len: l.src[i] else: '\0'

proc advance(l: var Lexer): char =
  ## One character, maintaining line/col. `\n` is the only line break the
  ## scanner counts; a CR is skipped as whitespace rather than counted, so a
  ## CRLF file reports the column it would have on any platform.
  let c = l.src[l.pos]
  inc l.pos
  if c == '\n':
    inc l.line
    l.col = 1
  else:
    inc l.col
  c

proc fail(l: Lexer, msg: string) {.noreturn.} =
  cypherFail(glyErrSql, l.src & ":" & $l.line & ":" & $l.col & ": " & msg)

proc skipTrivia(l: var Lexer) =
  ## Whitespace and comments. openCypher has both `//` and `/* */`, and a
  ## query with neither is rare enough that not supporting them would be a
  ## papercut rather than a simplification.
  while not l.atEnd:
    let c = l.peek()
    if c in {' ', '\t', '\r', '\n'}:
      discard l.advance()
    elif c == '/' and l.peek(1) == '/':
      while not l.atEnd and l.peek() != '\n':
        discard l.advance()
    elif c == '/' and l.peek(1) == '*':
      discard l.advance(); discard l.advance()
      var depth = 1
      while depth > 0:
        if l.atEnd:
          l.fail("unterminated block comment")
        if l.peek() == '*' and l.peek(1) == '/':
          discard l.advance(); discard l.advance()
          dec depth
        elif l.peek() == '/' and l.peek(1) == '*':
          discard l.advance(); discard l.advance()
          inc depth
        else:
          discard l.advance()
    else:
      break

proc isIdentStart(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

proc isIdentChar(c: char): bool {.inline.} =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc isDigit(c: char): bool {.inline.} = c >= '0' and c <= '9'

proc lexEscape(l: var Lexer, acc: var string) =
  ## The escapes openCypher defines. `\uXXXX` and `\UXXXXXXXX` are included
  ## because they are the only way to write a character outside the source
  ## encoding, and a database that cannot store one is a database someone
  ## works around by base64-ing it into a string property.
  let e = l.advance()
  case e
  of 'n': acc.add '\n'
  of 't': acc.add '\t'
  of 'r': acc.add '\r'
  of 'b': acc.add '\b'
  of 'f': acc.add '\f'
  of '0': acc.add '\0'
  of '\\': acc.add '\\'
  of '\'': acc.add '\''
  of '"': acc.add '"'
  of '/': acc.add '/'
  of 'u', 'U':
    let width = if e == 'u': 4 else: 8
    var v = 0'u32
    for _ in 0 ..< width:
      let c = l.peek()
      if not (isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')):
        l.fail("malformed \\" & $e & " escape")
      discard l.advance()
      v = v * 16 + uint32(
        (if isDigit(c): ord(c) - ord('0')
         elif c >= 'a': ord(c) - ord('a') + 10
         else: ord(c) - ord('A') + 10))
    ## A lone surrogate is not a character; openCypher rejects it and so do
    ## we, rather than storing something that no UTF-8 encoder will accept.
    if v >= 0xD800'u32 and v <= 0xDFFF'u32:
      l.fail("escape is a lone surrogate")
    acc.add Rune(v).toUtf8
  else:
    l.fail("unknown escape \\" & $e)

proc nextToken*(l: var Lexer): Token =
  skipTrivia(l)
  result.line = l.line
  result.col = l.col
  if l.atEnd:
    result.kind = tkEof
    return

  let c = l.peek()

  # ---- identifiers and keywords -----------------------------------
  if isIdentStart(c) or c == '`':
    if c == '`':
      discard l.advance()
      while true:
        if l.atEnd:
          l.fail("unterminated quoted identifier")
        let ch = l.advance()
        if ch == '`':
          break
        if ch == '\n':
          l.fail("newline inside a quoted identifier")
        result.text.add ch
    else:
      while isIdentChar(l.peek()):
        result.text.add l.advance()
    result.kind = tkIdent
    return

  # ---- numbers -----------------------------------------------------
  if isDigit(c):
    var text: string
    while isDigit(l.peek()):
      text.add l.advance()
    var isFloat = false
    ## A `.` is a fraction only when a digit follows: `1..3` is a range, and
    ## a lexer that cannot tell them apart cannot lex variable length.
    if l.peek() == '.' and isDigit(l.peek(1)):
      isFloat = true
      text.add l.advance()
      while isDigit(l.peek()):
        text.add l.advance()
    if l.peek() in {'e', 'E'}:
      isFloat = true
      text.add l.advance()
      if l.peek() in {'+', '-'}:
        text.add l.advance()
      if not isDigit(l.peek()):
        l.fail("exponent has no digits")
      while isDigit(l.peek()):
        text.add l.advance()
    result.kind = if isFloat: tkFloat else: tkInt
    result.text = text
    if isFloat:
      result.num = parseFloat(text)
    else:
      ## Overflow is a range error at semantic time, not a lexing error, so
      ## the widest integer that fits is what lands here.
      try:
        result.uval = parseBiggestUInt(text)
      except ValueError:
        l.fail("integer literal out of range: " & text)
        result.uval = 0
      ## Two's complement makes the reinterpretation exact for everything
      ## that fits, including the value a negative fold will produce.
      result.intNum = cast[int64](result.uval)
    return

  # ---- strings -----------------------------------------------------
  if c == '\'' or c == '"':
    let quote = l.advance()
    while true:
      if l.atEnd:
        l.fail("unterminated string literal")
      let ch = l.advance()
      if ch == quote:
        break
      if ch == '\\':
        lexEscape(l, result.str)
      elif ch == '\n':
        l.fail("newline inside a string literal")
      else:
        result.str.add ch
    result.kind = tkString
    return

  # ---- parameters -------------------------------------------------
  if c == '$':
    discard l.advance()
    ## `$` alone is a syntax error rather than a symbol, because a lone `$`
    ## is a typo of a parameter in every case and a "symbol" error would
    ## send the caller looking for a grammar that has one.
    if not isIdentStart(l.peek()):
      l.fail("expected a parameter name after '$'")
    result.kind = tkParam
    while isIdentChar(l.peek()):
      result.text.add l.advance()
    return

  # ---- symbols, longest match --------------------------------------
  for sym in Symbols:
    if l.src.len - l.pos >= sym.len and
       l.src[l.pos ..< l.pos + sym.len] == sym:
      for _ in 0 ..< sym.len:
        discard l.advance()
      result.kind = tkSym
      result.text = sym
      return

  l.fail("unexpected character '" & $c & "'")

proc tokenize*(src: string): seq[Token] =
  ## The whole token stream, EOF included. Used by the tests and by the
  ## statement layer's "why is this query rejected" path; the parser itself
  ## pulls one token at a time so a 4 KB query does not become 4 KB of
  ## tokens before the first row.
  var l = initLexer(src)
  while true:
    let t = l.nextToken()
    result.add t
    if t.kind == tkEof:
      break

proc isKeyword*(t: Token, kw: string): bool {.inline.} =
  ## Case-insensitive by contract: Cypher keywords are not case sensitive
  ## and identifiers are, so this must only be used where the parser has
  ## already established it is looking at a keyword position.
  t.kind == tkIdent and cmpIgnoreCase(t.text, kw) == 0

proc describe*(t: Token): string =
  case t.kind
  of tkEof: "end of query"
  of tkIdent: "identifier " & t.text
  of tkInt: "integer " & t.text
  of tkFloat: "number " & t.text
  of tkString: "string literal"
  of tkParam: "parameter " & t.text
  of tkSym: "'" & t.text & "'"