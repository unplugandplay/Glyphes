## glyphes — errors at the query layer (CYPHER.md §5)
##
## One type, carrying the ABI status it becomes. A parse error and an
## out-of-contract construct are both `CypherError`; they differ in the code
## the host sees, which is the difference between "your query has a typo"
## and "that is a M6 feature" — and PRD §5.1 requires the second to be
## specific rather than a wrong answer.
##
## The Nim type is internal: it never crosses the ABI (ABI.md B8). The
## boundary converts `code` into the return value and `msg` into the error
## slot, the same as it does for `GlyError`.

import ../abi

type
  CypherError* = ref object of CatchableError
    ## Hand-built rather than `newException`, for the same reason
    ## `TxError` is: Nim cannot construct a `ref object of CatchableError`
    ## through the normal path.
    code*: int32

proc cypherFail*(code: int32, msg: string) {.noreturn.} =
  var e: CypherError
  new(e)
  e.msg = msg
  e.code = code
  raise e

proc parseFail*(msg: string) {.noreturn.} =
  ## A syntax error. The message carries a `file:line:col` prefix from the
  ## lexer, so this stays as-is rather than decorating it again.
  cypherFail(glyErrSql, msg)

proc unsupported*(what: string) {.noreturn.} =
  ## A construct that parses but is outside the 0.1 contract. Naming the
  ## construct is the whole point: "UNION is not supported in 0.1" is
  ## actionable, "syntax error" is not.
  cypherFail(glyErrUnsupported,
    what & " is outside the glyphes 0.1 contract")

proc errorCode*(e: CypherError): int32 = e.code