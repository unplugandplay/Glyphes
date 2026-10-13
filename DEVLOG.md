# glyphes — DevLog

Chronological build log: what landed, what broke, what each failure
taught. Companion to [`docs/PRD-GLYPHES.md`](docs/PRD-GLYPHES.md) (the
contract), [`docs/M0-NOTES.md`](docs/M0-NOTES.md) (the Nim→FFI seam in
detail), and [`ENHANCEMENTS.md`](ENHANCEMENTS.md) (what comes next).
Everything here is reproducible from the working tree + `nimble gate`.

**Where it is now:** **M0–M4 landed.** `nimble gate` = 217 Nim tests + 64
Ruby tests + the TCK subset + four benchmark/stress gates, 0 failures;
`nimble asan` runs both suites under AddressSanitizer clean and TSan is
clean over the soak. The store holds a graph (dense ids, threaded adjacency
both ways, property slots over a length-prefixed arena, O(1) label
removal), the WAL survives `kill -9`, transactions commit or roll back from
Ruby, and `db.query` answers a Cypher read:

```
M1 store bench    create 1360 <= 8000   traversal 167 <= 400   heap 619 <= 680 MB
C1 TCK subset     71/71 in-contract (gate 95%), 18/18 refusals name their construct
C9 query bench    96 977 queries/s (gate 50 000), 2-hop 0.066 ms (gate 3 ms)
W1 / T1           crash recovery and reader/writer soak both green
```

Nothing survives a crash yet, and nothing can write a graph from Ruby yet.
Both are M2 and M4.

| § | Milestone | The one thing it taught |
|---|---|---|
| review | specs before code | four of my own claims were wrong — a memory gate below its own computed cost, a struct 8 bytes smaller than stated, two colliding pin namespaces |
| M0 | ABI spine | `{.dynlib.}` is mandatory and `--app:lib` never calls `NimMain`; both fail silently, one as "symbol not found" and one as a segfault in the host process |
| M0 | handle registry | under ORC a raw `pointer` in a table is use-after-free on the very next call — type the API `ref T` so the refcount cannot be forgotten |
| M0 | repo hygiene | I deleted the gem's own source with `rm -rf`, because a `.gitignore` line I'd written made a source directory look like build output |
| M1 | the store | tabulate the fields and let the compiler disagree with you — `PropSlot` was 24 bytes in the spec and 16 everywhere else |
| M1 | the store | put the number in a fixture: 91 passing tests missed 320 MB of padding, and one grep-sized benchmark caught it |
| M1 | the store | a bump allocator cannot bounds-check a sub-range, so every variable-length thing in it needs a length prefix |
| M3 | the boundary | the constructor that calls `NimMain` belongs to the dylib alone — in a test binary it re-initialises the heap under itself |
| M3 | the boundary | a Ruby thread is a foreign thread to Nim: without `setupForeignThreadGc` the first allocation takes the host process down |
| M3 | the memory gate | the gate was named RSS and measured `getOccupiedMem()`; true peak RSS is 1 100 MB, and a "regression" in it was the metric, not the store |
| M4 | the parser | three of the four relationship directions were wrong in the first version, and a fold that returned its input dropped the minus from `-2^2` |

---

## Review — the specs, before any code

The specs were written over several passes with no compiler attached.
Computing the byte layouts properly, which is the first thing M1 needs
anyway, turned up four errors in my own work.

**1. `GlyCell` is 24 bytes, not 32.** `ABI.md` §1 said 32 for
`{ u32, u32, ptr, u64 }`, which is 4+4+8+8. The document whose first rule
is "no struct by value, ever" was carrying a size figure that would invite
a hand-rolled layout in FFI — the exact failure rule 1 exists to prevent.
Corrected, and `lib/glyphes/ffi.rb` now asserts the size at load time so
the next drift is a `LoadError` on `require`.

**2. Two `P` pin namespaces.** The PRD pins P1–P12 at the project level;
`ABI.md` pins P1–P10 at the boundary. References in the wild read
`ABI.md P3` and "PRD pin P7" and mean different things by the same
number. ABI's pins became B1–B10, which is also a better name for what
they are: boundary rules, not project rules.

**3. The memory model did not add up.** `STORAGE.md` §7 claimed 11×10⁶
slots and then wrote 72 MB for them — which is the figure for 3×10⁶. The
edge properties had been dropped from the count while staying in the
product. At 24 B per slot the real figure is 264 MB, and the total blows
past the memory gate I had amended to 480 MB *in the previous revision of
the same amendment*.

The fix was to stop doing arithmetic in prose. §7 now states an exact
fixture (10⁶ nodes, 4·10⁶ edges, 3 node properties of which one 40-char
string, 1 edge property), computes every line, and lands on 501 MB — so
the gate is **620 MB** with ~120 MB of headroom for allocator
fragmentation and `seq` growth slack. Pin S13 now requires every memory
gate to show its arithmetic, because a gate picked by intuition gets
weakened under pressure later, and a gate that cannot pass is worse than
no gate.

**4. Multi-label nodes were rejected but never explained.** The
rejection list said `(a:A:B)` is unsupported; nothing said why. It is
because `NodeRec.label` is a single `i32`, and multiple labels need a
variable-length field in a fixed-size record — the one thing
`STORAGE.md` §1 forbids. `CYPHER.md` §2.1 now says that, and points at
`(:Person)-[:HAS_ROLE]->(:Role)` as the modelling answer, which is
better for querying anyway.

Also settled at review time, because M0 freezes the header and both were
listed as open: the JSON out-param protocol (caller buffer, `cap` in/out,
retry with `cap = *written`) and the path representation (`GlyPath`
out-param plus bounds-checked component accessors, so a Ruby `Path` never
holds raw pointers past its statement).

---

## M0 — the ABI spine

The smallest milestone with the most unknowns. Its job was to answer
"can Nim produce a loadable library that Ruby can call safely" before the
store, the WAL, and the query planner were built on top of the answer.

### The two that would have cost days

**`{.dynlib.}` is mandatory on every export.** Nim 2.2's `{.exportc.}`
alone emits `N_LIB_PRIVATE`, which is
`__attribute__((visibility("hidden")))`. The symbol compiles, links,
produces a working `.so` with no linker error — and is then invisible to
`dlopen`. The symptom is `FFI::NotFoundError: Function 'glyphes_open' not
found` against a library whose `nm` output does contain it.

`{.dynlib.}` sets `lfExportLib`, which switches the emitter to
`N_LIB_EXPORT` (`nimbase.h:220`, `ccgtypes.nim:1231`). Verified by
probe before it was written into the code, because the failure mode is
silent and the fix is not obvious from the error text.

**`--app:lib` never calls `NimMain`.** Module initialization — global
`seq`s, string literals, the ORC allocator's page cache — is emitted into
an exported `NimMain`, and nothing in a plain library build invokes it.
The result is a segfault inside the engine's own allocator on the first
heap allocation, at an address near null, with no Nim-level backtrace,
inside the host process:

```
rawAlloc  <-  cstrToNimstr  <-  glyphes_open
Segmentation fault at 0x0000000000000010
```

I found this by bisecting to a four-line probe: a library whose only
export was `let s = $p; echo s.len` crashed, while one whose only export
was `g += 1` worked. Calling `NimMain` from Ruby by hand fixed it, which
confirmed the diagnosis before the fix was written.

`src/glyphes_init.c` attaches an `__attribute__((constructor))` that calls
`NimMain()`, so `dlopen` does it for any host. Deliberately *not* left to
the Ruby binding: a C constructor is the only version that protects a host
which knows nothing about Nim, which is the whole premise of shipping a
library.

### A memory bug the tests found by accident

The handle registry originally stored a bare `pointer` per slot. Under
ORC, the `ref Database` created inside `glyphes_open` is destroyed when
that proc returns, so every later `glyphes_stat` was use-after-free. It
surfaced as `GLY_ERR_CLOSED` raised against an unrelated, healthy
database in the "interleaved databases are independent" test — which is
what made me look at the registry rather than at the test.

`register` is now `register*(kind: HandleKind, obj: ref T)` and calls
`GC_ref`; `release*(h)` unrefs *after* marking the slot dead, so a lookup
that already passed its liveness check still holds a pointer the
collector has not been told about. Typing the parameter `ref T` rather
than `pointer` is the actual fix: the refcount cannot be forgotten at a
call site. The handle itself works as designed — generation-tagged slots
recycle correctly, and a stale handle returns `GLY_ERR_STALE` rather than
touching freed memory, which is the property that makes `ensure` cleanup
in Ruby safe.

### Smaller things, each worth a line

- **`Glyphes::FFI` shadows the `FFI` constant.** Every
  `FFI::MemoryPointer` inside `module Glyphes` resolved to
  `Glyphes::FFI::MemoryPointer`. Fixed by re-exporting the primitives the
  shadowing hides.
- **`GlyHandle` is a scalar.** `uintptr_t` binds as `:uint64`, not
  `:pointer`. Bound as `:pointer`, FFI passes the *address of* the FFI
  object as the handle value, and the first call fails `GLY_ERR_STALE`
  with a handle number that is visibly a heap address. The confusing part
  is that `glyphes_open` takes `GlyHandle *out_db`, which *is* a pointer,
  so both spellings appear in one header.
- **A Hash literal with `Name:` keys produces Symbols.** The load-time
  layout assertion measured `Symbol#size` and reported `7` — the length
  of `:GlyCell` — raising a `LoadError` about a struct mismatch that did
  not exist. Hash rockets keep them as class objects.
- **Nim keywords in ABI-shaped names.** `ptr` and `out` are keywords;
  `` `ptr` `` for the field, a rename for the parameter.
- **C string parameters lose `const`.** Nim emits `NCSTRING` for its own
  declaration of each export, and having the header's `const char *` and
  Nim's `char *` both visible is a conflicting-types error. The header
  declares input strings as `char *` and the engine copies into Nim-owned
  memory on entry, so nothing writes through it. An em dash in a C
  comment is also a hard error, not a style nit.
- **`module_function` in the parent module shadows.** `module_function
  def check!` directly under `module Glyphes` installs a private instance
  method on every nested class, so `Database#check!` shadowed it. It
  lives in `Glyphes::Guard` now.
- **`{.acquire.}` is gone in Nim 2.x**, and `withLock` needs
  `--threads:on`. Every build flag passes it, including the library
  build, because `TXN.md` §7 requires distinct handles to be independent
  across threads and a registry mutex is the cheapest way to keep that
  true.
- **ASan cannot install interceptors from `dlopen`.** `nimble asan` sets
  `DYLD_INSERT_LIBRARIES` so Ruby starts with the runtime preloaded.
  Without it the suite runs and reports green while ASan watches nothing.
  The run ends with `ERROR: Failed to munmap` — Nim's ORC allocator
  returns pages in a way ASan's shadow mapping does not tolerate, which
  appears *after* the results line and is not a glyphes bug.

### The mistake I made

Cleaning a stale build, I ran `rm -rf lib/glyphes`. That is the gem's
Ruby source directory. It was not a build artifact; it was in `.gitignore`
because I had added `lib/glyphes/` to it while reading a nimble
`mkdir lib` as though it created an artifact directory there. Three files
(`ffi.rb`, `errors.rb`, `database.rb`) were deleted and rewritten from
scratch.

Two rules came out of it, both now written into `.gitignore` as comments
rather than only into this log: never ignore a source directory whose name
collides with a build step's output, and read `.gitignore` before running
a recursive delete. The lesson generalizes past this repo — a hygiene file
that lies about what is source is more dangerous than no hygiene file.

### What landed

```
src/glyphes.h        the ABI, hand-maintained, ASCII comments only
src/abi.nim          the Nim mirror: types via importc, status constants
src/errors.nim       GlyError, the thread-local global error slot
src/handles.nim      generation-tagged handle registry (40/24 bit split)
src/database.nim     the database object; open-mode validation
src/glyphes.nim      the only module with exportc — the whole boundary
src/glyphes_init.c   the constructor that calls NimMain

lib/glyphes.rb       require graph + VERSION
lib/glyphes/ffi.rb   ffi_lib, struct layouts, load-time size assertions
lib/glyphes/errors.rb  one class per GlyStatus value
lib/glyphes/database.rb  Database: open/close/stat, status -> exception
```

Gates: 31 Nim tests (status vocabulary, struct layouts, registry,
database open), 21 Ruby tests (the seam — round-trips, stale handles,
null arguments, idempotent close, error mapping, layout assertions),
both suites clean under ASan.

### What the gate does *not* cover yet

Everything below is declared in `src/glyphes.h` and unimplemented: the
whole statement and cursor surface, the `cap` in/out JSON protocol, the
`GlyPath` accessors, `GLY_MORE`/`GLY_DONE` streaming — which is the
entire reason `Cell` is a fixed 24 bytes and traversed in batches — and
the store, the WAL, and Cypher. `Glyphes::Database` at M0 can tell you
its `generation` is 1 and that is genuinely all it can do.

---

## M1 — the store (next)

Dense ids, `NodeRec` at 48 B and `EdgeRec` at 56 B, threaded adjacency in
both directions, the label dictionary with per-label id lists, and
property slots over a bump arena. No WAL yet — durability is M2 and the
store's write path is the thing M2 logs.

The gate, from `STORAGE.md` §7: 10⁶ nodes / 4·10⁶ edges created in under
8 s, all-traversal under 400 ms, RSS under 620 MB, and degree bookkeeping
exact after 10⁶ random edge operations. That last one is not a benchmark —
it is a correctness check against a brute-force recount, because a drift
in `out_count`/`in_count` corrupts the planner's hub detection silently,
which is the worst kind of bug.

Outstanding decision that M1 does *not* need but M3 does: whether the
merge uses per-record or per-chunk copy-on-write (`TXN.md` §12). It
belongs in M3, and doing it afterwards is a rewrite.

---

## M2 — WAL, snapshot, recovery (in progress)

Durability is in and the crash gate is green, but the milestone is **not
landed**: the code is not yet wired into `glyphes.nimble`, there are no
M2 unit tests, and `docs/WAL.md` still describes a `SetProp` payload the
implementation does not use.

### What works

`src/wal/crc32.nim`, `src/wal/wal.nim`, `src/wal/snapshot.nim`,
`src/wal/recover.nim`, `src/txn/txn.nim`, and the crash harness under
`tests/fuzz/`. WAL.md W1 is green: 25 `kill -9`s spread over a 100-transaction
import, every one recovering to a graph that is *exactly* the graph a clean
run of the same seed produces at the last committed transaction.

That last part is the part worth keeping. The first version of the harness
compared a killed run against the harness's own clean run, which uses seed 1
while every killed run uses its own seed — so it was measuring the two seeds
disagreeing, and it "passed" while recovering graphs with more edges than the
clean one. The harness now re-runs the child with the same seed stopped at
the recovered transaction and compares that. A prefix of a schedule is only
comparable to a prefix of the *same* schedule.

### Nine bugs the crash gate found

Every one of these was invisible to the M1 suite, which is the argument for
building the gate before the feature rather than after.

1. **Byte offsets indexed as elements.** `slotBytes[written]` and
   `slots[consumed]` treat a byte offset as a character index. The snapshot
   writer died at exactly `262 slots × 16 B = 4192`, one record past the end.
2. **`totalSlots` counted nodes but not edges**, while the copy loop packed
   both, so the header's slot count was 396 short of what the body held.
3. **Record buffers sized by `nodes.len` instead of `nodes.len - 1`.** Slot 0
   is padding, so 48 phantom bytes shifted every later section by one record.
4. **`inc stop` instead of `at = stop + 1`** in the dictionary reader, so
   every dictionary entry read the first string again and the code-order
   check fired on the second.
5. **The snapshot recorded `lsn: 0`** no matter what `writeSnapshot` was
   passed, so recovery replayed the whole log on top of state that already
   contained it.
6. **`aux` written as one byte.** `PropSlot.aux` is `uint16`; the reader read
   two. Every replayed string and container failed to decode.
7. **Deleting several edges of one chain in a transaction was
   order-dependent.** `unlinkEdge` splices through `nextOut`/`nextIn`, which
   are the links an edge had *when it was created*; removing an earlier edge
   first left the later one pointing at a tombstone that had left the chain.
   The outcome depended on hash-table iteration order. Fixed with
   `rebuildChains`, which re-splices each affected endpoint once — O(degree)
   per node, the order `unlinkEdge` already paid. This was the S4 degree
   mismatch and the S9b tombstone-still-linked pair.

The eighth is structural: `commit` wrote node records *before* merging
edges, so a `setProp` on an endpoint — which copies the *base* record into the
delta, stale heads and all — let the delta overwrite the merge's adjacency.
Node records are now written last, keeping the adjacency the edge merge just
established. The ninth is in replay itself, which ignored `fromLsn`
entirely and started from byte 0, re-applying the whole log on top of state
that already contained it.

### Still to do before M2 lands

- `tests/unit/test_wal.nim`: CRC vectors, frame round-trip, torn tail,
  transaction rollback, snapshot round-trip, replay idempotence.
- Wire M2 into `glyphes.nimble` and into `nimble gate`.
- `docs/WAL.md` §3/§4: describe `opNoop` commit markers and the logical
  `SetProp` payload actually used.
- WAL.md W2 (truncation), W3 (bit flips), W4 (torn tail), W6 (crash during
  checkpoint) are specified but not yet implemented as gates.

---

## M3 — transactions (in progress, T1 RED)

Landed: the error taxonomy (`TxError` now carries a `GlyStatus`-matching
code, so `GLY_ERR_BUSY`/`STALE`/`LIMIT` reach Ruby instead of a generic
failure), the `base_generation` capture and stale-base check, two of the
five budgets, atomic publication of the record arrays, and an atomic
single-writer claim. 13 new tests in `tests/unit/test_txn.nim`: T2, T3,
T5, T8.

**T1 is red and that is the finding.** The soak is 6 readers and 2
writers; it found three things, and two of them were real bugs that no
single-threaded test could have reached.

1. **The writer claim was check-then-act.** `if store.writer != 0` then
   `store.writer = id` let both writers through; one committed on a base
   the other had already replaced. It is now one compare-and-swap. The
   first attempt at that fix was worse than no fix — `Atomic[T]` is a
   value type, so `var loc = s.writerClaim; loc.compareExchange(...)`
   performed the exchange on a *copy* and every claim succeeded. The
   CAS has to run on the field.

2. **The published arrays were not atomic as a set.** `nodes`, `edges`,
   `labelPos` and the label member lists were separate fields committed
   one after another, so a reader could load a new `nodes` beside an old
   `labelPos`. The soak saw a node reporting `outCount 139264`, a value
   assembled from two generations. They are now published as one
   `Published` bundle behind a single assignment — and that assignment
   needed a lock, because a Nim `ref` field is not atomic and the
   refcount update races a concurrent read into a corrupted refcount,
   which surfaces much later as a segfault inside an unrelated allocation.

3. **Still open: two writer threads crash in a heap allocation.**
   `soak.nim` reports `SIGSEGV` inside `encodeValue` → `alloc`, with the
   writer claim serialising them and no reader touching the arena. Not
   diagnosed. Until it is, `nimble gate` does not include the soak and
   M3 does not land.

Also unresolved, and named in `tests/unit/test_txn.nim` as a tripwire:
with a reader outstanding, a cascading delete leaves one node live. The
test asserts today's behaviour, so fixing it turns that test red.

**A hazard the soak deliberately does not paper over:** a property slot
offset belongs to the arena of the generation that produced it, so
combining an old snapshot's `propView` with the store's current arena
reads a payload from wherever that offset now lands. The reader loop in
`soak.nim` therefore checks records and chains and *does not* read
properties, with the reason written down. That needs an answer before
M3 closes — either an arena per generation or slot-level indirection.

---

## M3 — T1 green: what the concurrency gate cost

T1 is now green. 6 readers and 2 writers for 120 s: 11 273 commits, 91 104
`GLY_ERR_BUSY` rejections, zero torn reads, zero invariant violations,
clean under ASan. Getting there took five fixes, and four of them were
real bugs that no single-threaded test could have found. That is the
argument for having written the gate before the feature.

**1. The writer claim was check-then-act.** `if store.writer != 0` then
`store.writer = id` is a race: both writers passed, and one committed on a
base the other had already replaced. It is now one compare-and-swap.

**2. The fix for (1) was worse than the bug.** `Atomic[T]` is a value
type, so the first version did `var loc = s.writerClaim;
loc.compareExchange(...)` — performing the exchange on a *copy*. Every
claim succeeded. The CAS has to run on the field itself.

**3. The published arrays were not atomic as a set.** `nodes`, `edges`,
`labelPos` and the label member lists were separate fields committed one
after another, so a reader could load a new `nodes` beside an old
`labelPos`. The soak caught a node reporting `outCount 139264` — a value
assembled out of two generations.

**4. The reader counter that gated copy-on-write was itself
check-then-act.** The writer sampled "is anyone reading?", saw zero, and
began mutating the published arrays in place — and a reader could
register in the window between the sample and the mutation, then read the
arrays while they were being rewritten. This one had *two* symptoms: a
cascading delete left a node live (a test asserted the wrong behaviour for
weeks of wall-clock before I understood it was a symptom and not a fact),
and long soak runs segfaulted inside an allocation.

**5. The fix for (4) had a refcount race.** Publishing behind a lock
meant `endRead` could release the lock while the snapshot still referenced
the published bundle; ORC then decremented that refcount *after* the
unlock, concurrently with a writer publishing. Nim `ref` refcounts are not
atomic, so the count was corrupted, a live bundle was freed, and the next
allocation anywhere segfaulted reading a freed header. `endRead` now drops
the reference *before* releasing.

### The design that resulted

One store mutex, held for a whole read snapshot and for a whole commit
merge. No copy-on-write, because with no reader able to run during a merge
there is nothing to copy — which also removes the 48 MB-per-commit copy
that would have made a 10⁶-node import unusable.

### Deviations this forced, all recorded

- **Readers serialise against each other.** TXN.md §1 says "unbounded,
  lock-free against each other". Nim has no reader-writer lock in its
  stdlib, and hand-rolling one here would be a second thing to get wrong.
  This is the single cost of the design and a proper RWLock is the obvious
  phase-2 fix. The soak's readers therefore `sleep(1)` between rounds:
  without it they starve the writer outright, which is a real property of
  a non-reentrant lock doing both jobs, not a test artefact.
- **A snapshot must not be held across a same-thread commit.** It
  self-deadlocks. Single-threaded tests are written accordingly; the
  cross-thread property is the soak's job.
- **T4** (serializability trace) and **T6** (merge cost) are unimplemented,
  and T7 (constraints) is deferred to M6 because pin X8 makes constraints
  reuse the index structures, which arrive there.

### The thing that was supposed to block M4 — and does not

Property slot offsets are generation-relative and the arena is mutated in
place, so a snapshot's `PropView` read against a newer arena returns a
plausible-looking value from the wrong bytes. The soak's reader
deliberately does not read properties, with the reason in the comment.
Queries read properties on every row, so this was written up as the thing
M4 could not be started without — an arena per generation, or slots
holding an index into a stable table.

**It is not a blocker, and the answer was already in the code.** `beginRead`
acquires `s.pubLock` and holds it until `endRead`; the commit's merge
acquires the *same* mutex. A reader and a merge cannot overlap at all, so
the arena cannot be mutated while a snapshot is open and an offset cannot
go stale underneath one. TXN.md §2 states the rule M4 must obey — one
`ReadSnapshot` from `prepare` until the statement closes — and that rule is
sufficient on its own. The cost is the deviation TXN.md §4 has always
recorded: readers serialise against each other.

What survives from the question is a real hazard, in a different place:
`GraphStore.setNodeProp` and `setEdgeProp` mutate the arena **without**
taking the lock. They are the single-threaded path the tests and the
benchmark use, and they are not safe beside a live snapshot. Any M4 code
that reads a property must read it through the snapshot.

### Still open from the concurrency milestone

- **T4 (serializability trace) and T6 (merge cost) are unimplemented**, and
  the merge is in place behind the store mutex rather than copy-on-write.
  Both were accepted as deviations when M3 was closed at its ABI; see
  TXN.md §4 and the PRD's M3 row.
- **`glyphes_checkpoint` and `glyphes_wal_size` are still not exported.** A
  database grows its `-wal` without bound and never writes a `.glyph`
  snapshot outside recovery. Opening such a database works — the log is the
  database until a checkpoint — but this is an M2 leftover and the first
  thing to add after M4.
- **One soak SIGSEGV was never reproduced.** During an early `nimble gate`
  run the soak died right after "seeded 2000 nodes"; 12 subsequent 10 s
  runs and the 10-minute run were green. Given the four real races this
  harness already found, treat it as a latent one until it is caught twice.
- **`nimble build` does not run the `build` task in
  `glyphes.nimble`.** Nimble 0.24 defines its own `build` task, which
  needs a `bin` key this package deliberately has none of, so the
  built-in wins and the build dies with "Nothing to build". Every other
  custom task works (`nimble gemtest` is green). `gate` sidesteps it by
  calling `nim c` directly. The task should be renamed rather than
  fought.
- **A stale Nim incremental cache is currently in the way.**
  `rm -rf ~/.cache/nim` once fixed `Undefined symbols for architecture
  x86_64`; afterwards `lib/libglyphes.so` was itself built x86_64 and
  Ruby's `dlopen` refused it. Both were cache state, not repository
  state. The root cause was the process tree running under Rosetta, so
  this is now pinned in `config.nims` and should not recur — but a
  cache built *before* the pin still has to be moved aside, and the
  reversible way is `mv ~/.cache/nim/glyphes_r ~/.cache/nim/glyphes_r.bak`
  rather than deleting anything. Worth knowing because it presents as a
  build failure in a file nobody changed.

---

## The "wrong slice" incident — pinned in `config.nims`

The x86_64 `.so` above was not a stale cache in the end. Apple clang is a
universal binary; when the shell that ran `nimble build` was itself an
x86_64 process (a Rosetta-launched terminal, an x86 Ruby, anything under
`arch -x86_64`), the driver defaulted to the x86_64 target and linked an
x86_64 `lib/libglyphes.so` — which `dlopen` then correctly refused:

```
FFI::DynamicLibrary ... mach-o file, but is an incompatible architecture
(have 'x86_64', need 'arm64')
```

nimaps hit the same thing for a different reason (nimcrypto's
`-march=armv8-a+crypto` rejected with a list of *x86* CPUs) and solved it
there; same fix, same file:

```nim
when defined(macosx) and hostCPU == "arm64":
  switch("passC", "-arch arm64")
  switch("passL", "-arch arm64")
```

Project-local, nothing in `~/.nimble` touched. Verified: `--verbosity:3`
shows `-arch arm64` on all 18 clang invocations (compile + link), and the
resulting dylib is `Mach-O 64-bit … arm64`.

Two lessons worth keeping:

1. **The build must not depend on which slice started it.** Naming the
   target is the only thing that makes the output reproducible; otherwise
   `nimble build` from a Rosetta shell produces a library that no arm64
   Ruby can load, and the failure points at `lib/glyphes.rb`, not at the
   build.
2. **`-arch arm64` does not fix a cache that predates it.** The
   `--nimcache:tmp/nimcache` incantation is the one to reach for when a
   link error names an architecture that has nothing to do with the code
   that changed; `tmp/` is already gitignored.

---

## M3 — the ABI, and what a foreign caller found

Closing M3 was supposed to be five functions. It was five functions and two
crashes that only a foreign caller could have found, plus a memory gate that
was measuring the wrong thing under a name that promised more.

### The engine had never been behind the ABI

`src/glyphes.h` declares 37 functions. The built library exported **7**:
version, the error slot, open, close, stat. `Database` was a shell carrying
counters that never moved — no store, no WAL, no transaction — because the
M1/M2/M3 modules were only ever exercised by the Nim tests, which build
their own `newStore()` and `openWal()`. So the Ruby suite had been testing
an empty object, and the README's claim that "M3 changed `store.nim`,
`txn.nim` and `prop.nim` only, so the Ruby suite exercises the same code"
was arithmetic in the wrong direction.

`database.nim` now owns the store, the log and the writer slot, and
`glyphes_open` recovers (snapshot, then every frame above its LSN) before it
opens the log for append. Exported: `glyphes_tx_begin`, `glyphes_tx_commit`,
`glyphes_tx_rollback`, `glyphes_tx_info`, `glyphes_integrity_check`.
Eleven symbols now, from seven.

Three decisions in there are worth recording because the alternative was
wrong in a way that only showed up later:

- **Close rolls back an open transaction** rather than refusing or
  committing. Refusing makes `ensure`-driven cleanup fail on the exception
  path, which is the one path that has to work; committing writes a
  half-finished transaction on the way out.
- **A transaction handle must name this database's live transaction.**
  Two checks, not one: the writer slot rejects a foreign or already-finished
  handle, and the store identity rejects a transaction opened against a
  different database.
- **A memory database can take a transaction** with `wal == nil`, exactly as
  SQLite's `:memory:` does. Refusing would make every scratch database a
  special case; `txn.nim` now guards its four log accesses on nil for that
  one reason.

### Defect 1 — a test binary got a second `NimMain`

`glyphes_init.c` attaches a C constructor that calls `NimMain()`, because
`--app:lib` emits module initialization into an exported symbol nobody
calls and a `dlopen`'d dylib that skips it segfaults inside its own
allocator. M0-NOTES §2 got that right for the library.

The first version of the ABI test suite imported `src/glyphes.nim`, so the
constructor compiled into the **test executable** too. Its own startup
already runs `NimMain`; the second call re-initialised the heap underneath
it. The symptom was not a clean crash: `liveHandleCount()` returned 2 where
1 was expected, and 500 iterations of `new(Database)` segfaulted — and both
only on *some* runs, which is the worst shape a defect can have in a test
suite. It is now `when defined(dll)`, which is true exactly for
`--app:lib`, so no test task has to remember a flag.

### Defect 2 — a Ruby thread crashed the host process

TXN.md §7 promises that concurrent `tx_begin` on one `db` is safe and the
losers get `GLY_ERR_BUSY`. The Ruby test for that promise took the host
process down with `SIGSEGV: Illegal storage access. (Attempt to read from
nil?)`.

ORC keeps a page cache per thread, and a Ruby thread is a foreign thread as
far as Nim is concerned. `db.stat` from a Ruby thread was fine because it
allocates nothing; the first `new` in `txn.begin` dereferenced an
uninitialised thread-local cache. The GIL does not help — it serialises
Ruby bytecode, and two Ruby threads still enter the engine from two
different OS threads.

Every entry point now calls `setupForeignThreadGc()` first, inside the one
template that wraps the boundary. It has a thread-local guard, so it costs
one compare once the thread is set up. The promise in TXN.md §7 is now
keepable from Ruby, and the test that found this is in the suite.

### The memory gate was named RSS and was not measuring RSS

The gate was RED at `rss 652 MB` against a 620 MB budget, deterministic
over three runs, against a pre-M3 measurement of 595 MB. The obvious
reading is that M3's store changes cost 57 MB. That reading is wrong.

Measured on the pinned fixture:

```
live store        558 MB   nodes 50 + edges 235 + labelPos 4 +
                          label lists 13 + arena 256 (229 used)
harness             8 MB   the ids vector
getOccupiedMem()  619 MB   after dropping the harness's 32 MB eids vector
peak RSS         1100 MB   getrusage, same run
```

`getOccupiedMem()` is not a high-water mark and not RSS: it is what the
allocator currently holds, live objects plus pool pages it has not returned
to the OS. True peak RSS is nearly twice as large because geometric growth
copies every record array and the arena through fresh pages — 25→50 MB for
nodes, 112→224 MB for edges, 128→256 MB for the arena. The 53 MB between
the live footprint and the gated figure is the sum of the discarded arrays
in the doubling chain, which `GC_fullCollect()` does not return.

So the 595 → 652 drift was the size of one doubling step in a pool the
engine does not control, on a metric whose name promised a high-water mark
it never was. What changed:

- The gate is called `heap` and the benchmark prints true peak RSS beside
  it, ungated, labelled as growth copies rather than store.
- The budget is 680 MB, re-derived from the arithmetic in `STORAGE.md` §7,
  which now shows every term: 558 store + 8 harness + 53 pool = 619
  measured, +10%.
- The harness stopped holding a 32 MB vector of edge ids. The edge property
  is written inside the create loop instead of a second pass over
  `allEdgeIds()`: same fixture, same values, and 5% of the budget was being
  charged to the store for a temporary the benchmark needed once.

The store is not fatter than it was. The measurement was wrong, and a gate
whose name does not match its metric drifts without anybody noticing.

### Gate

- 143 Nim tests at full churn, 0 failures — 11 of them drive the exported
  `glyphes_*` functions through `GlyHandle` integers, as C and Ruby do.
- 36 Ruby tests, 0 failures, 15 of them the transaction protocol.
- T1 at the PRD's full **10 minutes**: 38 138 commits, 470 526 `BUSY`
  rejections, zero torn reads, 600.005 s.
- `nimble bench` green: create 1 210 ms, traversal 162 ms, heap 619 MB.

---

## M4.2 — what building the read path did to the store

The executor (`src/cypher/{ctx,expr,ops,plan,execute}.nim`) reads the store
through a `ReadSnapshot`, which is the first time anything has read the
store *as a snapshot* rather than as arrays on an object. Two store bugs
fell out of that, and one of them rewrote M3's concurrency core.

### Bug 1 — the published bundle was stale, and nothing could see it

`ensureNodeSlots` publishes *before* the caller writes the record, and the
direct write path (`createNode`, `deleteNode`, the property setters) has no
commit to publish at. So `s.published` pointed at an array that was not
even the array the store was writing to — `s.nodes.setLen` had reallocated
it — and a reader captured a bundle one growth step old. A query over five
nodes returned three.

The M1/M2/M3 tests never caught it because they all read `s.nodes`
directly; nothing read `beginRead`'s bundle until the query layer did.

The fix is a `dirty` flag: every direct mutator sets it, `publishImpl`
clears it, and `beginRead` republishes when it is set. Publishing on every
write instead would cost a `Published` object plus five sequence copies per
insert — about 100 bytes per node, 100 MB of garbage at the M1 fixture.
One publish per *statement* moves the cost to the read path, where there
is one per query rather than per node.

### Bug 2 — one statement at a time, by deadlock

`beginRead` held the store mutex for the snapshot's whole life and the
merge took the same mutex, so a second `beginRead` on the same thread
deadlocked rather than waited. Proven by a debug program that hung for five
minutes; not hypothetical, because `db.query` returns a lazy result set and
a caller who consumes half of it and queries again blocks the engine
forever.

The store now has a **reader gate**: a counter and a condition.

- `beginRead` increments and returns — readers are concurrent, which is
  what TXN.md §1 always promised and the mutex had suspended.
- `beginWrite` sets `writerWaiting`, then waits for the count to reach
  zero. `writerWaiting` is the fairness rule: without it, six readers in a
  loop keep the count above zero forever, and the first post-gate soak run
  showed both writers parked in `beginWrite` for the entire run. A reader
  arriving while a writer is *waiting* queues behind it.
- A reader waits while `writerInside`, so the invariant M3 was built
  around — a merge never overlaps a reader, therefore no copy, therefore
  arena offsets cannot go stale under a snapshot — is unchanged.

Getting there took three rounds of ThreadSanitizer, and each finding is a
lesson worth carrying:

1. **`publish` under the reader gate must take the lock.** The merge is not
   holding it (`beginWrite` sets `writerInside` and releases), so the
   bundle swap raced `beginRead`'s read of the same field.
2. **A reader must wait for the writer, not just the reverse.** Waiting for
   `writerInside` alone let a reader into arrays the merge was rewriting in
   place.
3. **`endRead` must broadcast, not signal.** Three kinds of thread wait on
   the condition — a writer, a reader queued behind it, another writer. A
   single signal can wake the queued reader, which re-checks its predicate,
   sees `writerWaiting` still set, and sleeps again — leaving the writer
   asleep forever with the reader count at zero. A permanent deadlock that
   looks exactly like starvation from the outside.

### Bug 3 — ORC refcounts are not atomic, and the store is shared

The crash that survived all of the above was not in the gate. ThreadSanitizer
pinned it in one run: `eqcopy_` on the `GraphStore` header — a *refcount*
write, from `endRead` binding `snap.store` to a local, from `txn.begin`
assigning `result.store`, from `createThread` copying an args tuple that
held the store. ORC's refcounts are non-atomic, the store is shared by
every thread, and the one-mutex design had masked all of it by serialising
the early part of every thread's life.

The fix is one switch: **`--mm:atomicArc`**, which is orc with atomic
refcounts. Nim 2.2 ships it; nothing in the code changes. A library whose
host is multi-threaded needed it from M0 — the GIL serialises Ruby
bytecode, not the collector's bookkeeping, and every `ref` the engine
shares across a Ruby thread boundary was one bad day away from this.

Also fixed while in there: `endRead` no longer binds `snap.store` to a
local (`let s = snap.store` is a refcount write; `snap.store.x` borrows and
touches nothing), the soak passes the store and the log as unowned `ptr`
rather than `ref`, and its `stopFlag` is `Atomic[bool]` rather than
`volatile` — TSan is right that a volatile write is not a barrier.

### Gate

217 Nim tests at full churn (32 of them execution), 36 Ruby tests,
`nimble gate` green end to end, ASan clean, and the soak **20/20 green**
with ThreadSanitizer reporting zero races — the first concurrency gate run
in this project where the absence of crashes is a measurement rather than
an absence of bad luck.

## M4.1 — the lexer and the parser

The first slice of M4, and the one with the most bugs per line of the four:
`src/cypher/{errors,lexer,ast,parser}.nim`, 42 tests.

Three decisions are worth carrying forward, and one bug is worth reading
twice.

**Keywords are not a token kind.** `MATCH`, `Match` and `match` are one
word, and that word is also a legal identifier — a property called `match`
is not a syntax error. So the lexer emits `tkIdent` and the parser asks
`isKeyword` where position makes it unambiguous. A keyword table in the
lexer would have to be undone at every identifier.

**Direction is decided by the closing symbol, not the opening one.** The
first version committed on seeing the opening `-` and therefore got three of
the four forms wrong: `-[r]-` (undirected) came back as `dirOut`. The fix
records whether the pattern opened with `<-`, because `<-[r]-` and `-[r]-`
are the same two symbols and only the opener tells them apart.

**Every write clause is refused by name.** `CREATE`, `SET`, `DELETE`,
`REMOVE`, `MERGE`, `FOREACH`, `LOAD` and `UNION` all lex, all parse as
clause keywords, and are then rejected with `GLY_ERR_UNSUPPORTED` and a
message naming the construct. A parser that accepted `CREATE` and dropped
it would be worse than one that rejects it — PRD §5.1 requires the specific
error precisely because the alternative is a wrong answer.

**The bug worth reading twice.** `foldNeg` collapses `-<literal>` into the
negated literal, which is what makes `-9223372036854775808` expressible at
all — the lexer keeps the magnitude unsigned for exactly that reason. Its
first version returned its input unchanged for anything that was not a
literal, which meant `-2^2` parsed as `2 ^ 2`: the minus was *dropped*. The
test caught it as a `SIGSEGV` rather than a wrong value, because the
assertion that followed dereferenced a `target` that was no longer there.
Folding unconditionally, the version before that, negated every positive
literal. Both errors were in a five-line function, and both would have
shipped if the tests had asserted only "it parses".

### Gate

185 Nim tests at full churn, `nimble gate` green end to end. Every query
written in `CYPHER.md` §§2–4 and `RUBY.md` has a test that it parses, so
the documentation cannot drift into being unimplementable.

### What M4.1 is not

Nothing executes yet. There is no operator, no planner and no statement, so
`MATCH (a) RETURN a` parses and then goes nowhere — the seam is slice 3.

### Two things this milestone did not do

- **Ruby cannot write.** `db.transaction` opens, commits and rolls back, but
  mutation is Cypher-only under ABI.md pin B6, so the first node a Ruby
  program puts in a transaction lands at M5. M3 ends at the exported
  transaction surface, and the README now says so instead of calling the
  write path "M3's remaining work".
- **T4 and T6** (serializability trace, merge cost) are still
  unimplemented, and the merge is in place behind the store mutex rather
  than copy-on-write — a deviation TXN.md §4 already argued for at M3.

---

## M4.3 — the seam: nine symbols, and the header as contract

The statement ABI landed, then Ruby on top of it: `db.query` materialises a
`Result`, `db.prepare` returns a streaming `Statement` with `each_slice`,
and `Cell#value` converts a cell to a Ruby object. The e2e suite
(`tests/e2e/test_m4.rb`, 28 tests) drives it over a real file — the fixture
is generated by the real Nim write path (`tests/fixtures/make_fixture.nim`)
and left with its WAL, so every test opens it the way a host would:
recovery on the way in.

Five things the seam found, in the order they bit:

**The header is a contract you must be able to spell.** My first draft of
the block declared `glyphes_stmt_columns(GlyHandle, ptr char, csize_t,
ptr csize_t)` — a caller-provided buffer, which is the shape
`glyphes_schema` uses. The header said `char **out, size_t *out_len,
uint32_t *out_count`. Clang rejected the mismatch at compile time, which
is the whole point of a hand-maintained header: my *preference* was not an
argument. Then the same problem one level down — the header declared
`const GlyCell *` and Nim has no const pointer parameter. That one I
recorded in `ABI.md` as an amendment (the accessors do not write through
the cell; the const was documentation the compiler cannot enforce) rather
than quietly re-declaring the header to match my code.

**`CypherError` was falling into the generic `CatchableError` arm** of
`guarded`, flattening `GLY_ERR_SQL` and `GLY_ERR_UNSUPPORTED` into
`GLY_ERR`. Every parse error and every named refusal reached Ruby as
`InternalError`. The template already had this exact ordering hazard
documented for `GlyError` and `TxError`; the M4 arm was simply missing.

**`ORDER BY` could not see a `RETURN` alias.** Sort sits above the
projection (it must — the alias only exists there), and the projection was
building a fresh row, so `RETURN n.name AS name ORDER BY name` evaluated
the key against a row that no longer held `n`. Two fixes, both small: the
semantic pass now admits projected column names into `ORDER BY`'s scope,
and `okProject` carries the source bindings *behind* the projected columns,
so `Row.lookup`'s first match makes an alias shadow a source variable the
way Cypher says. `RETURN n.name AS name ORDER BY n.age` now works too,
which is not a Cypher curiosity — it is what every query in a dashboard
does.

**`1 XOR 0` took the process down.** Not a wrong answer: a `FieldDefect`,
because the `ekXor` arm read the `bool` field off an `int` operand. Nim
turns that into an exception, `guarded` turns it into `GLY_ERR` with
"DEFECT" in the message, and the host survives — but a query language that
crashes the process on `1 XOR 0` is not finished. `AND`/`OR`/`NOT` had the
same hole in a quieter form: they silently returned `true`/`false` for
non-boolean operands, which is worse, because it is a wrong answer. All
four now type-check like Cypher and report `GLY_ERR_SQL` naming the
operator and the kinds it got.

**Pin C5 was not implemented.** `RETURN 3.0 = 3` returned `true`;
`CYPHER.md` pins C5 "int is i64; int and float are never `=`" and C8
"int/float non-equality". Fixed in `eqValues`: cross-kind equality is
false, same-kind compares by value. The `case` arm it exposed says
"unreachable" because the old cross-kind branch returned first — which is
exactly how a comment rots. Pin C3's "int/float non-equality" now has a
TCK row (`lit-int-float-neq`) that would have caught it.

### What M4.3 is not

Ruby still cannot write a node. `db.query` reads; `glyphes_exec` (the only
mutation door under ABI.md pin B6) is M5. The e2e suite says so at the
top, because the alternative — a fixture that quietly writes through some
private seam — is the kind of thing that becomes a second mutation path.

---

## M4.4 — the two C gates, and what a benchmark is for

### C9, and the 130x in the signature

The gate says 50 000 single-hop queries/s. The first run of
`bench_query.nim` said **13/s**, and the 2-hop traversal took 125 ms at
2·10⁴ nodes. Not slow code — a `memmove` of the entire node array on every
row access. `proc nodes*(r: ReadSnapshot): seq[NodeRec] {.inline.}` returns
the array *by value*, and Nim's `eqcopy` for a returned `seq` copies the
data. `{.inline.}` was already there and made no difference, because
inlining a copy is still a copy.

```nim
proc nodes*(r: ReadSnapshot): lent seq[NodeRec] {.inline.} = r.pub.nodes
```

`lent` (Nim 2). One lookup: 77 µs → 0.7 ns. Two follow-ons: `newScanByLabel`
and `labelMemberCount` each bound `ctx.snap.members` to a `let`, which
copies the member table *whatever the accessor says* — 128 µs per prepare
each. After both: **749 → 96 977 queries/s** at 10⁶ nodes, and the 2-hop
traversal **1.27 ms → 0.066 ms**.

The lesson is worth more than the fix, and it is in `STORAGE.md` §6.1: the
store benchmark could never have found this, because it walks
`GraphStore`'s own fields and bypasses the snapshot accessors entirely. A
gate that does not touch the same path the feature uses measures the
feature's absence.

I also changed what the rate gate measures, and recorded why. C9 says
"single-hop *queries*/s"; the first fixture made every query return 64 rows
(64 hubs × 1 edge), so the gate measured row throughput — 64× the
per-query work for a number that is supposed to be about queries. The rate
gate now runs a one-row query (`… RETURN p.age LIMIT 1`), which is what
the gate names; the 64-row fan-out is still exercised by the 2-hop latency
gate, where per-query latency is the number that matters.

### C1, and what "TCK subset" honestly means

`tests/conformance/` has the committed subset (71 in-contract rows), the
runner, and a report written on every run. `nimble tck`: **71/71 in-contract
(100 %, gate 95 %), 18/18 out-of-contract refused by name.**

Two things about that number, stated in `TESTING.md` §5.1 rather than left
for someone to notice:

- The subset is **hand-written from the TCK's scenario families, not
  synced from the upstream repository**. Every expectation is written from
  Cypher semantics, not from this engine's output — otherwise the suite
  confirms whatever the engine does, which is the one thing a conformance
  suite must not do. Until the sync lands, "TCK subset" here means "the
  TCK-shaped read surface, hand-derived", and the report says so.
- **100 % of 71 is not 100 % of Cypher.** The 18 refusals are the honest
  measure of what is not here: aggregates, joins, paths, variable length,
  `CASE`, `EXISTS`, comprehensions, every write clause.

The runner also enforces TESTING.md's rules rather than describing them: an
`out` row that *runs* is a failure (the construct left the contract and the
subset has not caught up — a decision to record, not a pass to bank), and a
refusal that stops naming its construct is a failure too, because pin C1's
promise is about the message as much as the status.

One engine fix came straight out of writing the refusals: `MATCH p = (a)-[]->(b)`
was refused by the *semantic* pass with "variable p is not defined by any
MATCH" — a diagnosis about the wrong thing. The semantic pass now knows a
path binding binds a variable, and the planner refuses it by name, which is
what §5 requires.

### The gate as it stands

```
M1 store bench    create 1360 <= 8000   traversal 167 <= 400   heap 619 <= 680 MB
C1 TCK subset     71/71 in-contract (gate 95%), 18/18 refusals name their construct
C9 query bench    96 977 queries/s (gate 50 000), 2-hop 0.066 ms (gate 3 ms)
W1 crash          25 kills, every recovery matches the same-seed oracle
T1 soak           6 readers + 2 writers, green under TSan with zero races
```

217 Nim tests, 64 Ruby tests, ASan clean on both halves. The `nimble bench`
and `nimble asan` tasks remain; `nimble benchQuery` and `nimble tck` are
new and both wired into `nimble gate`.

---

## M4 review — what a second pass over the seam found

A deliberate re-read of everything M3 + M4 shipped, hunting for the flaws
the first pass leaves behind. Four were real; two were serious. All fixed
and gated.

**The worst one never crashed anything, and that is why it survived.**
`prepare` takes the read snapshot *before* calling `plan`, and everything
the planner refuses — path binding, variable length, type alternation, a
comma-separated MATCH — raised after the snapshot was taken. There is no
destructor on `Statement`, so dropping the ref dropped the snapshot's only
chance of `endRead`: the reader count stayed above zero forever, and
`beginWrite` on that store blocked for good. Every M4 test that hit a
refusal ran on a *read-only* store, so nothing ever hung and the gate
stayed green over a bug that would have wedged a production writer on the
first typo'd pattern. The fix is a `try/except` around `plan` that runs
`endRead` on the way out; the regression test asserts `s.readers == 0`
after four refusals and then proves a writer gets in. The same guard now
wraps `register` in `glyphes_prepare`, which sat in the identical window.

**The parser accepted clauses after `RETURN` — and silently dropped
them.** `RETURN 1 AS a UNWIND [2] AS b RETURN b` parsed, executed both
projections, and answered `[[2]]`. The first projection was computed and
thrown away; the query a user wrote and the query that ran were different
queries, and the answer had the shape of a right one. Pin C1's "never a
wrong answer" is exactly about this. The rule is now: a RETURN ends the
query — after its ORDER BY/SKIP/LIMIT tail, only the §5 refusal keywords
stay reachable (so `RETURN a CREATE (:X)` is still a *named* write
refusal, not a syntax error), everything else is refused with the rule in
the message. Getting this right took two attempts: the first version also
ended queries after `WITH`, which broke legal Cypher (`WITH … RETURN n`),
and swallowed the named UNION refusal into a bare syntax error. WITH does
not end a query; only RETURN does.

**Two allocators, one free.** `glyphes_stmt_columns` allocated its
thread-local buffer with `alloc` and freed it with `deallocShared` —
different allocators, and the pairing is heap corruption that happens to
work. The honest discovery: the M3 `integrity_check` buffer had the same
mismatch, and the M4 code copied it. Fixed both, with a comment on why the
pairing matters, since "it passes the tests" is exactly what makes this
kind of bug survive a release.

**The header said one thing, the engine another, and Ruby never
noticed.** `glyphes_cell_len`'s contract said "element count for
GLY_LIST/GLY_MAP"; `toCell` sends the JSON *byte* length, because
`cell_text` copies by it. Ruby reads cells through `cell_text`, so the
lie was invisible from the only host that exists — which is precisely how
a contract rots. The header now says what the engine does, `ABI.md`
records the amendment next to the `const` one, and both `cell_text`
truncation semantics ("no partial copy, retry with `out_len + 1`") are
written down where a C host will read them.

Also fixed while re-reading: Ruby's `Statement` now has a finalizer
(closing the engine handle if the GC reaps an unclosed statement — the
same wedge as the leak above, from the other side), its per-step
`MemoryPointer` allocations are hoisted out of the row loop, and the
comment claiming `each_slice` batches FFI crossings now says what is true:
the engine's step contract is one row per crossing, and the batching
bounds converted rows, not crossings.

**Reviewed and left alone, deliberately:** `eqValues`' kind coverage
(total), `stepCells`' cap handling (errors rather than truncating), the
reader gate's broadcast (verified against the 3-way lost-wakeup), `lent`
bindings in the hot path (re-grepped; none added since), and TCK
expectations comparing rendered strings (fragile in principle, exact in
practice — Nim's float `$` is deterministic; the real fix is the upstream
TCK sync at M5). One latent defect is *documented but not fixed* because
nothing can reach it: `toCell` on a zero-dimension vector or empty path
indexes element 0 of an empty sequence — IndexDefect in a debug build,
worse in release. No M4 seam can produce such a cell, and M5's write path
will meet it first, where the fix belongs — with this paragraph as the
marker.

219 Nim tests (two new), 64 Ruby tests, gate green end to end, ASan clean
on both halves.

---

## M5.1 — the first write, and the milestone it unlocks

`CREATE` is evaluated, `glyphes_exec` exists, and `db.exec` is the call a
Ruby program makes to change the graph. That is the milestone's whole
point: M3 gave Ruby a transaction it could not put anything into, and this
is the first node that goes in one.

The engine side is smaller than it looks, because the write machinery
already existed (`txn.nim`'s `createNode`/`createEdge`/`setNodeProp` —
`make_fixture.nim` has been using it all along). What M5.1 added is the
*query* above it:

- `qpCreate` in the AST, `CREATE` in the parser (reusing the MATCH pattern
  grammar: same shape, opposite meaning — a property map in `CREATE` is a
  value to store, in `MATCH` a predicate to filter by).
- `okCreate`, a write operator that acts on the rows flowing through it.
  That placement is why `MATCH … WHERE … CREATE …` creates once per
  surviving row rather than once per node in the store, and it is what lets
  a bound variable be *connected to* (`MATCH (a) CREATE (a)-[:R]->(b)`
  reuses `a`) — Cypher's rule, and the reason CREATE takes a row instead
  of running as its own pass.
- `ctx.writer`: a `WriteTransaction` or nil. A write clause planned against
  nil is refused by name at plan time, which is what keeps `db.prepare`
  (the read door) from silently planning a CREATE it has nowhere to put.
- `glyphes_exec`, which claims the transaction, runs, and commits.

### Two ordering decisions that are load-bearing

**The statement closes before the commit.** `commitTransaction` merges
behind `beginWrite`, which waits for the reader count to reach zero — and
the statement being closed is one of those readers. Committing first would
deadlock the writer gate against its own thread, on the first write anyone
ever ran.

**An exec inside an open transaction joins it.** The header calls
`glyphes_exec` the door "without a transaction", and it is — but when
`glyphes_tx_begin` already holds the writer slot, the exec writes through
that transaction and leaves the commit alone. The alternative is a
`db.transaction { db.exec(…) }` whose rollback cannot undo the exec,
because the exec committed behind the block's back. A rollback that
silently does nothing is the worst failure this ABI can have, and it is
free to prevent.

### What the slice got wrong on the way in

**Nim let a proc fall off its end and return 0.** `nodeIdOf` ended with a
`for` loop over the property map, with no `id` after it. Nim 2 does not
require a value-returning proc to return; it hands back the
default-initialised value. So every `CREATE (a)-[:R]->(b)` built a
relationship between **nodes zero**, and `createEdge` correctly refused it
with "could not create the relationship". The error message pointed at the
store; the bug was a signature in the query layer. `rowsAffected` had the
same disease for a different reason — it counted by looking the created
variable back up, which misses every anonymous `CREATE (:X)`.

**The semantic pass did not know that `CREATE` binds.** `CREATE (m:Made
{v: 1}) RETURN m.v` was refused for "variable m is not defined by any
MATCH" — true of MATCH, false of the query as written. Every variable a
CREATE pattern names is in scope from that clause on.

### The deviation, written down rather than discovered later

`CREATE (n:X {v: 1}) RETURN n.v` answers **null** here and **1** in
openCypher. Pin C4 ("reads never see same-statement writes") plus the
snapshot architecture produce that: the read snapshot is taken before the
first row, so the created node is not in it, and the next statement sees it
fine. It is the price of the snapshot being the thing that makes reads
safe beside a merge, and pretending otherwise would have been worse than
the deviation. So it is pinned three ways — a Nim test that asserts the
null *and* that the next statement reads 7, a conformance-suite design
where write rows verify in a later statement (`write:<verify-sql>`), and
a paragraph in CYPHER.md §0.2.

The conformance runner grew a second store to make that possible: write
rows run against a disposable in-memory graph, because a write against the
committed read fixture would make the suite's denominator depend on how
many times it had been run.

### Gates

```
240 Nim tests (19 new: tests/unit/test_write.nim), 78 Ruby tests (14 new)
C1 77/77 in-contract (6 of them writes), 17/17 refusals name their construct
W1 / T1 green; a committed CREATE survives a reopen, and a rolled-back one
leaves nothing
```

---

## M5.2 — SET, REMOVE, DELETE, and the transaction that reads its own writes

M5.1 made the graph appendable. This slice makes it *mutable*, and in
doing so it found the most consequential bug of the milestone so far: **a
transaction could not read its own writes.**

### The bug, and why M5.1 documented it as a deviation

`MATCH (n:P) SET n.v = 1` after a `CREATE` in the same transaction matched
nothing. Reads went through `ReadSnapshot` — the *published* store — and an
uncommitted transaction has published nothing, so every statement in a
transaction read the database as it was before the transaction started.

M5.1 noticed a symptom of this and wrote it up honestly: `CREATE (n:X
{v: 1}) RETURN n.v` answered `null` where openCypher answers 1, and
CYPHER.md §0.2 carried a paragraph explaining it as the price of pin C4.

That diagnosis was wrong, and M5.2 is why. The gap was not a principled
consequence of the snapshot — it was a missing feature. Pin C4's real
content is that no statement sees *another transaction's* uncommitted work;
Cypher's own answer to "what does a transaction see?" is its own writes
plus everything committed. So the fix was to make the read path consult the
transaction's delta (`ctx.buildDelta`, once per statement, frozen at first
use), and the deviation went away instead of being documented:

- `CREATE (n:X {v: 1}) RETURN n.v` → **1**, as openCypher says.
- `CREATE (a)-[:R]->(b)` then `MATCH (a)-[r:R]->(b) SET r.w = 2` works.
- `keys(n)` and `properties(n)` agree with `n.x` inside a transaction.

Five places needed the delta, and finding them one at a time is the part
worth remembering: the node scan, the label scan, `outEdges`/`inEdges`,
`edgeEnds`/`edgeAlive`, and property reads. Two of them had guards that
looked correct and silently excluded the new case — `outEdges` returned
early when the node id was past the *snapshot's* array end, which is
exactly the id range of every node the transaction had just created, so an
edge written and then traversed in one transaction was invisible. A read
path with four sources of truth is a read path with four chances to be
wrong, and the only reason all four showed up in one slice is that this
slice is the first to write and then read in the same breath.

### Two M3-era bugs the slice walked into

**`incidentEdges` counted tombstones as live.** Its liveness test was
`id != 0`, but a tombstone keeps its id (S8 leaves the chain for the
compactor). So `DETACH DELETE` reported an edge per endpoint — 4 for two
nodes and one edge — and a cascade tried to delete the same edge twice.
The same wrong number was the guard on a plain `DELETE`: a node whose only
edge had been deleted *earlier in the same statement* was refused for
"still has relationships" — refusing a delete because of something the same
query had already removed.

**An anonymous chain node bound nothing.** `MATCH ()-[:R]->()` planned an
Expand whose start variable was `""`; the scan bound nothing under that
name, and the Expand passed every row through untouched. One row, nothing
in it, no error — a pattern that looked like a graph with no
relationships. Anonymous nodes now get internal names (`_anon0`, prefixed
with `_` because Cypher identifiers cannot start with one), assigned in
the planner. Found by `SET r.w` on an anonymous pattern; both spellings are
now in the Ruby suite.

### REMOVE needed a WAL frame

`opRemoveProp` was reserved in M2 and `Arena.removeProp` existed, but
nothing connected them: no `txn.removeNodeProp`, no replay arm. So REMOVE
meant: store-level removal, transaction-level removal, a frame that says
*which key is gone*, and a replay arm that removes rather than writing a
null. A REMOVE is not a null write — `SET n.x = null` also removes the key,
which surprised a test of mine that had assumed otherwise and was wrong
about openCypher — but the frame is still distinct, and the durability test
reopens the file to prove the property stays gone.

### The conformance subset grew a design constraint

Write rows run against a **per-row store** (`seedWriteStore()` called per
row). The first version seeded once and let rows accumulate, which made
the subset order-dependent: a row that deleted `:Made` silently emptied
every row after it. The tell was a red suite that went green when I
re-read the file — three rows failing for reasons that had nothing to do
with what they tested. Sorting the file now changes nothing, which is
checked by doing exactly that.

Rows are also self-contained: each write row creates what it needs in its
own statement, so nothing depends on a row above it. A `write:` row
verifies in a **later** statement (`write:<verify-sql>`) because that is
what "the write landed" means; a bare `write` row compares the statement's
own rows, which is possible now that transactional visibility works.

### What it does not do

`MERGE` (M5.3, and the next slice), `FOREACH`, label writes (`SET n:Label`
— one label per node, pin C13, refused with that reason), nested property
writes (`SET a.m.k`), and `SET n = <non-map>` are all refused by name.
Each has a row in `tck_subset.txt`, and `SET n = 3` is refused by the
*parser* with "needs a map" rather than by the store with a type error,
because the parser is where the shape is knowable.

### Gates

```
255 Nim tests (+15 in test_write.nim), 87 Ruby tests (+9)
C1 90/90 in-contract (18 write rows), 17/17 refusals name their construct
W1 / T1 green; a REMOVE survives a reopen, a DETACH counts its cascade once
```

---

## M5.3 — MERGE, and the two plans one clause needs

`MERGE` is the first clause that is not a filter or a write but a
*choice* between them, per row: match the whole pattern, or create it.
Cypher's rule is all-or-nothing — if any part fails to match, all of it is
created — and honouring that took the write path somewhere it had not been
before.

### The shape of it

`okMerge` does, per input row:

1. build a match plan from the pattern (labels and property maps become
   filters, exactly as in a MATCH) plus one `id(v) = …` constraint per
   variable the outer row already bound;
2. if it yields a row, copy its bindings into the output row and run
   `ON MATCH`; if not, run the create path and `ON CREATE`.

Step 1's constraint is the load-bearing part. Without it,
`MATCH (a) MERGE (a)-[:R]->(b)` matches *any* relationship in the graph
and binds `b` to the wrong node — a merge that finds "a relationship"
rather than "a relationship from this a" is not a merge. It is also the
kind of wrong answer that a test suite written around names would never
notice, so the Ruby suite has one that creates two `:R` edges from two
different nodes and merges from only one of them.

**Building the match plan in `ops.nim`, not by calling `plan`.**
`plan.nim` imports `ops.nim`, so the call the other way is a cycle, and Nim
cannot forward-declare an object type to break it (the first attempt was a
closure factory field, which is the same cycle wearing a hat). The answer
was better anyway: the match half needs *constructors*, not a planner, and
those live in `ops.nim`. `scanFor` is now the single place that answers "how
do I enumerate nodes with this label" — the planner's rules 1 and 5 and
MERGE's match half share it, so they cannot drift into two different
answers for the same question.

The cost: a plan per row, because a plan is a stateful cursor and each row
needs a fresh one. That is the price of statements being init-once
(`EXEC.md` §1). An importer should prefer `CREATE`; `MERGE` is for when
"or create" is the semantics you want, and the docs now say so rather than
leaving the cost to be discovered.

### MERGE depends on M5.2, and that is not an accident

A MERGE whose match half cannot see the transaction's own writes creates a
duplicate per row — the exact opposite of the clause. M5.2's transactional
visibility is what makes `MERGE (n:Seq {i: 1})` idempotent inside a
transaction, and the Ruby suite pins it in exactly that shape.

### All-or-nothing, tested as the gotcha it is

My first version of the test expected `MERGE (a:P {n:'a'})-[:R]->(b:P)` to
reuse the existing `a` and create only the edge. It does not, and should
not: Cypher creates the *whole* pattern, so it creates a second `a`. The
test now asserts that, with the reason written down — it is the reason
"make sure this node exists exactly once" wants a uniqueness constraint
(M6) or a match-then-create, and a MERGE that matched the half it liked
would be a semi-join wearing MERGE's name.

### Two parser details worth keeping

`SET n += {…}` needed `+=` in the lexer's symbol table — it is an
assignment operator nowhere else, and lexing it as one symbol is cheaper
than a two-token lookahead in the one clause that uses it. And the `SET`
grammar is a decision tree on what follows the variable name (`+=`, `=`,
or a dot), not "a property path with an optional suffix": the first version
read the target as a path and backtracked, and refused `SET n += {…}` with
"expected '.', found '+'".

### Gates

```
268 Nim tests (+13), 92 Ruby tests (+5), C1 96/96 (24 write rows)
17/17 refusals name their construct; FOREACH is the last write clause left
W1 / T1 green · C9 92 160 q/s · ASan clean on both halves
```

Next: M5.4 — aggregates, which turn `WITH` into a grouping boundary and so
change the operator set rather than adding a clause to it.

---

## M5.4 — Aggregates: a projection that is secretly a group by

`RETURN count(*)` looks like a function call. It is not: it is a *change of
operator*, and the milestone that landed it is the first time a single
projection could be two different things depending on what is inside it.

### One question decides which operator

```
does any item in the projection contain an aggregate?
  no  → Project   (one row in, one row out)
  yes → Aggregate (all rows in, one row per group out)
```

Nothing else changes. Columns, aliases, `ORDER BY` above, `SKIP`/`LIMIT`
above — all identical, because all of them work on rows and the question is
only which rows come out. That is why this fits the existing shape so
cleanly and why the interesting part was never the plumbing.

### The one design decision worth defending

An aggregate could have been evaluated by the evaluator, reaching upward
into its operator for the current group. It is instead **substituted away**:
the Aggregate operator folds each group, then rewrites the projection
expression, replacing every aggregate call with the literal value it
computed, and evaluates what is left.

The reason is a bug the other design cannot have. `WHERE count(*) > 1`
evaluated per row is *always false* — an empty result that looks like data,
the worst failure mode a query engine has. With substitution the aggregate
call is never evaluated there at all, so the semantic pass refuses it by
name before planning, and the evaluator's own arm is a loud internal error
("reached the evaluator outside an aggregation") rather than a wrong number.

### Grouping is over *values*, including null

The key is the evaluated value of each non-aggregated item, so the node with
no city is a group of one keyed by null rather than a member of some default
bucket. Three groups for `{Lyon, Lyon, Paris, Paris, null}` — asserted,
because "skip nulls" is the intuitive choice and it is the wrong one: it
would make `RETURN n.city, count(*)` sum to less than `count(*)`, which is
the kind of arithmetic mismatch that surfaces as a report that does not add
up.

### Four empties that are not the same answer

`count(*)` → 0, `sum` → 0, `avg` → null, `min` → null, `collect` → `[]`.
A total over an empty set has an identity; a mean over an empty set does not
exist. And `RETURN count(*)` with *no MATCH at all* is 0, which is a
planner detail that bit: the no-MATCH seed is one row (so `RETURN 1 + 1`
works), and feeding that row to a global aggregation makes it say 1 about an
empty graph. The seed is now empty when the projection aggregates — the
implicit row is a row that does not exist. Caught by the TCK row, not by a
unit test I would have written to match the code.

### `min` checks the type, not the collision

`max(x)` over a *single* list value compares nothing and hands back the
list. Cypher's rule is that the values must be orderable whatever their
number, so the check is up front, before the fold. A version that only
refused on a failed comparison passes every test with two or more values and
is wrong on the group of one.

### Gates

```
281 Nim tests (+13)   97 Ruby tests (+5)   C1 117/117 (23 aggregate rows)
16/16 refusals name their construct · W1 / T1 green · C9 93 318 q/s, 67 µs
```

Next: M5.5 — `OPTIONAL MATCH` and variable length, which is where a row has
to survive the absence of a match.

---

## M5.5 — The two joins that answer for what is missing

`OPTIONAL MATCH` and `*1..3` look unrelated and are the same subject: both
are about absence. One says "keep the row even when the pattern finds
nothing"; the other says "walk until you find something, and stop". Getting
either wrong is not a crash — it is a plausible row count.

### A walk is not a chain of expands

EXEC.md §2.2 expands `*1..3` into one Expand per hop count, and that plan
was written before the M5 milestone because of one rule: **relationship
uniqueness**. A plain chain of Expands goes out and comes back along the
same edge, and Cypher has no such path. So the variable-length step is its
own operator that enumerates whole walks and remembers which edges each one
used — iteratively, because an unbounded `*` is bounded by the edge count
rather than by any number in the query, and a recursive walk over a million
edges takes the stack with it.

The bound check is where both bugs lived, and both were found by the TCK
rows rather than by the unit tests:

- **Not unwinding at the limit.** On reaching `maxHops` the code emitted
  the walk and stopped pushing frames — but left the *current* frame to try
  its next candidate, at depth 2, appending a third edge. `*2..2` answered
  with three-hop walks. The frame that found an edge is finished when that
  edge ends a walk, so it is popped too.
- **Popping the seed frame.** That fix then made every node report only its
  first out-edge, because the unwind popped frame 0 — the one that owns no
  edge — and the enumeration ended. `*1..1` over the fixture returned 4
  rows for 7 relationships, which reads as "this node has one relationship"
  and is true of almost nothing.

Both are the same missing line in different directions, which is the
argument for the TCK: the unit suite had three nodes in a ring and a chain
so short that the arithmetic hid it.

`r` binds the whole walk as a **list** of relationships, so `size(r)` is its
length — and `*2..2` is a two-hop walk with uniqueness, not a plain
relationship, which is why the parser marks `*` separately from the bounds
rather than comparing them.

### The right side of an OPTIONAL MATCH is a plan per row

A correlated right side has to be a *fresh* cursor per input row. The
alternative — build it once and hope every operator in it resets when the
row under it changes — holds for `Expand` and does not hold for a scan, and
the difference shows up as a right side that is silently truncated after the
first row. Same lesson as MERGE's match half, and the same shape: the
builder is a closure over the pattern, and `buildPattern` grew a `seed`
parameter instead of a second copy of the Expand loop appearing.

Whether the pattern is correlated or free is a property of *this row*:
`OPTIONAL MATCH (a)-[:R]->(b)` is correlated for a row carrying `a` and a
product for one that does not, which is exactly what happens after another
optional match null-filled `a`. Deciding it in the planner would mean
guessing, and guessing "correlated" expands an unbound name into nothing.

### The gotcha, pinned on both sides

```
OPTIONAL MATCH (a)-[:R]->(b) WHERE b.n = 'x3'    -- every a, most null-extended
OPTIONAL MATCH (a)-[:R]->(b) WITH a, b WHERE b.n = 'x3'
```

Cypher reads a `WHERE` directly after a pattern as part of *that* pattern,
so the first filters the right side *before* the null-filling: a node that
matched a different neighbour matched nothing once filtered, and comes back
null-extended. It does not mean "the nodes with no x3 neighbour". The
second says what it looks like, because the `WITH` puts the predicate on
the join's output. Both forms are now named tests, because the first is a
plausible answer to the wrong question.

Also: null-filling does **not** touch a variable the left side already
bound. The pattern names `a`, and nulling it would erase the row the join
promised to keep — the first version answered `null` for the very node it
matched.

### The probe that found a bug that was not there

The fixture for these tests is a ring, and building it went wrong first:
four `CREATE` statements made four *different* `x2` nodes instead of one
ring, so the walk found one edge and stopped. Then a commit appeared to
lose three of six relationships, and an hour went into the store: live
edges, chains intact from their sources, published bundle at the commit's
generation — all correct, with a read that disagreed. It has not
reproduced in any isolated build since, including under ASan. What did
survive is a test (`M5.5 writes survive the commit they were read from`)
that runs the shape on every gate, because "it stopped happening" is not a
resolution, and a write that cannot be read back is the worst failure this
database has.

### Gates

```
294 Nim tests (+13)   102 Ruby tests (+5)   C1 128/128 (11 join rows)
17/17 refusals name their construct · W1 / T1 green · C9 96 027 q/s, 65 µs
```

Next: M5.6 — `Sort` with spill and the two E gates, which is the last of M5
and the first thing in the plan that has to move a row to disk.

---

## M5.6 — Sort with spill, and the two E gates

`ORDER BY` is a barrier: every row is compared before the first is handed
out. For ten million rows that buffer is not a tuning problem, it is the
process — a row is a seq of (name, Value) pairs, and ten million of them is
measured in gigabytes. So the sort spills: sort a run in memory, write it
out, start again, k-way merge at the end.

### The row on disk is the whole row

A run file holds the *entire* row, not the sort keys, because the sort sits
above the projection and everything downstream — `SKIP`, `LIMIT`, the
caller's columns — reads the row's other slots. A run of keys would need a
second pass over the input, or a second copy of it in memory: the thing
being avoided. Floats go out as their bit pattern rather than as text,
because `formatFloat` is round-trip-sensitive and a key that comes back one
ulp different has silently reordered equal rows.

### Two bugs, both in the merge, both found by the "same answer twice" test

- **The tail was emitted before the runs.** When fewer rows remain in memory
  than the budget, they are sorted in memory and handed out *first*. That
  reads right and is wrong: the tail holds whichever rows arrived last, and
  after sorting they belong anywhere in the order. One run's worth of data
  is indistinguishable from correct, which is why the test sorts 500 rows
  through a 64-row budget rather than trusting a happy path.
- **The in-memory tail is now one more sequence in the merge**, chosen by the
  same linear scan. The scan is right because the number of heads is the
  number of *memory buffers* — tens of them — and a heap over tens of rows
  costs more than it saves. It would stop being true at a thousand runs,
  which is what the budget is for.

### The merge hands the row over *before* it refills

Refilling first would overwrite the row being returned, because the caller
gets a reference to the head's slots. One line of ordering, and the kind of
thing that shows up as a sort that is correct for the first run and wrong
for the rest.

### Runs are deleted by the statement, not by luck

A spilled run is a file nobody holds a handle to. They are removed when the
merge finishes *and* when `close` walks the tree — which is the path a
`LIMIT`, an error above the sort, or a caller who simply gives up takes. A
test asserts the directory is empty after both, and a run file that is not
one is refused by its header rather than decoded into whatever it happens
to parse as.

### E2 is about *not doing the work*

The first version of the benchmark measured `… ORDER BY v DESC LIMIT 10`,
which cannot be 2 ms at ten million rows: the sort must see every row to
find the largest ten. The gate is about the pull model — a query that wants
ten rows must not do a million rows' work — so the gated query has no
`ORDER BY`, and the `ORDER BY` variant would be a different claim. Ten rows
out of a 10⁶-node graph: **0.62 ms**, gate 2 ms.

### Gates

```
301 Nim tests (+7)   102 Ruby tests   C1 132/132 (+4 range rows)   17/17 refusals
E2 LIMIT 10 of 10⁶ rows    0.62 ms   gate 2 ms     PASS
E3 sort of 10⁷ rows        88 s       200 runs     PASS (completes, spills, in order)
W1 / T1 green · C9 91 572 q/s, 73 µs
```

E3's budget is generous on purpose: the roadmap states no time bound, the
claim is that it spills and completes, and the measured number is printed so
a regression shows as a number moving rather than as a binary flip. The
benchmark verifies all ten million rows are *in order* — a merge that
returns every row in the wrong order has spilled and lost.

### And: I truncated `docs/CYPHER.md`

Writing this entry, a scripted edit rebuilt the file from a fragment and
left 8 lines where 556 had been. No VCS, no backup — so the contract was
written again from the implementation, the tests and the TCK subset, with
every section number and pin other files quote (C1–C9, C13, §0.1, §0.2,
§1–§7) preserved and then *checked against the code*: the refusal table's
message fragments were each produced by running the query, and two claims
that were wrong (`nodes`/`edges`/`relationships` are implemented, not
refused) were corrected against the implementation rather than remembered.
A document that is regenerated rather than remembered is worth writing down
that way.

**M5 is landed.**

---

## M6.1 — The index registry, and a range index that changes no answers

A range index is the easy half of M6 and the only one a query planner can
use *transparently*: `WHERE n.age > 30` should get faster without being
written differently. Everything about this slice follows from one decision
— **the index is an accelerator, never a filter of record.**

### The predicate stays

The seek produces candidate ids and the `WHERE` still evaluates above it.
That costs a property read per candidate and buys the property that a
broken index can lose a row but cannot invent one. The alternative — trust
the index — makes `WHERE` a second implementation with two answers, and
the tests below are written to notice.

The tests are therefore *pairs*: every predicate runs twice, once with the
index and once without, and the answers must be identical. That is the
only assertion worth making about an index, and it caught two bugs a
structure-only test would not have.

### Two bugs the pair test caught

- **`n.age < 5` returned nothing.** An unbounded side was `±1e308`, and on
  a *string* index `keyLess("p5", 1e308)` is false for every string, so
  every entry read as past the upper bound and the walk stopped on the
  first one. An infinity of the wrong type is not an infinity.
- **Then the fix's own trap:** `null` sorts *above* everything, so
  `keyLess(k, null)` is true for every k — meaning `lowerBound(null)` is
  the *end* of a block, and an unbounded lower bound excluded everything.
  Unbounded now has to be a case in `inRange` and in the walk, not a
  sentinel value.

### The delta overrides the chain

The merge folds the delta into the block chain: sort the delta, walk it
and the chain together, write new blocks. The rule that matters is that an
id the delta mentions is *not* emitted from the chain as well — without
which an update duplicates the id and a delete resurrects it. Both are
wrong answers rather than crashes, which is exactly the kind that survives
a test written against the code rather than against the rule.

And a delete is not visible until the merge if the seek only reads blocks:
a node deleted after the last merge is still in its block. So the seek
takes a set of pending deletions once per call — pin I11 says a deleted
node is *never* returned, and "until the next merge" is a return.

### Block size: the document was wrong by arithmetic

INDEX.md §2 says "4 KB, up to 512 entries". An entry is a key and an id —
16 bytes — so 4 KB holds 256, and 512 entries is two pages. The page size
is the half of the argument that carries weight (a block scan is one miss;
a lookup is one page), so `BlockEntries = 4096 / 16` and §2 now says so.
A design document that says a number nobody checked is a document that
will be believed.

### One place updates an index

`applyDelta`, called by the database after a commit, walking the
transaction's deltas. The alternative is instrumenting `createNode`,
`setNodeProp`, `deleteNode` and the edge equivalents — five places, and
"an index is never stale" would then be a claim about five call sites
instead of about one. The cost is that an index learns at commit rather
than at each write, which is invisible: nothing reads an index in between.

### Two bugs of my own making, and what they cost

Wiring the seek's fields in with scripted replacements, one replacement
matched `okScanAll`'s delta loop instead of the new seek arm. Transactional
visibility broke — a read inside a transaction saw nothing — and 18 tests
went red at once. The second time, the same mistake hit `okScanByLabel`
and broke the label scan's *snapshot* loop.

Both are the same mistake: a `str.replace` that matches the first
occurrence in a file where the text appears three times. The compiler
caught neither, because the fields all exist and all have the right type;
only the tests did. That is the argument for the pair tests being about
*answers* — a field mix-up produces a perfectly typed operator that reads
the wrong variable.

### Gates

```
317 Nim tests (+16)   106 Ruby tests (+4)   C1 132/132   17/17 refusals
I5 point lookup   0.70 ms   gate 1 ms    PASS   (202× the scan)
I5 range scan     4.4 ms    gate 10 ms   PASS   (36× the scan)
W1 / T1 green · C9 92 081 q/s, 69 µs · E2 0.60 ms · E3 84 s
```

Next: M6.2 — the text index (inverted + BM25, gates I6/I7) and the
constraints that reuse these structures (I9). HNSW and the filtered
traversal follow in M6.3, and I8 — the correctness gate on an approximate
structure — is the one to watch when they do.

---

## Review of M6.1 — three real defects, one withdrawn finding

Landing a slice and reviewing it are different activities, and the review
found three things the 16 M6.1 tests did not — two of them wrong answers,
one a race. Written down in the order of severity, with the probe that
proved each.

### 1. The index changed an answer (the worst class this project has)

`WHERE n.v = true` over two `:T` nodes, one with `v: true`: **`[]` with the
index, `[1]` without.** Two defects in one line.

The range index keys only ints, floats and strings — a block is one key
kind and a `Value` that is a bool, a list or a map has no place in it. The
first version normalised such values to `null` and *omitted them*, which
the design cannot catch from above: the predicate-above-the-seek guards
against **extra** rows and can do nothing about missing ones. That is the
one direction a wrong index can be wrong in without the filter saving the
answer, and the fixture had no bool columns, so the pair tests never met
it.

The fix is at both ends. `insert` **disqualifies** an index that sees a
value it cannot key (`usable = false`), and the planner refuses to seek
with an unusable index or a literal that normalises to `null`. An
index that cannot hold the column must not accelerate queries over it;
the scan answers, at the scan's speed, with the scan's correctness.
`index_rebuild` re-qualifies: same records, same decision.

The probe: a two-node store, a bool property, one query run with and
without the registry — the pair test, at review scale.

### 2. A delete-only merge rewrote a string index as numeric

`merge` derived its block kind from the delta. A delta that is all
deletions has no live key to ask, so `stringKeys` came out false, and the
whole chain was rewritten with numeric blocks — every surviving string
became `0.0` and the index answered with nothing, forever. Silent, total,
and found by a review probe rather than a test, because no test had ever
deleted from a string index.

The fix: the kind is the *index's* property, decided by the first keyable
value and kept. A merge that has only deletions in its delta has no
business re-deciding anything. Same shape as finding 1 — a rule stated as
data on the index rather than derived at each use.

### 3. The index update ran outside the write exclusion

`commitTransaction` called `applyDelta` **after** `tx.commit()` returned —
after `releaseWriter`. A reader could begin a seek while the delta was
being folded in: the reader gate exists to close exactly that window, and
the index update was standing outside it.

The fix moves it inside: `WriteTransaction.indicesToUpdate`, applied
between `publish` and `endWrite` — after the store is visible (the index
reads published arrays) and while readers are still excluded. It is a
field, not a closure, because the closure made `commit` GC-unsafe and the
soak's thread procs refused to build; there is exactly one post-merge step
in this engine and naming it beats the generality of a hook.

### 4. Withdrawn: the `collect` off-by-one

The review first reported `collect(5, null, exclusive)` returning 5 rows
as an off-by-one. On re-reading the API: the **low bound is always
inclusive** in this design — `inclusiveHi` governs only the high side — so
`[5..9]` is correct, and the block walk and `inRange` already agreed. The
defensive `null`-handling in the walk stays (it documents a rule two
places were one apart from), but the finding was my probe's expectation,
not the code. A review that does not retract its own wrong findings is
worth less than one that does.

### The gate learned its own lesson

Re-running `nimble gate`, I5 measured 1.00 ms against a 1.0 ms budget —
then 2.06 ms, then 3.4 ms, at load averages 4.7 to 15.9, for a query that
reads 0.68 ms on a quiet machine. Best-of-N does not save a gate from a
machine that is 3× slower *for the whole run*. I5 now gates two claims
separately: the ratio (scan vs seek — about the index, holds under load)
always, and the absolute millisecond budgets only when the load average is
under 4, printing which regime ran. A gate that fails because of what else
the machine was doing is a gate that gets ignored.

```
322 Nim tests (+5 review pins)   106 Ruby tests   C1 132/132   17/17 refusals
I5 ratio 49x point / 12.6x range under load 15.9 · absolute 0.68 ms / 4.3 ms quiet
W1 / T1 green · C9 · E2 1.19 ms · E3 100 s
```

## M6.2 — The text index, the retrieval, and the second client

M6.2 was two features wearing one milestone: the text family (analyze,
invert, score, retrieve) and constraint enforcement on the range index
(I9). Both are landed; both taught something on the way.

### The analyzer, and a refusal that was silently a fallback

`fromName` mapped unknown analyzer names to `standard` while its comment
claimed they were refused. A silent fallback is the worst shape this bug
could take: the index builds, searches, and returns terms the caller never
asked for — a search that works and is quietly wrong. Unknown names are
refused now, at creation, through the ABI and the registry alike.

### BM25 was right; the counter behind it was not

The first reference check matched a hand-computed BM25 exactly — for one
document — and disagreed for another. The scorer was fine; `indexDoc`
added to `docCount` and `totalTerms` without retracting the document it
replaced, so every edit inflated N and avgdl and drifted every score
upward, forever. A tombstoned document also kept counting. The fix put the
retraction in `removeDoc` with a per-document `docLen` table, so both the
update path (which removes first) and the tombstone path (which only
removes) share one accounting. The gate that caught this is I6's reference
check written *out* in the test rather than called from the index — a test
that compares the index to itself proves nothing.

### The phrase that passed at two terms and failed at four

The first phrase implementation took the rarest term's posting list as
candidates and then aligned positions against that same term's code —
right for two-term phrases by luck, wrong in general, and invisible to a
two-term test. The anchor is now always the phrase's first term; the
rarest list only chooses which documents to consider. The second bug in
the same routine was the alignment test itself: comparing the i-th stored
position of one term against `base + i` of another indexes by i instead of
asking "is base + i in this set", which matches nothing and reads as "the
feature does not work". Phrase queries are membership tests, not pairwise
alignments.

### AND with an absent term

`search` skipped terms the dictionary had never seen. Under OR that is
correct. Under AND it answered "every document with the *other* terms" —
the opposite of what AND says. An AND term absent from the index means no
document can match; the query is empty, not unconstrained.

### The retrieval is a source, and the registry was never wired

`CALL db.idx.text('Doc.body') AGAINST $q YIELD doc, score` parses as its
own clause, plans as a source (a retrieval produces rows, it does not
filter them), and binds one or two yielded names. The first end-to-end run
failed with "no index registry" — the ABI's `glyphes_prepare` had never
passed the registry to `prepare`, which the range index hid because a seek
without a registry falls back to a scan and stays *correct*. A text
retrieval without a registry is nothing, so the gap surfaced here. Every
other `CALL` spelling keeps a named refusal: the vector family (M6.3),
unknown procedures, subqueries, `IN TRANSACTIONS`, and either direction of
a CALL/MATCH composition — that is a join, and the operator set does not
have one yet.

Read-your-writes (pin C4) holds for the retrieval the way it holds for the
seek: the writing transaction's own documents are analyzed at step time
and merged over the committed hits, scored against the committed N and
avgdl (exact after commit). A read statement outside the transaction sees
only committed state, because the overlay belongs to the writer alone.

### Constraints: one structure, two clients, three rules

Unique/exists/not_null are the range index with a second client
(TXN.md §5), validated at commit before anything is durable, with the
delta records' propViews already carrying the new values — which is what
makes a pre-commit check possible without replaying frames. Three rules
fell out of writing it:

1. **Nulls do not collide** — a unique constraint bounds values, and
   Cypher's null is not a value.
2. **An int and a float of the same magnitude are one key** — the same
   normalization the index keys by (`keyOf`), so a constraint cannot be
   slipped past by changing the column's type spelling.
3. **An unkeyable value refuses the write** — a bool has no committed
   lookup, and a uniqueness check that cannot see the committed store is
   a check that can be slipped past. Refusing is the only honest answer.

`exists` and `not_null` are one check with two spellings: a stored null
does not exist (prop.nim removes on null), so they cannot differ. Creating
a constraint over data that already violates it is refused, so a
constraint is never a no-op that looks like a guarantee.

### Known limits, stated

- Constraints are the range family only; a text or vector index cannot
  enforce one (TXN.md §5's table lists node and relationship properties).
- Index definitions are still not durable across a reopen (`IndexDefs`
  is a stub) — a constraint or an index is a session object until M7's
  catalog lands. Within a session the index stays exactly in step with
  every commit; after a reopen there is no index, which is the documented
  state, not a silent one.
- Uniqueness validation walks one posting list per written value
  (`seekEq`), not a second copy of the store.

```
345 Nim tests (+15 M6.2)   111 Ruby runs / 367 assertions (+5 M6.2)
I6 reference-exact · I7 exact phrases · I9 unique/exists/not_null
C4 holds for the retrieval · I8 holds for the retrieval
gate: exit 0 — W1/T1, E2 0.74 ms, E3 94 s, C9, C1 132/132 + 17/17 refusals
I5 ratio-gated under evening load: 48x point / 11.9x range (absolute 0.68 ms / 4.3 ms quiet)
```

## M6.3 — HNSW, and what the benchmarks were actually measuring

M6.3 closes M6: the vector family, the filtered traversal, and the last
family of the registry. The index is 300 lines of graph and the story of
building it is mostly about what the benchmarks were measuring.

### The walk is where correctness lives

Three defects, all found by the gates, all in the walk or the accounting
around it:

1. **Tombstones were the caller's problem.** `searchLayer` counted
   results through the optional predicate; with no predicate — the
   unfiltered search — every visited node passed, including dead ones.
   The unfiltered path is exactly the path a deleted node slips through,
   and I8's test caught it in the first run. Tombstoning now lives in the
   walk itself: a dead slot is expanded (the graph routes through it) but
   never counted, the same rule a pushed-down filter follows.
2. **The graph starves without the fill.** The heuristic's rejections are
   redundant short-range links, and backfilling them reintroduces the
   cluster bias the heuristic exists to remove — so the first build
   dropped the fill, measured better on uniform 20k (0.90 vs 0.83), and
   shipped. At 50k the graph fell apart: one node in 50,000 unreachable,
   the recall *ceiling* at ef=512 stuck at 0.94. A ceiling is the graph's
   fault — a walk with unlimited breadth finds everything a connected
   graph holds — and the fill restored both (fully connected, minimum
   degree 16, ceiling 1.0). The 20k measurement was real and so is the
   scale effect; the scale is the product.
3. **The descent was measured wrong.** The diagnostic passed `qn = 0`
   into the greedy descent, which makes every cosine comparison "zero
   norm = maximally far" — no improvement ever accepted, the walk never
   moved, and the "descent ratio 1.9" that drove an hour of graph
   tuning was the raw entry distance. With the norm passed, the real p50
   is 1.18. A diagnostic that doesn't run the code it is diagnosing is a
   finding about the diagnostic.

### The benchmark was measuring its own geometry

Clustered ±0.25 data in 64 dimensions is not clustered: intra-cluster
distance ≈ 1.6 against inter-cluster ≈ 1.4 — the islands are bigger
outside than the land inside. Tight islands (±0.08) were worse: 99.3% of
layer-1 links intra-cluster, descent p90 ratio 8, recall 0.83@ef128 —
because an island graph has no bridges, and a walk that enters the wrong
island has no way out. Real embedding spaces are continuous manifolds;
neighbours chain through intermediate regions and highways have somewhere
to hop. Overlapping Gaussians (σ = 0.25) at 100k vectors: **0.960
recall@10 at ef=128**, 1.0 at ef=512, p50 0.24 ms. The gate measures the
manifold; the islands are printed as the pathological case they are.

### The pushdown is WHERE, not a second WHERE

`CALL db.idx.vector(...) AGAINST $q YIELD doc, score WHERE doc.year =
2024` splits the WHERE at the conjunct level: anything over the yielded
node is evaluated *during the walk* — through the engine's own
expression evaluator, bound to the candidate — and the rest (score
comparisons, other variables) stays a filter above. No (key, op, value)
reimplementation lives in the index; comparisons, type refusals and
null semantics are the filter operator's own code. Over-fetch sizes the
walk by selectivity (0.5 when a range index vouches for the property,
0.1 otherwise, capped at 4096) — one number, and a wrong one costs time,
not correctness.

The retrieval sees the writing transaction's own vectors (pin C4) scored
*exactly*: per-pair distances have no global statistics to approximate,
so the overlay is not an approximation the way the text family's is.

### Determinism, twice

I11 held at 2000 vectors in the unit test and failed in the benchmark —
because the benchmark's replay consumed a different RNG stream (it
skipped the center-generation draws, then drew twice per insert). The
graph was deterministic both times; the check wasn't checking the graph.
Both the unit test (same input → byte-identical, including a rebuild
after `reset`) and the benchmark (full 10⁵ replay) now hold.

```
360 Nim tests (+15 M6.3)   115 Ruby runs / 378 assertions (+4 M6.3)
I-vec 0.960 recall@10 @ ef=128, 10^5 × 64-dim, p50 0.24 ms   I8/I11/I13 green
C4 holds for the retrieval (exact overlay scores)
```

## Review of M5 / M6 — four defects, and a theme

The first pass over M5 and M6 together found four real defects, all in the
same family, plus a set of paths that turned out to be right and now say
so in a test. The family: **an index's work is proportional to the wrong
quantity.** Twice it was proportional to the corpus where it should have
been proportional to the lists it already walked, and twice it did a full
rebuild's work for a write that changed nothing.

### 1. Phrase queries were quadratic in the corpus

`phrase` looked up each candidate's positions with
`positionsOf(nodeId, code)` — a scan of that term's *entire* posting list —
once per candidate, once per phrase term, and once more to score. The
comment directly above it claimed the positions were "gathered once so the
alignment test is a membership check and not a scan of the posting list".
They were not gathered. The comment described the fix, which is what a
comment written while fixing a bug does when the fix does not land.

Measured on 16k documents with every document holding the first term:
2 ms at 2k, 5 ms at 4k, 20 ms at 8k, **80 ms at 16k** — time quadrupling
as the corpus doubled. At 10⁵ documents the feature the milestone exists
for would have been unusable, and no test noticed because the unit tests
run on a hundred documents where quadratic is invisible.

The fix: one pass per phrase term, restricted to the candidate set,
carrying the posting itself so alignment and scoring are both reads of
what the pass already found. **0.3 / 0.6 / 1.1 / 2.1 ms** — linear, and
40× faster at 16k. The regression test is a *work counter*
(`TextIndex.walked`, incremented by every posting a query visits), not a
timing assertion: a timing test on a shared machine fails for reasons that
have nothing to do with the code, and a work counter fails only for the
reason it exists.

### 2. AND scoring was quadratic in the same way

`search(..., andAll = true)` intersected posting lists smallest-first — a
correct, linear merge — and then scored the survivors by finding each
document's posting with a scan of the whole list, per document, per term.
The expensive-looking part was fine; the scoring pass underneath it was
the quadratic one. Now: one pass per matched list, added into the
intersection's document set.

### 3. An unchanged write paid a full re-index (twice)

Probing the commit path turned up this: re-`SET`ting a node's indexed
property to the value it already holds re-indexed it anyway. For the
vector index that is an entire `ef_construction` insert plus a permanent
tombstone — 20 commits on a 4k-node index cost 25.8 ms and left 20 dead
slots, on a walk that then pays for every tombstone it visits
(INDEX.md §4.4). Measured after the fix: **0.39 ms and zero dead slots**,
the no-op costing one pass over the dimensions.

The text index has the same skip, comparing the *analyzed term codes*
against what is already indexed rather than the raw text — two spellings
that fold to the same terms index the same postings, so the second one
really is a no-op, and the analysis happens anyway.

Both skips live in `insert`/`merge`, not in the caller, so every caller
gets them. The freshness tests still pass: a *changed* value tombstones
and reindexes, and the old term stops matching.

### 4. An overlay score differed from the committed score by one ulp

The read-your-writes overlay scores the transaction's own vectors outside
the graph. It computed `dot / (sqrt(na) * sqrt(nb))` where the walk
computes `dot / (la * lb)` on precomputed lengths. Same mathematics, a
different last bit. The DEVLOG for M6.3 claimed those scores were
"exact" — they were exact to within a rounding, and a last-ulp
difference between an overlay row and its committed counterpart is a row
that changes rank the instant the transaction commits. `scoreVec` now
performs the same arithmetic in the same order, and a test asserts
bit-equality against what the walk returns.

### What held up, and now says so in a test

- `vkVector` through M5's sort spill codec: intact, all 501 rows carry
  their vector through a forced spill (M6.3 put a value kind into the
  store that M5's spill has to carry; it did).
- Aggregates over an empty group: `count` 0, `avg` null, `collect` empty,
  and exactly one row — the aggregate is computed *over* the implicit row
  but answers about the absence of rows.
- `sum`/`avg` over a mixed int/float column: 6.5 and 2.1666; `min`/`max`
  return the values themselves, so an int column's minimum is an int.
- Two writes to the same property in one transaction: the last one wins,
  and the first one's frame does not survive into the log's replay.
- An aborted transaction leaves nothing behind, and the ids it consumed
  are not handed out again.
- The constraint path through a real commit: `GLY_ERR_CONSTRAINT` (-5),
  with the offending value named in the message.
- Vector pushdown: `WHERE doc.year = 2020` returns exactly the filtered
  set (not over-fetched rows, not a scan); a pushed conjunct and a `score`
  conjunct compose; `OR` and `<>` route to the remaining filter above.

### The meta-finding

Three of the four defects sat directly under a comment that described the
correct behaviour rather than the code's behaviour. Comments are written
from the specification while the code is written under pressure to make a
test pass; when they diverge, the comment is the more persuasive document
and the worse oracle. The counter is the difference: the regression tests
here assert *work done* and *bits produced*, which is what actually
distinguishes the fixed code from the broken one, and neither can agree
with a comment that has drifted.

```
367 Nim tests (+7 review pins)   115 Ruby runs / 378 assertions
I-vec GREEN · I5 GREEN · E2 0.71 ms · E3 85 s · C1 132/132 + 17/17 refusals
gate exit 0
```

## M7 — the Ruby layer complete, and the ABI's declared-but-empty half

M7's surface was mostly written down a long time ago; what was missing was
the half of it that had been *declared* and never built. The header
declared thirty-four entry points; twenty-six existed. The eight that did
not — the cell accessors, `stats`, `schema`, `checkpoint`, `wal_size` —
were the ones a reviewer reading the header would assume were there, and
three more (`cell_at`, `cell_get`, `cell_blob`) are refusals *by design*.
M6.3 built `db.idx.vector` through the same door without noticing.

### Three refusals that are the implemented contract

`cell_at` and `cell_get` would index into a list/map cell's payload —
which is its JSON rendering — so element access means parsing JSON inside
the engine and returning a sub-cell that points into a buffer the engine
would then own. That is the ownership rule the whole accessor set exists
to uphold, so the accessors refuse with `GLY_ERR_UNSUPPORTED` and the
header says so. `cell_blob` refuses because a blob handle needs freeing
by somebody, and an engine-allocated one puts a second allocator in the
ABI. The host reads the payload once with `cell_text` and walks it there;
that is what the Ruby binding does, and a refusal with a reason beats a
JSON parser in the engine that returns lossy sub-cells.

### The cap protocol, and the status it is not

Every JSON-returning call has a two-phase cap protocol: ask with a small
buffer, the engine reports the size, ask again. A successful probe answers
`GLY_MORE` — "buffer too small, here is the size" — which is *success*.
The Ruby helper read any non-zero status as failure, so every probe
raised, and a node that does not exist — the case where the status
carries the only information there is — surfaced as an `ArgumentError`
from the exception constructor instead of a `SqlError`. Two lines, and
they were the difference between "this node is gone" and "something went
wrong in FFI".

### A checkpoint that did nothing

`checkpoint(truncate: true)` asks to drop every log frame the new
snapshot already contains. The first implementation asked the frame
scanner where the last frame ended and cut there — which is the *end of
the log*, so the flag silently did nothing and `wal_size` never fell. A
checkpoint snapshots at the tip, so the whole log is covered and the
correct cut is zero. The test that caught it is three lines (commit, cut,
assert the size) and it is the kind of test that only exists because the
gate asked "what does this flag do".

### One name, one index

`index_create(kind: :range, …)` and then `kind: :text` on the same
`Label.property` created *two* indexes with the same name: `index_list`
reported `User.email` twice and `index_drop` removed whichever it reached
first. The registry keyed by name but each family had its own table, so
neither saw the other. The name is the identity (INDEX.md §1) and it does
not carry the family; a second family over a taken name is now a refusal
that says which family holds it.

### Definitions are durable; contents are rebuilt

Pin W5 says index *state* is never in the log and indexes rebuild from
live records at open — but until now the *definitions* were not durable
either, so a reopened database had no indexes and no constraints, and
`index_create` was the only way back. Definitions now live in a small
`.indexes` sidecar beside the snapshot (text, one line per definition,
written at every checkpoint and whenever the registry changes). The
snapshot's frozen header and CRC are untouched; no index bytes are stored
anywhere, because the contents rebuild from live records in bounded time.
A reopen finds the same registry, re-enforces a unique constraint against
the rebuilt index, and answers seeks from it.

### What landed in Ruby

The `Cell` hierarchy is real value classes: a `GLY_NODE` cell materializes
as a `Node` view (id + labels + properties, re-read against the store, so
a node handed around reflects later writes), an edge as an `Edge` (id,
type, endpoints), a vector as a `Vector`. `Node.new(db, id)` reads a node
without Cypher; each accessor is one engine call. The durability doors —
`checkpoint`, `backup`, `vacuum`, `schema`, `stats` — and the cursor verbs
— `first`, a capped `to_a` that raises `LimitError` rather than truncating,
`count`, `reset` — are in. The layout files (`version.rb`, the gemspec,
the extension stub) are there, so the gem is installable and says how to
build the engine when the `.so` is missing.

Gates: **R1** — all eleven statuses reach a class, six raised through real
queries. **R2** — GC-stress holding live Cells across batch boundaries and
un-closed statements, then writing, with no segfault and no wedged writer.

```
367 Nim tests   129 Ruby runs / 475 assertions   C1 132/132 + 17/17 refusals
W1/T1 green · E2 0.68 ms · E3 84 s · I5 · I-vec green   gate exit 0
```

## M8 — the model layer

`Glyph::Base` is in: lifecycle, class verbs, lazy `Glyph::Relation`,
associations (`has_many` / `has_one` / `belongs_to` / `through:`), scopes,
callbacks, and the validation door — `validates` in both the Rails hash
form and the positional form, with `uniqueness` deliberately delegating to
an engine constraint rather than a Ruby check that two writers can race.

A create is one crossing and gets its id back from the same statement
(`glyphes_exec_returning`), so `create!` does not read the store twice.

Gates: **R6** — 49 Rails-shaped model tests. **R5** — *measured*, not
asserted: a counter on `Database` verbs plus node-view reads pins one
crossing per verb, and pins the one honest exception, an attribute a
query did not carry, which is a lazy view read for that record when it is
touched (`pluck` is the door for a whole collection in one).
**R10** — `person.knows.first(5)` says `LIMIT 5`; `last` is a reversed
`ORDER BY … DESC LIMIT 1`, never a Ruby-side `.last`. **R9** — a schema
change clears every model's compiled-statement cache, which is now also
bounded at 512.

Two defects found while wiring this, both fixed: `MATCH (n) WHERE n.age =
$id SET …` bound no `$id` (the write params dropped `:id`), so *every*
update matched nothing and reported success; and a query-returned record
held only its id, so every attribute read raised `NoMethodError` until the
node view became the lazy fallback.

M7 also got its two review findings: the `.indexes` sidecar now carries
the family settings (analyzer, metric, `m`, `ef_construction`), so a
reopen rebuilds *the index that was there* rather than a default one, and
`backup` copies the sidecar beside the snapshot and the log.

```
367 Nim tests   178 Ruby runs / 601 assertions   C1 132/132 + 17/17 refusals
W1/T1 green · E2/E3/I5/I-vec green   gate exit 0
```

## Review of M7 + M8

Nine defects found reading the two milestones against their contracts, all
fixed with regressions:

**Silent wrong answers — the worst class.** The `where("…")` qualifier
turned `true` into `n.true` and the word inside `'ana'` into `'n.ana'`;
both statements compiled and both answered **zero rows**. The rewritten
qualifier skips string literals, keywords and `$params` first.
`where(age: nil)` compiled to `n.age = null` — never true in Cypher — so
every absent field answered zero rows; nil now means `IS NULL`, which the
engine has had all along. And `ana.knows.last` emitted `ORDER BY b.id(n)`,
a property of a variable the MATCH never bound, and raised; ordering by a
store id is `id(b)` on the b side and `id(n)` on the n side, and a bare
`order(:id)` means the store id on both.

**The door had a way around it.** `freeze` set a flag and froze nothing:
a "frozen" record accepted `name =`, then `save` **wrote it to the store**.
Freezing the record is not enough — `p.name = x` mutates the Hash an ivar
holds, not the record — so freeze freezes `@attributes` and `@original`
too, and `frozen?` is Ruby's own. The flag version is gone. `touch` was
rewritten to skip validations, then rewritten back: without dirty tracking
touch writes the whole row, so a touch that skips the door is a way to
save an invalid row by calling it a touch. The door holds.

**The view leaked into semantics.** A record a query returned held an id
and a view; `valid?` validated nils for fields the node actually has, so
`update` on a queried record failed on properties it was never shown —
records now hydrate once before validating. A lazy attribute read seeded
`@attributes` but not `@original`, so a mere *read* made `changed?` true.
`upsert` spent a second crossing re-reading the node the MERGE had just
answered; the record is built from the id.

**Names reach statement text.** Property names, order fields and labels
are interpolated, so a hash key like `"x OR n.name"` was an injection the
engine would happily parse. Every interpolation point now goes through one
identifier guard that refuses by name.

**The one cache §0 allows was keyed wrong.** By where *values*, so an app
filtering on a moving value got no reuse; now keyed by shape (the keys),
bounded, and the bound test counts entries rather than trusting the cap.

**M7's sidecar could brick a good database.** `writeFile` truncates before
writing, so a crash mid-write left a torn sidecar and every later open
failed on intact data. Writes go through a temporary and a rename, a
corrupt line is skipped, and a corrupt *file* opens with no indexes — the
documented answer for absent definitions — with the data untouched.

M7 + M8 review score: 9 defects, 9 regressions, none of them found by the
gates that were green when the milestones shipped.

```
367 Nim tests   190 Ruby runs / 643 assertions   C1 132/132 + 17/17 refusals
```

## M9 — import and export

`db.import` / `db.export` are in, for CSV, JSONL and Parquet, with the
properties the contract names: one transaction around the whole file
(Y12), `exec` in batches of 5 000, `types:` coercion, `skip:` for headers,
and `vector:` building its index *after* the load rather than maintaining
it per row.

**Parquet is written and read here, in Ruby.** PLAIN encoding, uncompressed,
one row group, one page per column — about 600 lines including a Thrift
compact-protocol codec, because Parquet's footer *is* a Thrift struct and
there is no way to the format without one. The alternative was the
`parquet` gem, which is a native extension whose loader failed on this
Ruby's build; a graph database whose only dependency is `ffi` should not
carry an Arrow stack for a format the engine never sees (P9). The reader
refuses what it does not implement — dictionary, compression, several row
groups — *by name*, because a reader that mis-decodes a file it does not
understand is worse than one that says so.

Three defects found while building it, all of the kind this milestone is
for:

- **R11 did not work, and the test said it did.** `read_csv` returned the
  *requested* keys as the file's columns, so the unknown-column check
  compared the keys with themselves, never fired, and a misspelled header
  silently dropped its column — exactly what Y13 forbids, behind a green
  test.
- **A failed import left rows behind.** Coercion failures inside the batch
  loop wrote a partial file. The whole file is now coerced *before* the
  transaction opens, so a rejected row writes nothing at all.
- **A definition-level stream had no length.** RLE streams ran until the
  group count ran out, so every page after its first run decoded as
  garbage — silently, as wrong numbers. DataPageV1's 4-byte length prefix
  is what makes a run sequence decodable; the writer had none.

**R8**: a 10^6-row CSV imports in **28 s** (budget 60 s), and the Parquet
export lands within **0.002 %** of a byte count recomputed from the format
itself — PLAIN widths and RLE level arithmetic — rather than from a golden
file this writer produced, which would only prove it reproduces itself.

```
367 Nim tests   209 Ruby runs / 685 assertions   C1 132/132 + 17/17 refusals
R8: CSV 28.0 s < 60 s   Parquet drift 0.0020 % < 0.1 %
```

## M10 — corruption & recovery

The milestone is one gate: **W3, 10⁶ bit-flips, every outcome a clean open
or a named error.** WAL.md had recorded it for months as "the sweep is not
implemented" — unit-tested at one flip per region, which is the right unit
test and not the gate. Writing the sweep found **four defects that no unit
test had**, and every one of them was silent data loss or a crash:

**1. A CRC mismatch was treated as a torn tail.** Recovery stopped, *truncated
the file*, and opened "successfully" with every transaction after the damage
missing — and destroyed the damaged bytes, so there was nothing left to
diagnose. A torn tail is a frame that was never finished (the crash case,
correct to drop). A finished frame whose content fails its checksum is
damage. Now: `GLY_ERR_CORRUPT` (-12), a named error, and the file is left
exactly as found.

**2. `txnFlags` was outside the frame CRC.** The CRC covered
`header[0..20] ‖ payload` — and the CRC field itself is at 20..23, so
`txnFlags` at 24 was in neither span. That is where the COMMIT bit lives.
Flipping one bit there turned a committed transaction into an uncommitted
one: the log replayed into a graph holding that transaction's nodes as if
they had committed, **CRC valid, no error anywhere**. The frame CRC now
covers the whole header except the checksum field.

**3. A flipped `payloadLen` in the middle of the log was a torn tail.** A
header whose declared payload runs past the end of the file is genuinely
ambiguous — a crash between the header write and the payload write leaves
the same bytes. It stops being ambiguous the moment another *valid* frame
sits behind it: the log did not stop here, so nothing truncated this frame,
so its length field is a lie. `replay` now scans forward, and a frame that
overruns with a good frame behind it is damage.

**4. A truncated snapshot raised `AssertionDefect`.** `doAssert buf.len >=
SnapshotHeaderSize` — in a release build the assert vanishes, and in a
checked build `AssertionDefect` is *not* a `CatchableError`, so it unwound
past every host `rescue` and took the process down. A snapshot cut short by
power loss is shorter than its own header, which is the ordinary W2 case. It
is now a refusal the caller can catch.

**What one unit test said about all this:** `test_wal.nim` asserted "a bit
flip in the log stops replay there, earlier commits survive (W3)" — which
is defect 1, written down as the intended behaviour. The test was green and
the gate would have been too, had it existed.

**The one outcome the format cannot settle.** A flip in the *final* frame's
length field is byte-identical to a crash between that frame's header and
its payload, and WAL.md W4 says to drop such a frame. At 10⁶ flips this is
117 cases (0.012 %); the harness counts them as `ambiguous`, reports the
count, and fails on every other silent outcome. Calling it green is not
tolerance — it is the enumeration of the class the format permits.

```
369 Nim tests   210 Ruby runs / 693 assertions   C1 132/132 + 17/17 refusals
W1/T1 green   W2 55 boundaries green   W3 10⁶ flips: 999 883 named, 0 silent
```

## Review of M1–M10 (the whole system)

A cross-cutting pass over every milestone, focused on what single-milestone
reviews cannot see: the invariants that span the whole system, the gate
inventory, and the core that the earliest milestones wrote before any
review culture existed.

**Found and fixed:**

- **R3 was violated in plain sight.** `Statement#step` — one FFI crossing
  per row, the exact thing R3 forbids — was a *public* method. It was public
  because nothing had made the call: the suite built on `each_slice` and
  `to_a`, which batch, and `step` sat unexamined between them. It is now
  private, and a regression test pins the visibility. The engine-level
  `stn` the TCK uses is unaffected — that is a different layer's contract.

**Found and documented (no code change needed):**

- **R5's header overclaims.** "Every verb is exactly one FFI crossing" is
  true for the measured verbs (create, find, update, destroy, count,
  exists?, first, last, reload) but not for the bulk shapes: `destroy_all`
  is one query plus N deletes (Rails-faithful), and `find_or_create_by` on
  a miss is a find plus a create. Both match Rails, and both are defensible;
  the word "every" was the only wrong part. Measured, not asserted.

- **M9's `batch:` parameter partitions the transaction; it does not batch
  statements.** The grammar has no multi-row insert, so each row is its own
  `exec` inside one transaction regardless of `batch:`. The performance
  contract that matters (one transaction, no per-batch commit) is real;
  the parameter name was the part that overclaimed. Documented in the
  import layer's header.

**Verified clean, no change needed:**

- The M1 core (arena, ids, prop codec) is careful, heavily annotated with
  the bugs it already fixed, and hammered by W1/W2/W3. No new defect found
  in a targeted read.
- R4 (cell-after-close) holds by design: materialized values are Ruby's
  own copies, so post-close access is safe. Probed to confirm.
- The M1 invariants (S1–S10) hold after a mixed create/delete/update/
  checkpoint workload: `integrity_check` reports clean.
- The commit path (M2) and its index interplay (M6) are annotated with the
  defects they already fixed; a fresh read found nothing new.

**Gate inventory, as it stands:**

| Gate | Status |
|---|---|
| R1 (statuses → classes) | **green**, 12 statuses since M10 |
| R2 (GC stress, live cells) | green |
| R3 (no per-row FFI path) | **green now** — was violated by public `step` |
| R4 (cell after close) | green |
| R5 (≤1 crossing per verb) | green for measured verbs; bulk shapes documented |
| R6 (60 unit + 12 integration) | 58 model tests — short of the letter, honest in ROADMAP |
| R7 (raw Cypher reachable) | green |
| R8 (10⁶ CSV; Parquet vs reference) | **green** (28 s; 0.002 %) |
| R9 (schema change clears cache) | green |
| R10 (lazy associations, LIMIT) | green |
| R11 (unknown import column) | green |
| R12 (8 Puma workers) | **not implemented** — no harness exists |
| W1 (kill -9 recovery) | green |
| W2 (truncate at 4 KB) | **green** since M10 |
| W3 (10⁶ bit-flips) | **green** since M10 (999 883 named, 0 silent) |
| W4 (torn tail) | green |
| W5 (replay idempotence) | green |
| W6 (checkpoint during WAL) | green (unit-level) |
| W7 (throughput) | **not implemented** |

```
370 Nim tests   210 Ruby runs / 693 assertions   C1 132/132 + 17/17 refusals

## M11 — the literal gate

M11 was to be benchmarks: glyphes against SQLite edge tables, `make bench`,
`ARCHITECTURE.md`, a `limitations.md`, and the 20-node soak. Before writing
a headline number, the benchmark needed a scale it could actually load, and
the load calibration is where the milestone turned over.

### Four hundred milliseconds hiding behind a benchmark

Building a 2·10^4-node graph and asking for one indexed node came to about
4.6 ms per query. Not slow because of the index — slow because of it *not
being used*. The first bisect:

| query, 2·10^4 nodes            | rate     |
|---------------------------------|----------|
| `RETURN 1`                      | 61 000/s |
| `WHERE p.id = $i`, no index     |   215/s |
| `WHERE p.id = $i`, index built |   205/s |

A full scan, an index, and no index all within one noise band: the index
was doing nothing at all. Then the spelling:

| `WHERE p.id = …`, index built   | rate      |
|---------------------------------|-----------|
| `= $i` (parameter)              |    235/s  |
| `= 19999` (literal)             | 51 164/s  |

**217x, on the same predicate, differing only in a `$`.**

### The bug

`src/cypher/plan.nim`, `seekCandidates`, took a conjunct only when the
right-hand side was `ekLit`:

```nim
if right.kind != ekLit:
  return
```

`evalLiteral` — three lines above — resolves `ekParam` against the bound
parameter table, and its comment reads "*a parameter resolves here, so
`WHERE n.age = $age` is seekable*". The intent was there; the gate one
level below made it unreachable for exactly the case it named. A parameter
predicate planned as a full scan, silently, with no error and no slower
result — every answer correct, every query 200x slower.

It reached the model layer, the importer, and every benchmark in the repo,
because those are written with parameters. `P.where(age: k)` on 2·10^4
indexed rows: **197/s**.

### Why no gate caught it

I5 measures the index *directly* — seek an integer, seek a range, assert
under budget. It cannot fail, because the index was always correct. The
gate that existed for "does the planner use the index" was
`n.age > 30`: a literal, on the one spelling nobody writes by hand. The
test asked whether the index works. The product asks whether the *planner
reaches* it.

### The fix

`seekCandidates` accepts `ekLit` or `ekParam` wherever a value side is
allowed, resolving through the `evalLiteral` that already understood both.
One condition, on the three value-side branches.

| | before | after |
|---|---|---|
| query, indexed, parameter   | 235/s   | 46 009/s |
| model layer `P.where(age:)` | 197/s   | 30 558/s |
| reopened ORC db, 5·10^4     | full scan | 35 125/s |

### The direction that matters

A seek may only ever *add* speed. So the new tests pin the plan, not the
clock:

- `$p` and the literal reach the same plan, for `=`, `<=`, `>` (equal
  probe counts, equal answers)
- an **unbound** parameter resolves to null, null is not keyable, so the
  scan answers — seeking would return nothing and silently drop rows, the
  one direction an accelerator may not move
- answers are compared against an unindexed run across 12 predicate shapes
  (equality, ordering both ways, `IN`, flipped `lit = prop`, string keys,
  two conjuncts, non-indexed property, unbound parameter): identical

373 Nim · 211 Ruby / 697 assertions · C1 132/132 + 17/17 refusals · I5, I-vec,
M1 GREEN

### What M11 owes the benchmarks

Two defects M11's own plan would have buried:

1. `bench_sqlite.rb` as first written mixed *property* ids (SQLite side,
   `$src`/`$dst`) with *internal* ids (glyphes side, `id(a) = …`). The two
   engines were answering different questions. Every benchmark now asserts
   answer equality before it prints a time, because a fast wrong number is
   worse than no number.
2. Edge load measured 881 edges/s against 110 000 nodes/s — the grammar
   refuses a comma-`MATCH`, so an edge needs `MATCH … MERGE … CREATE`, and
   each edge pays a re-filter. This is the real cost of the dialect's
   expressiveness, and it belongs in `limitations.md` with the number,
   not in a footnote.

```
373 Nim tests   211 Ruby runs / 697 assertions   C1 132/132 + 17/17 refusals
```
