# glyphes — M0 notes: what the Nim→FFI seam actually does

Findings from building M0 (2026-10-07). Every one of these cost a
compile-error cycle or a crash, so they are written down where the next
person building on this will find them. Everything here is M0-specific;
the durable rules live in `docs/ABI.md` as pins.

## 1. `{.dynlib.}` is mandatory on every export

Nim 2.2's `{.exportc.}` alone emits `N_LIB_PRIVATE`, which is
`__attribute__((visibility("hidden")))`. The symbol compiles, links, and
produces a valid `.so` — and is then invisible to `dlopen`:

```
$ nim c --app:lib --noMain:on p.nim          # proc f() {.exportc.}
$ nm -gU libp.so | grep foo
                                     # nothing
$ ruby -e 'require "ffi"; ...'
FFI::NotFoundError: Function 'foo' not found
```

`{.dynlib.}` sets `lfExportLib`, which switches the emitter to
`N_LIB_EXPORT` (`nimbase.h:220`, `ccgtypes.nim:1231`). Every exported proc
in `src/glyphes.nim` therefore carries `{.cdecl, exportc, dynlib.}`.

This is the single most common Nim→FFI failure and it is completely
silent until the host tries to call in.

## 2. `--app:lib` needs `NimMain` to be called

Module initialization — global `seq`s, string literals, the ORC
allocator's page cache — lives in an exported `NimMain`, and **nothing
calls it** in a plain `--app:lib` build. The result is a segfault inside
the engine's own allocator on the first heap allocation, at an address
near null, with no Nim-level backtrace, in the host process:

```
rawAlloc  <-  cstrToNimstr  <-  glyphes_open
Segmentation fault at 0x0000000000000010
```

`src/glyphes_init.c` attaches an `__attribute__((constructor))` that calls
`NimMain()`, so `dlopen` does it for any host. The Ruby binding does not
depend on this having worked — `GLYPHES_LIB` plus the constructor is
enough — but a C constructor is the only version that protects a host
which knows nothing about Nim.

Confirmed by probe before it was written down: calling `NimMain` by hand
from Ruby made the same library work.

## 3. `Glyphes::FFI` shadows the `FFI` constant

Naming the module `Glyphes::FFI` means every `FFI::MemoryPointer` inside
`module Glyphes` resolves to `Glyphes::FFI::MemoryPointer`, which does not
exist. The fix is to re-export the primitives the shadowing hides:

```ruby
MemoryPointer = ::FFI::MemoryPointer
```

Cheap, and it turns a confusing `NameError` into nothing at all.

## 4. `GlyHandle` is a scalar, not a pointer

`uintptr_t` in C, so it binds as `:uint64` in FFI — not `:pointer`.
Binding it as `:pointer` passes *the address of the FFI object* as the
handle value, and the first call fails as `GLY_ERR_STALE` with a handle
number that is visibly a heap address.

The confusing part is that `glyphes_open` takes `GlyHandle *out_db`, which
*is* a pointer, so both spellings appear in the same header. The
distinction is per-parameter, not per-type.

## 5. A Hash literal with `Name:` keys silently produces Symbols

```ruby
LAYOUT = { GlyCell: 24, GlyStat: 64 }
#              ^^^ Symbol key, not the class
```

The load-time layout assertion then measured `Symbol#size` and reported
`7` (the length of `:GlyCell`), raising a LoadError about a struct
mismatch that did not exist. Hash rockets, `{ Cell => 24 }`, keep these as
class objects.

## 6. Nim keywords in ABI-shaped names

`ptr` and `out` are Nim keywords and cannot be parameter or field names
without escaping: `` `ptr` `` for the field, and a rename for the
parameter. `GlyCell.ptr` and `GlyCell.len` are the C names; the escape
keeps them matching the header.

## 7. C string parameters lose `const`

Nim emits `NCSTRING` (`char *`) for its own declaration of each exported
proc. Having both the header's `const char *` and Nim's `char *` visible
to clang is a conflicting-types error. The header therefore declares
input strings as `char *`, and the engine copies into Nim-owned memory on
entry so nothing writes through it. `docs/glyphes.h` says so at the top.

An em dash in a C comment is also a hard error, not a style nit.

## 8. ASan cannot install interceptors from `dlopen`

```
==88561==ERROR: Interceptors are not working. This may be because
AddressSanitizer is loaded too late (e.g. via dlopen).
```

`nimble asan` sets `DYLD_INSERT_LIBRARIES` to the ASan runtime so Ruby
starts with it preloaded. Without that, the suite runs and reports green
while ASan watches nothing — the worst possible failure mode for a
sanitizer.

The run does emit `ERROR: Failed to munmap` at exit: Nim's ORC allocator
returns pages to the OS in a way ASan's shadow mapping does not tolerate.
That is a known ASan/Nim interaction, not a glyphes bug, and it appears
only after the results line. Treat a non-zero `runs,` count as the signal.

## 9. The registry must hold a reference, not a pointer

`handles.nim` originally stored a bare `pointer`. Under ORC, the
`ref Database` created inside `glyphes_open` is destroyed when that proc
returns, so every subsequent call was use-after-free. It surfaced as
`GLY_ERR_CLOSED` from an unrelated database in the interleaving test.

`register` is now typed as `register*(kind, obj: ref T)` and calls
`GC_ref`; `release*(h)` unrefs after marking the slot dead. Typing it as
`ref T` rather than `pointer` is the point: the GC_ref cannot be forgotten
at a call site.

## 10. `--threads:on` is required

`{.acquire.}`/`{.release.}` are gone in Nim 2.x, and `withLock` needs
threads enabled. Every build flag in `glyphes.nimble` passes
`--threads:on`, including the library build — the handle registry has a
real mutex, and `TXN.md` §7 requires distinct handles to be independent
across threads.

## 11. `lib/glyphes/` is source, not build output

The first `.gitignore` had `lib/glyphes/` in it, from reading the nimble
`mkdir lib` as if it made an artifact directory. It did not: `lib/glyphes/`
holds the gem's Ruby sources. A later `rm -rf lib/glyphes` to clear a stale
build deleted them, and they had to be rewritten from scratch.

Two rules from that, both now in `.gitignore` as a comment: never ignore a
source directory that shares a name with a build step's output, and read
`.gitignore` before running a recursive delete.

## 12. `module_function` in the parent module shadows

`module_function def check!` directly under `module Glyphes` installs a
private instance method on every class nested in `Glyphes`, so
`Database#check!` shadowed the module function and blew up. It lives in
`Glyphes::Guard` now.

## Not yet exercised

M0 has no store, no WAL, no statements. Everything below is written but
untested by code, and the tests for it belong to its milestone:

- `glyes_stmt_*`, `glyphes_cell_*`, `glyphes_index_*` — declared in
  `src/glyphes.h`, not implemented
- the `cap` in/out protocol for JSON out-params (`ABI.md` §7)
- `GlyPath` component accessors and their bounds checks
- `GLY_MORE` / `GLY_DONE` streaming, which is the whole reason `Cell` is
  24 bytes and batched
