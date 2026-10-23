## gbasic_channel.nim — the host's end of the guest channel.
##
## The guest (the eZ80) has no compiler and no graph: it sends a line
## and reads an answer. This module is what answers.
##
## The vocabulary is small on purpose — the guest has to *parse* the
## answers, and a guest that parses JSON is a guest that needs a JSON
## parser in 3 KB of assembly:
##
##     gq <line>            a GLYPH QUERY line: the ids it matched
##     exec <line>          a GLYPH QUERY write: how many entities landed
##     props <id>           a node's label, then "key value" per property
##     edges <id>           "TYPE -> other" / "TYPE <- other" per edge
##     link <a> <t> <b>     one edge between two existing nodes
##
## A request is a verb, a space, and its argument — and a `gq`
## request may carry parameters after a TAB (9): the GLYPH QUERY line
## has spaces in it, and a tab cannot appear in one (the compiler's
## lexer would refuse it) — so a tab is a separator the guest can
## trust. The parameters are `name=value` fields: the guest's names
## hold node ids, and a value is a parameter on this side of the
## channel just as it is on every other side (pin GQ4).
##
## The answers are lines, separated by CR, and a *value* that contains
## a space is fine: the key and the value are split at the first space,
## and the rest of the line is the value.
##
## An answer that begins with "!" is a refusal, and the rest of the
## line is the message. The guest's whole job is to show what it was
## told, and a refusal it cannot see is a refusal the child never
## learns about.

import std/[strutils, tables]
import ./gbasic
import ./gbasic_store
import ./gq
import ./database
import ./store/prop

const
  TAB = '\t'

proc failAnswer(msg: string): string =
  ## A refusal, in the one shape the guest can recognise.
  result = "!" & msg.replace("\r", " ").replace("\n", " ")

proc idsAnswer(ids: seq[int64]): string =
  ## The ids, comma-separated. An empty answer is an empty line: the
  ## guest must be able to tell "nothing matched" from "no answer".
  var parts: seq[string] = @[]
  for i in ids:
    parts.add $i
  result = parts.join(",")

proc parseParamField(field: string; params: var Table[string, Value]) =
  ## One `name=value` field. The value is a number or a quoted string —
  ## the two things a client's name holds that a query can use.
  let eq = field.find('=')
  if eq <= 0:
    raise newException(ValueError, "a parameter field needs a name and a value")
  let name = field[0 ..< eq].strip()
  var text = field[eq + 1 .. ^1].strip()
  if text.len >= 2 and text[0] == '"' and text[^1] == '"':
    params[name] = Value(kind: vkString, s: text[1 .. ^2])
    return
  if text == "true":
    params[name] = Value(kind: vkBool, b: true)
    return
  if text == "false":
    params[name] = Value(kind: vkBool, b: false)
    return
  var n: int64 = 0
  var ok = text.len > 0
  for ch in text:
    if ch in {'0'..'9'}:
      n = n * 10 + (ord(ch) - ord('0'))
    else:
      ok = false
  if not ok:
    raise newException(ValueError,
      "the parameter '" & name & "' is not a number or a quoted string")
  params[name] = Value(kind: vkInt, i: n)

proc gqAnswer(t: GbTransport; line: string;
              params: Table[string, Value]): string =
  ## One GLYPH QUERY line, run through the door, answered with the ids
  ## it matched (or the labels, for the `labels` statement).
  ##
  ## The door is asked directly, not through the client's statement
  ## runner: the guest sends *GLYPH QUERY*, and the guest's names are
  ## already values by the time they reach here.
  let res = t.runFn(line, params)
  if res.ids.len > 0:
    return idsAnswer(res.ids)
  if res.labels.len > 0:
    return res.labels.join("\r")
  ## `count` answers even when the answer is zero: the guest prints the
  ## digits it was given, and an empty answer would print as nothing
  ## where the client prints "0".
  let head = line.splitWhitespace()
  if head.len > 0 and head[0].toLowerAscii == "count":
    return $res.count
  if res.count != 0:
    return $res.count
  ""

proc propsAnswer(t: GbTransport; id: int64): string =
  ## A node's label, then its properties — the shape the guest's `show`
  ## prints.
  var text = ""
  for (k, v) in t.propsFn(id):
    if text.len > 0: text.add "\r"
    if k == "label":
      text.add "label " & v
    else:
      text.add k & " " & v
  text

proc edgesAnswer(t: GbTransport; id: int64): string =
  ## A node's edges, in the shape the client prints them: the type, the
  ## arrow, and the far end. The arrow is the client's (`->` / `<-`),
  ## not a direction code — the guest prints the line as it stands.
  var text = ""
  for (rtype, other, forward) in t.edgesFn(id):
    if text.len > 0: text.add "\r"
    text.add rtype & (if forward: " -> " else: " <- ") & $other
  text

proc channelAnswer*(db: Database; request: string): string =
  ## The host's answer to one request. Never raises: the channel has no
  ## way to carry an exception, and a refusal the guest cannot see is a
  ## refusal the child never learns about.
  let t = newStoreTransport(db)
  let line = request.strip()
  if line.len == 0:
    return failAnswer("an empty request")
  try:
    ## The request is split in two: the head (a verb and its argument,
    ## separated by a space) and the parameters (after the first tab).
    let tabAt = line.find(TAB)
    let head = (if tabAt < 0: line else: line[0 ..< tabAt]).strip()
    var paramFields: seq[string] = @[]
    if tabAt >= 0:
      for field in line[tabAt + 1 .. ^1].split(TAB):
        if field.strip.len > 0:
          paramFields.add field
    let spaceAt = head.find(' ')
    let verb = (if spaceAt < 0: head else: head[0 ..< spaceAt]).toLowerAscii
    let arg = (if spaceAt < 0: "" else: head[spaceAt + 1 .. ^1].strip())
    case verb
    of "gq":
      if arg.len == 0:
        return failAnswer("gq needs a GLYPH QUERY line")
      var params = initTable[string, Value]()
      for field in paramFields:
        parseParamField(field, params)
      gqAnswer(t, arg, params)
    of "exec":
      ## A write: the answer is how many entities landed, because the
      ## client prints that ("1 created", "1 updated", "1 dropped") and
      ## the guest must print the same.
      if arg.len == 0:
        return failAnswer("exec needs a GLYPH QUERY line")
      var params = initTable[string, Value]()
      for field in paramFields:
        parseParamField(field, params)
      $t.runFn(arg, params).affected
    of "props":
      if arg.len == 0:
        return failAnswer("props needs a node id")
      propsAnswer(t, parseInt(arg))
    of "edges":
      if arg.len == 0:
        return failAnswer("edges needs a node id")
      edgesAnswer(t, parseInt(arg))
    of "link":
      let parts = arg.splitWhitespace()
      if parts.len != 3:
        return failAnswer("link needs two ids and a type")
      $t.linkFn(parseInt(parts[0]), parts[1], parseInt(parts[2]))
    else:
      ## An unprefixed line is a GLYPH QUERY line: the guest's own
      ## statements compile to one, and the guest sends it as it stands.
      gqAnswer(t, head, initTable[string, Value]())
  except CatchableError as e:
    failAnswer(e.msg)
