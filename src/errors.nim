## glyphes — the error slot (ABI.md B8)
##
## Errors are a status code plus a message in a slot. Nim exceptions
## never cross the ABI: an exception unwinding into a Ruby stack frame is
## undefined behaviour, not a recoverable error, so every exported proc
## catches and returns a GlyStatus instead.
##
## Two slots, per ABI.md: a handle-local one for errors attributable to
## an object, and a thread-local global for errors raised before any
## handle exists (bad arguments, OOM). ffi.rb reads the global through
## glyphes_global_error.

import std/strutils
import ./abi

when defined(js):
  {.error: "glyphes targets native hosts only (ABI.md P1)."}

type
  GlyError* = object of CatchableError
    ## Internal only. Never crosses the ABI; it exists so Nim-internal
    ## call sites can use ordinary exceptions and the boundary can
    ## convert them to status codes in one place.
    status*: GlyStatus

var
  globalError {.threadvar.}: string
  globalErrorC {.threadvar.}: cstring

proc setGlobalError*(msg: string) =
  ## Thread-local (ABI.md B9: no hidden shared state except this slot).
  ##
  ## The cstring mirror is reallocated on every set rather than returned
  ## from the Nim string: Nim 2.x forbids casting a `string` to
  ## `cstring`, and the alternative — allocating a fresh buffer for the
  ## caller and documenting that they must free it — would put a second
  ## allocator in the ABI (ABI.md B1, and the §7 note on why
  ## engine-allocated strings were rejected).
  globalError = msg
  if globalErrorC != nil:
    deallocShared(globalErrorC)
  if msg.len == 0:
    globalErrorC = nil
  else:
    ## Raw alloc + copyMem rather than allocCStringArray: that one takes
    ## an openArray[string] and builds a *vector* of C strings (it is
    ## for argv-style arrays), which is a different shape entirely.
    let buf = cast[ptr UncheckedArray[char]](alloc(msg.len + 1))
    ## unsafeAddr msg[0] rather than the 1.x cstringData, which Nim 2
    ## removed. Safe here because the length-0 case returns above, so
    ## msg[0] always exists.
    copyMem(addr buf[0], unsafeAddr msg[0], msg.len)
    buf[msg.len] = '\0'
    globalErrorC = cast[cstring](buf)

proc globalErrorMsg*(): string = globalError

proc globalErrorCStr*(): cstring = globalErrorC

proc clearGlobalError*() =
  globalError = ""
  if globalErrorC != nil:
    deallocShared(globalErrorC)
    globalErrorC = nil

proc fail*(status: GlyStatus, msg: string) {.noreturn.} =
  ## Raise with a specific status. Named `fail` rather than `raise`
  ## because `raise` is a keyword and cannot be overloaded usefully.
  var e = new(GlyError)
  e.msg = msg
  e.status = status
  raise e

proc failf*(status: GlyStatus, fmt: string, args: varargs[string]) {.noreturn.} =
  ## Formatted variant. Separately named rather than an overload because
  ## a varargs overload of `fail` makes every two-argument call
  ## ambiguous, which Nim resolves by erroring at every call site.
  fail(status, fmt & args.join(" "))

proc statusOf(e: ref Exception): GlyStatus =
  ## Map a Nim exception onto a status code. GlyError first, because it
  ## carries the specific status; everything else is a generic failure,
  ## and a Defect is deliberately not distinguishable from any other
  ## Exception here — the exported procs log it as a DEFECT before
  ## calling this, because a Defect reaching the boundary means the host
  ## process is already in an unknown state.
  if e of GlyError:
    return (cast[ref GlyError](e)).status
  glyErr
