## glyphes — the FFI boundary re-export.
##
## This module exists so `import glyphes/ffi` has something to resolve to
## and so the boundary's rules are stated in one place. The declarations
## live in abi.nim (types and constants) and glyphes.nim (the exported
## procs); this file is the map between them and the reason the header
## exists at all.
##
## `{.dynlib.}` on every export is load-bearing, not stylistic. Nim 2.2's
## `exportc` alone emits N_LIB_PRIVATE, which is
## `__attribute__((visibility("hidden")))`: the symbol compiles, links,
## produces a valid .so, and is then invisible to dlopen. The symptom is
## FFI::NotFoundError against a library whose `nm` output does contain the
## name. Verified by probe before it was written down — see M0-NOTES §1.
##
## The other boundary rule worth remembering: a GlyHandle is a uintptr_t
## *scalar*, so the Ruby side binds it as :uint64. Bound as :pointer, FFI
## passes the address of the FFI object as the handle value and the first
## call fails GLY_ERR_STALE with a handle number that is visibly a heap
## address. M0-NOTES §4.

import ./abi
import ./errors
import ./handles

export abi, errors, handles
