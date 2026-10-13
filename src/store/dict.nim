## glyphes — the string dictionary (STORAGE.md §4)
##
## One implementation, three instances: labels, relationship types, and
## property keys. Interning a string twice returns the same code, which
## is what lets `CREATE (:Person)` and `MATCH (p:Person)` agree without a
## string compare at query time.
##
## Codes are assigned in first-seen order starting at 1. Code 0 means
## "unlabelled"/"untyped" and is never assigned — it is the value a
## zeroed record already carries.
##
## Append-only (STORAGE.md S10): a code is never reassigned, so a
## snapshot is a straight dump of `codes` and no caller can be left
## holding a code that now means something else.

import std/strutils

type
  Dictionary* = object
    codes*: seq[string]   ## index 0 is the empty placeholder for code 0
    index*: seq[int32]    ## hash slot -> code; 0 empty, -1 tombstone
    count*: int           ## live entries, excluding tombstones
    used*: int            ## occupied slots incl. tombstones

const
  EmptySlot = 0'i32
  Tombstone = -1'i32

proc initDict*(d: var Dictionary, capacity: int = 64) =
  ## The hash table is a power of two so the probe index is a mask
  ## rather than a modulo, and grows at a 0.75 load factor.
  d.codes = @[""]                     ## code 0: never assigned
  var cap = 16
  while cap < max(capacity, 16) * 2:
    cap = cap shl 1
  d.index = newSeq[int32](cap)
  for i in 0 ..< d.index.len:
    d.index[i] = EmptySlot
  d.count = 0
  d.used = 0

proc hashOf(s: string): uint32 =
  ## FNV-1a. Not a cryptographic hash and does not need to be: the only
  ## adversary is a pathological key name, and a 32-bit hash keeps the
  ## table half the size of a 64-bit one for no measurable difference at
  ## the distinct-key counts a label or property-key set ever reaches.
  result = 2166136261'u32
  for ch in s:
    result = (result xor uint32(byte(ch))) * 16777619'u32

proc grow(d: var Dictionary) =
  var newIdx = newSeq[int32](d.index.len * 2)
  for i in 0 ..< newIdx.len:
    newIdx[i] = EmptySlot
  for code in 1 ..< d.codes.len:
    var slot = int(hashOf(d.codes[code]) and uint32(newIdx.len - 1))
    while newIdx[slot] != EmptySlot:
      slot = (slot + 1) and (newIdx.len - 1)
    newIdx[slot] = int32(code)
  d.index = newIdx
  d.used = d.codes.len - 1

proc intern*(d: var Dictionary, s: string): int32 =
  ## Intern and return the code. Idempotent.
  if d.index.len == 0:
    initDict(d)
  var slot = int(hashOf(s) and uint32(d.index.len - 1))
  while true:
    let occupied = d.index[slot]
    if occupied == EmptySlot:
      break
    if occupied != Tombstone and d.codes[occupied.int] == s:
      return occupied
    slot = (slot + 1) and (d.index.len - 1)

  d.codes.add s
  result = int32(d.codes.len - 1)
  d.index[slot] = result
  inc d.count
  inc d.used
  # 0.75 load factor: grow *after* inserting so a single-item dictionary
  # still probes correctly, and so `count` is never observed mid-grow.
  if float(d.used) * 4.0 > float(d.index.len) * 3.0:
    grow(d)

proc lookup*(d: Dictionary, s: string): int32 =
  ## The code for `s`, or 0 if not interned. The query path calls this
  ## so a `MATCH (p:Nonexistent)` is a miss rather than an allocation.
  if d.index.len == 0:
    return 0
  var slot = int(hashOf(s) and uint32(d.index.len - 1))
  while true:
    let occupied = d.index[slot]
    if occupied == EmptySlot:
      return 0
    if occupied != Tombstone and d.codes[occupied.int] == s:
      return occupied
    slot = (slot + 1) and (d.index.len - 1)

proc nameOf*(d: Dictionary, code: int32): string =
  ## The string for a code, or "" for code 0 or an out-of-range code.
  if code <= 0 or code.int >= d.codes.len:
    return ""
  d.codes[code.int]

proc count*(d: Dictionary): int {.inline.} = d.count
