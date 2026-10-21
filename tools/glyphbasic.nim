## glyphbasic.nim — the GLYPH BASIC prompt.
##
## A `psql` for the graph: a prompt, a session that remembers where you
## are, and the control flow the query language deliberately has not
## (PRD-GLYPH-BASIC.md).
##
##   glyphbasic <database>
##
## The client reaches the graph through one door (GB1), so this program
## holds no store handle of its own: it opens the database, hands the
## client a transport, and reads lines.

import std/[os, strutils]
import ../src/gbasic
import ../src/gbasic_store
import ../src/database
import ../src/abi

proc main() =
  let args = commandLineParams()
  if args.len != 1:
    stderr.write "usage: glyphbasic <database>\n"
    quit(2)
  let db = openDatabase(args[0], 0)
  let transport = newStoreTransport(db)
  var session = newSession()
  ## `input` reads from the terminal: the client's input is the host's
  ## business, and the guest's would be a port channel.
  session.inputFn = proc(): string =
    try:
      stdin.readLine()
    except EOFError:
      ""
  echo "GLYPH BASIC 1.0 -- a prompt over ", args[0]
  echo "  find <label> [where <expr>]   go [back] <type> [from <name>]"
  echo "  show <name>   count   add   link   set   drop   labels"
  echo "  let <name> = <value>   print <expr>   input <name>"
  echo "  if <expr> then <stmt>   for <var> = <a> to <b> : <stmt> : next"
  echo "  a name holds a node: p = 1, and $p refers to it in a where clause"
  while true:
    stdout.write "ready> "
    stdout.flushFile()
    var line = ""
    try:
      line = stdin.readLine()
    except EOFError:
      break
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    if trimmed.toLowerAscii in ["quit", "exit", "bye"]:
      break
    try:
      if not session.runStatement(transport, trimmed):
        break
    except CatchableError as e:
      ## A refusal is a line of output, not a crash: the prompt must
      ## survive a mistake (GB6).
      echo "[", e.name, "] ", e.msg
    ## The transcript is printed and then cleared: the prompt shows what
    ## the last statement said, not everything the session ever said.
    if session.transcript.len > 0:
      stdout.write session.transcript
      session.transcript.setLen(0)
  close(db)

main()
