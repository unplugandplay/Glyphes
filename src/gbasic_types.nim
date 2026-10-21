## gbasic_types.nim — the values GLYPH BASIC's names can hold.
##
## Its own module because two modules need it: the client (gbasic.nim)
## and the expression evaluator (gbasic_expr.nim). The evaluator works on
## the *names* rather than on the session, so it depends on the values and
## not on the client — and the two do not import each other.

type
  GbValueKind* = enum
    gbvNull, gbvBool, gbvNode, gbvNumber, gbvString

  GbValue* = object
    ## What a name in the session can hold.
    case kind*: GbValueKind
    of gbvNull: discard
    of gbvBool: flag*: bool
    of gbvNode: nodeId*: int64
    of gbvNumber: number*: int64
    of gbvString: text*: string

proc valueText*(v: GbValue): string =
  ## A value as text. A number reads as its number, a string as itself,
  ## and a node id as its id.
  case v.kind
  of gbvNull: ""
  of gbvBool: (if v.flag: "true" else: "false")
  of gbvNode: $v.nodeId
  of gbvNumber: $v.number
  of gbvString: v.text
