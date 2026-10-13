## glyphes — named parameters, from one JSON object (ABI.md B5)
##
## A hand-written reader over `std/json`, because the value model is the
## store's `Value` and `json`'s model is its own: `JsonNode` → `Value` is a
## conversion that has to happen somewhere, and doing it here keeps the
## statement layer free of a second tree type.
##
## `null`, bool, int, float, string, and arrays/objects of those are legal.
## A parameter that is itself a map becomes `vkMap`, which is what
## `UNWIND $rows AS row` with `row.title` needs — and is why the conversion
## is recursive rather than scalar-only.

import std/[json, strutils, tables]
import ../store/prop
import ../abi

proc convert(j: JsonNode): Value =
  case j.kind
  of JNull: Value(kind: vkNull)
  of JBool: Value(kind: vkBool, b: j.getBool)
  of JInt: Value(kind: vkInt, i: j.getInt)
  of JFloat: Value(kind: vkFloat, f: j.getFloat)
  of JString: Value(kind: vkString, s: j.getStr)
  of JArray:
    var items: seq[Value] = @[]
    for item in j.items:
      items.add convert(item)
    Value(kind: vkList, items: items)
  of JObject:
    var pairs: seq[(string, Value)] = @[]
    for key, value in j:
      pairs.add (key, convert(value))
    Value(kind: vkMap, pairs: pairs)

proc parseParamsJson*(text: string): Table[string, Value] {.raises: [CatchableError].} =
  ## `{ "$name": value, … }`. An object is required: a scalar or an array at
  ## the top level is a caller error with a name, not a silent empty table —
  ## a query whose `$n` silently becomes null reads as "no rows", which is
  ## the wrong-answer shape this layer exists to prevent.
  result = initTable[string, Value]()
  if text.strip == "":
    return
  let root = parseJson(text)
  if root.kind != JObject:
    raise newException(ValueError,
      "parameters must be a JSON object of named values")
  for key, value in root:
    ## The binding layer passes names without the `$`; the engine's
    ## `ekParam` carries the bare name too. A `$` in the JSON key is
    ## accepted and stripped, because both spellings appear in the wild.
    let name = (if key.startsWith("$"): key[1 ..^ 1] else: key)
    result[name] = convert(value)
