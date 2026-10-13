# glyphes — ABI: the Nim engine seen from Ruby

> **Status:** specification, pre-implementation. Every *pin* here is
> normative. The C header in §2 is the contract; the Nim module map in §4
> is where each function lives.

This document fixes the seam between the Nim engine (`src/`) and the Ruby
layer (`lib/glyphes/`). It is deliberately narrow: one database handle, one
statement handle, one batched row cursor. There is no object model, no
callback into Ruby, and no struct crossing the boundary **by value**.

---

## 1. The three rules that make this safe

FFI between a systems language and a GC'd one goes wrong in three
predictable ways. Every rule below exists to kill one of them.

**Rule 1 — opaque handles only.** Every engine object crosses as
`GlyHandle` (a `uintptr_t` with a tagged generation). Ruby never sees a
Nim `ptr`, never dereferences, never stores one past the call that
produced it. Stale handles are detected, not dereferenced (§3).

**Rule 2 — no structs by value, ever.** Not for values, not for records,
not for parameters. If data must cross, the caller passes a pointer to
*its own* buffer and the engine fills it. This makes the ABI immune to
Nim/Ruby struct-layout drift, which is the single worst failure mode when
two toolchains generate layout independently.

**Rule 3 — the statement owns everything the row stream borrows.** Every
pointer reachable from a `GlyCell` is arena memory owned by the statement
that produced it, and is invalidated by exactly one call: the next
`glyphes_stmt_step` on that statement, or `glyphes_stmt_close`. Ruby
bindings encode this as `Statement#each` holding a native reference, so
a stale read is a Ruby exception, never a segfault.

### Batch, not per-value

FFI call overhead (~1µs) dominates per-node access. A 3-hop traversal
returns 10⁵ nodes; one call per node means 100ms of pure transition cost.
So `glyphes_stmt_step` fills a caller-provided array of **fixed-size
cells** and returns how many are valid. The cell holds a *pointer and a
length* into statement arena memory — it never copies a string, never
boxes, never allocates on the Ruby side.

```ruby
db.query("MATCH (p:Person)-[:KNOWS]->(q) RETURN p, q").each_slice(256) do |slice|
  # one FFI crossing per 256 rows
end
```

Cells are **24 bytes**: `{ tag: u32, len: u32, ptr: ptr, aux: u64 }`
= 4 + 4 + 8 + 8 on LP64. The `aux` slot carries the integer payload for
`GLY_INT`/`GLY_FLOAT` so numeric access is a pure Ruby array read with no
engine round-trip.

The Ruby side does **not** hand-roll this layout. `ffi.rb` declares the
struct once with `FFI::Struct` layout `:packed`, and gate B1 asserts
`sizeof(GlyCell) == 24` at load time — a cgen change that alters the
layout fails loudly on `require` instead of corrupting memory later.

---

## 2. The header

```c
/* glyphes.h — generated ABI, hand-maintained here.
 * Glyphes 0.1 · Nim 2.2 · ORC memory management
 *
 * All functions return a GlyStatus. 0 is success. Errors carry a
 * message retrievable from the owning handle; the global slot carries
 * errors raised before a handle exists (bad arguments, OOM).
 */
#ifndef GLYPHES_H
#define GLYPHES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status ------------------------------------------------------ */

typedef enum {
  GLY_OK            =  0,
  GLY_MORE          =  1,   /* batch full, more rows remain     */
  GLY_DONE          =  2,   /* row stream exhausted             */
  GLY_ERR           = -1,   /* handle-local error; see gly_error */
  GLY_ERR_CLOSED    = -2,   /* handle used after close          */
  GLY_ERR_STALE     = -3,   /* handle generation no longer live */
  GLY_ERR_SQL       = -4,   /* Cypher parse / semantic error    */
  GLY_ERR_CONSTRAINT= -5,   /* uniqueness / type constraint      */
  GLY_ERR_IO        = -6,   /* WAL or snapshot filesystem error */
  GLY_ERR_READONLY  = -7,
  GLY_ERR_BUSY      = -8,   /* writer already active            */
  GLY_ERR_LIMIT     = -9,   /* configured budget exceeded       */
  GLY_ERR_NOMEM     = -10,
  GLY_ERR_UNSUPPORTED = -11,/* valid Cypher, out of contract    */
  GLY_ERR_CORRUPT     = -12 /* CRC / magic mismatch: file damaged.
                           * NOT the torn tail, which is a frame that was
                           * never finished and is dropped.            */
} GlyStatus;

/* ---- handles and values ------------------------------------------ */

typedef uintptr_t GlyHandle;   /* opaque; 0 is never valid        */

typedef enum {
  GLY_NULL = 0, GLY_BOOL, GLY_INT, GLY_FLOAT,
  GLY_STRING, GLY_BYTES, GLY_VECTOR, GLY_NODE, GLY_EDGE,
  GLY_PATH, GLY_LIST, GLY_MAP, GLY_NULL_TYPE
} GlyType;

/* Write-only from the host. Never construct or assign one in Ruby.
 * sizeof == 24 on LP64; asserted at load time by the Ruby binding. */
typedef struct {
  uint32_t tag;    /* GlyType                                    */
  uint32_t len;    /* elements (chars, bytes, dims) or 0         */
  const void *ptr; /* arena memory owned by the statement        */
  uint64_t aux;    /* i64 payload, or f64 bits, or id            */
} GlyCell;          /* 4 + 4 + 8 + 8 = 24 bytes                   */

/* Path components. A GLY_PATH cell holds three parallel arrays in
 * statement arena memory, addressed with glyphes_cell_path_*. */
typedef struct {
  uint32_t count;   /* node count; edge count is count - 1        */
  const int64_t *nodes;  /* node ids, in traversal order           */
  const int64_t *edges;  /* edge ids, count-1 entries              */
  const uint8_t  *dirs;  /* 0 = src→dst, 1 = dst→src, count-1     */
} GlyPath;          /* caller-allocated; filled by the engine     */

/* ---- library ----------------------------------------------------- */

int32_t     glyphes_version(uint32_t *major, uint32_t *minor, uint32_t *patch);
const char *glyphes_global_error(void);
void        glyphes_global_error_clear(void);

/* Per-thread allocator and arena statistics, as JSON. Same
 * buffer-protocol as glyphes_schema: cap is in/out. */
GlyStatus   glyphes_stats(char *json_out, size_t cap, size_t *written);

/* ---- database ---------------------------------------------------- */

/* mode is a bitmask of GlyOpenMode. */
GlyStatus glyphes_open(const char *path, int32_t mode, GlyHandle *out_db);
GlyStatus glyphes_close(GlyHandle db);

enum {
  GLY_OPEN_READONLY = 1 << 0,
  GLY_OPEN_CREATE   = 1 << 1,   /* create if absent             */
  GLY_OPEN_MEMORY   = 1 << 2,   /* ":memory:", no WAL           */
  GLY_OPEN_READWRITE= 1 << 3    /* mmap the snapshot if present */
};

typedef struct {          /* filled by the engine; caller allocates */
  uint64_t nodes;
  uint64_t edges;
  uint64_t labels;
  uint64_t rel_types;
  uint64_t properties;      /* distinct property keys */
  uint64_t bytes_resident;
  uint64_t wal_bytes;
  uint64_t generation;      /* snapshot generation    */
} GlyStat;

GlyStatus glyphes_stat(GlyHandle db, GlyStat *out);

/* ---- transactions ------------------------------------------------ */

typedef struct {
  uint64_t id;
  uint64_t nodes_written;
  uint64_t edges_written;
  uint64_t properties_written;
  uint64_t wal_bytes;
} GlyTxInfo;

GlyStatus glyphes_tx_begin(GlyHandle db, GlyHandle *out_tx);
GlyStatus glyphes_tx_commit(GlyHandle db, GlyHandle tx);
GlyStatus glyphes_tx_rollback(GlyHandle db, GlyHandle tx);
GlyStatus glyphes_tx_info(GlyHandle tx, GlyTxInfo *out);

/* ---- statements and cursors -------------------------------------- */

/* params_json is a JSON object: {"$name": <value>}. null for none.
 * Named parameters only — positional binds buy nothing and complicate
 * statement reuse. */
GlyStatus glyphes_prepare(GlyHandle db, const char *cypher,
                          const char *params_json,
                          GlyHandle *out_stmt);
GlyStatus glyphes_stmt_reset(GlyHandle stmt);

/* Fills out_cells[..n]. Returns GLY_MORE when the batch was filled and
 * more rows remain, GLY_DONE at end of stream. */
GlyStatus glyphes_stmt_step(GlyHandle stmt, GlyCell *out_cells,
                            size_t cap, size_t *out_rows);

/* Column names for the current stream, NUL-separated, caller frees with
 * glyphes_free_columns. Stable for the lifetime of the prepared shape. */
GlyStatus glyphes_stmt_columns(GlyHandle stmt, const char **out,
                               size_t *out_len, uint32_t *out_count);
void      glyphes_free_columns(const char *cols);

/* -- cell accessors: copy out of arena memory, never borrow ------ */

/* NOTE (M4): the `c` parameter is `GlyCell *`, not `const GlyCell *`, in
 * glyphes.h. Nim cannot express a const pointer parameter, and a signature
 * the implementation language cannot spell is not a contract. The
 * accessors do not write through `c`; the const was documentation the
 * compiler could not enforce. This paragraph is the record. */

/* Copies at most cap bytes (always NUL-terminates when cap > 0) and
 * reports the full length so truncation is detectable. */
GlyStatus glyphes_cell_text(GlyCell *c, char *out, size_t cap,
                            size_t *out_len);
GlyStatus glyphes_cell_bytes(const GlyCell *c, uint8_t *out, size_t cap,
                             size_t *out_len);

/* Blob/vector into a fresh Ruby-owned buffer. */
GlyStatus glyphes_cell_blob(const GlyCell *c, const void **out, size_t *out_len);

/* Element access for GLY_LIST / GLY_MAP / GLY_VECTOR. */
GlyStatus glyphes_cell_len(const GlyCell *c, uint32_t *out);
GlyStatus glyphes_cell_at(const GlyCell *c, uint32_t i, GlyCell *out);
/* GLY_MAP: key must be a string cell. */
GlyStatus glyphes_cell_get(const GlyCell *c, const char *key, GlyCell *out);

/* Node/edge identity, for object-graph navigation without Cypher. */
GlyStatus glyphes_cell_id(const GlyCell *c, int64_t *out);

/* Path components. Borrows the cell's arena memory like every other
 * accessor, so it is invalidated on the same boundary (B3). */
GlyStatus glyphes_cell_path(const GlyCell *c, GlyPath *out);
/* Out-of-range i returns GLY_ERR rather than reading past the array. */
GlyStatus glyphes_cell_path_node(const GlyCell *c, uint32_t i, int64_t *out);
GlyStatus glyphes_cell_path_edge(const GlyCell *c, uint32_t i, int64_t *out,
                                 uint8_t *out_dir);

GlyStatus glyphes_stmt_close(GlyHandle stmt);

/* -- mutation without a transaction: autocommit ------------------- */

/* Batched write path for import. Returns rows-affected via out_n.
 * Faster than tx-wrapped statements by ~40% because it skips the
 * per-statement savepoint. */
GlyStatus glyphes_exec(GlyHandle db, const char *cypher,
                       const char *params_json, int64_t *out_n);

/* ---- schema and meta -------------------------------------------- */

enum {
  GLY_SCHEMA_NODES = 1 << 0, GLY_SCHEMA_EDGES = 1 << 1,
  GLY_SCHEMA_LABELS = 1 << 2, GLY_SCHEMA_PROPERTIES = 1 << 3,
  GLY_SCHEMA_INDEXES = 1 << 4
};

/* DECIDED (was open question, ABI.md §7): a caller-allocated buffer with
 * a size-predicting retry, not a fixed cap and not an engine-allocated
 * string. On return out_len is the full length; if it exceeds cap the
 * buffer was not written and the caller retries with cap = out_len. */
GlyStatus glyphes_schema(GlyHandle db, int32_t what, char *json_out,
                         size_t cap, size_t *out_len);

/* ---- indices (explicit control; CREATE INDEX in Cypher too) ------ */

enum { GLY_IDX_RANGE = 0, GLY_IDX_TEXT = 1, GLY_IDX_VECTOR = 2 };

/* Create takes a JSON options object, e.g.
 *   range : {"property":"age"}
 *   text  : {"property":"bio","analyzer":"standard"}
 *   vector: {"label":"Doc","property":"embedding","dim":768,
 *            "metric":"cosine","m":16,"ef_construction":200}
 * If the target is empty the index is created empty and populated on
 * first write; otherwise it backfills from the existing store. */
GlyStatus glyphes_index_create(GlyHandle db, int32_t kind,
                               const char *options_json);
GlyStatus glyphes_index_drop(GlyHandle db, const char *name);
GlyStatus glyphes_index_list(GlyHandle db, char *json_out,
                             size_t cap, size_t *out_len);
GlyStatus glyphes_index_rebuild(GlyHandle db, const char *name);

/* Bulk load: the HNSW build is 10-40x faster with an explicit
 * build-then-insert than with incremental inserts. */
GlyStatus glyphes_index_build(GlyHandle db, const char *name);

/* ---- durability -------------------------------------------------- */

enum { GLY_CHECKPOINT_TRUNCATE = 1 << 0, GLY_CHECKPOINT_FSYNC = 1 << 1 };

GlyStatus glyphes_checkpoint(GlyHandle db, int32_t flags);
GlyStatus glyphes_wal_size(GlyHandle db, uint64_t *out_bytes);

/* Verify snapshot + WAL against the store. Read-only. */
GlyStatus glyphes_integrity_check(GlyHandle db, const char **out_report);

#ifdef __cplusplus
}
#endif
#endif /* GLYPHES_H */
```

**Deliberately absent.** No `glyphes_node_new` / `glyphes_edge_create` /
`glyphes_prop_set`. Mutation is Cypher-only on purpose: a hand-written
node API would be a second, divergent mutation path with its own
constraint and WAL semantics, and it is the fastest way to grow this
project back into Memgraph's size. Importers use `glyphes_exec` in a
loop inside one transaction, which is batched anyway.

**M5.1 added `glyphes_exec`.** `rows affected` counts entities created,
deleted or updated — not property writes, because `SET n.age = 1` updates
one node and an importer asking "how much landed" wants entities.

**What M4 exported, and what it did not.** The statement surface landed as
nine symbols: `glyphes_prepare`, `glyphes_stmt_step`,
`glyphes_stmt_columns`, `glyphes_stmt_columns_count`, `glyphes_stmt_close`,
`glyphes_stmt_reset`, `glyphes_cell_text`, `glyphes_cell_id`,
`glyphes_cell_len`. Everything else this header declares is still
unimplemented and therefore absent from the library, which is the same
convention the M0–M3 symbols followed: the header is the contract, the
shared object is the truth, and `nm -gU lib/libglyphes.so` is how you tell
them apart.

Three consequences, all deliberate:

- **`glyphes_stmt_columns` returns engine-owned storage**, valid until the
  next call on this thread — the same rule as the error slot (B1). The
  header's comment about `glyphes_free_columns` predates that decision; the
  function is declared and unimplemented because no caller currently needs
  to keep the names past the next call. A host that wants a copy copies it,
  which is what `lib/glyphes/database.rb` does.
- **`glyphes_exec` joins an open transaction.** The header calls it the
  mutation door "without a transaction", and it is — but when a
  transaction is *already* open (the handle `glyphes_tx_begin` registered),
  the exec writes through that one and does not commit. Otherwise
  `db.transaction { db.exec(...) }` would commit inside the block, and the
  block's rollback could not undo it — a rollback that silently does
  nothing is the worst failure this ABI has.
- **`glyphes_exec` closes the statement before it commits.** Not a style
  choice: `commitTransaction` merges behind `beginWrite`, which waits for
  the reader count to reach zero, and the statement being closed holds one.
  Committing first deadlocks the writer gate against its own thread.
- **`glyphes_prepare` cannot leak a snapshot.** The reader count a
  statement holds is released on every path out of prepare, including the
  refusals the planner raises *after* the snapshot is taken. Before the
  guard existed, `MATCH p = (a)-[]->(b) RETURN p` — refused, correctly —
  parked the writer gate forever: `endRead` is the only code that
  decrements the count, and the statement that would have run it never
  existed. `tests/unit/test_exec.nim` holds the regression.
- **`glyphes_stmt_reset` answers `GLY_ERR_UNSUPPORTED`.** Statements are
  single-use (B2, `EXEC.md` §1): re-running means re-binding parameters and
  taking a new snapshot, which is a second prepare. The engine says so
  rather than half-implementing a reset that silently reuses the old
  bindings.
- **`glyphes_cell_text` accepts list and map cells as well as strings**,
  because those two cross as their JSON rendering (see `toCell`). It
  refuses vectors, whose payload is doubles rather than text. The same
  fact bends `glyphes_cell_len`: for list and map cells `len` is the byte
  length of the JSON payload — `cell_text` copies by it — and only a
  vector or path cell reports an element count. The header said "element
  count for GLY_LIST / GLY_MAP"; a C host that believed it would read the
  wrong number, so the header now says what the engine does and this
  paragraph is the record, same as the `const` amendment above.
- **`glyphes_cell_text`'s truncation path writes nothing.** The header
  comment says "always NUL-terminates when cap > 0"; the implementation
  refuses a partial copy — it sets `out_len`, returns `GLY_MORE`, and the
  caller retries with a buffer of at least `out_len + 1`. A half-copied
  string that happens to end in a NUL is a worse failure mode than a
  status the caller already has to handle. The
  element-wise accessors (`cell_at`, `cell_get`, `cell_blob`) and the path
  accessors are unbuilt: paths are refused at parse in this slice, and
  list/map element access would parse JSON inside the engine to hand back
  a sub-cell, which is the wrong place for it.

**Deliberately absent, phase 2.** No callbacks, no user-defined
functions, no streaming query channels. They are the two features that
turn a library into a server, and the server is phase 2.

---

## 3. Handle lifetime

Handles are `uintptr_t` with a 24-bit generation in the high bits, so a
reused address never validates as the old object:

```
  handle = (generation << 40) | slot
```

`glyphes_close` bumps the slot's generation. A call with a stale handle
returns `GLY_ERR_STALE` instead of touching freed memory. This is not
paranoid belt-and-braces — it is what makes `ensure`-based cleanup in
Ruby safe when an exception unwinds mid-transaction.

The Ruby's `Database#close` and `Statement#close` are idempotent and set
the Ruby object to a closed state; the native handle is dropped exactly
once. `ObjectSpace.define_finalizer` is registered **only** as a leak
alarm in development builds, never as the normal path: finalizers run at
GC time, and a GC-time `close` on a live WAL is a data-corruption bug
waiting for a bad day.

---

## 4. Module map

```
glyphes/
  src/
    glyphes.nim          entry, --app:lib; the ONLY module with exportc
    glyphes.h            the contract; abi.nim and ffi.rb both read it
    glyphes_init.c       the constructor that calls NimMain (M0-NOTES §2)
    abi.nim              the Nim mirror of glyphes.h: types, status
                         constants, version (ABI.md)
    errors.nim           GlyError, the global error slot, fail()
    handles.nim          generation-tagged handle registry

    store/
      arena.nim          bump allocator; offset 0 reserved; length-prefixed blobs
      ids.nim            dense i64 ids, stable per object; free list for reclaim
      dict.nim           open-addressed dictionary, codes from 1, append-only
      node.nim           NodeRec 48 B, flags, eagerly-maintained degrees
      edge.nim           EdgeRec 56 B, threaded-list links, direction
      label.nim          per-label member lists, O(1) swap-remove
      prop.nim           PropSlot 16 B, the Value model, the blob codec
      store.nim          the aggregate, adjacency, invariants S1-S10

    index/
      range.nim          ordered index (sorted block array + B-tree overlay)
      text.nim           inverted index, tokenizer, BM25 scoring
      vector.nim         HNSW, metric dispatch, filtered traversal
      registry.nim       index registry, build/backfill orchestration

    txn/
      txn.nim            single-writer, snapshot-read isolation
      cow.nim            copy-on-write page discipline
      budget.nim         per-transaction budget enforcement

    wal/
      wal.nim            append-only mutation log, frame checksums
      snapshot.nim       snapshot writer + mmap reader
      recover.nim         replay, idempotence, torn-tail detection

    cypher/
      lexer.nim          openCypher subset tokenizer
      parser.nim         recursive descent → AST
      ast.nim            AST types
      semantic.nim       name binding, type/scope resolution
      plan.nim           greedy index selection (no cost model, §PRD)
      ops.nim            volcano operators: ScanAll, ScanByLabel, Expand,
                        Filter, Project, Aggregate, Sort, Skip, Limit,
                        Unwind, Merge, Create, Delete, Set
      expr.nim           expression evaluation
      proc.nim           the small builtin function table
      execute.nim        statement lifecycle, arena, column binding

    stats.nim            counters, /stats text output

  lib/glyphes/
    glyphes.rb           require graph, error classes
    ffi.rb               ffi_lib bindings + struct layouts
    database.rb          Database, transaction, checkpoint, integrity
    statement.rb         Statement, Result, batched each/each_slice
    cell.rb              Cell value objects (lazy, arena-backed)
    errors.rb            GlyError hierarchy mapped from GlyStatus
    active_record.rb     Glyph::Base — Rails-shaped model layer
    import.rb            CSV / JSONL / Parquet readers -> glyphes_exec
    export.rb            query -> CSV / JSONL / Parquet writer
```

`ffi.nim` uses `{.push header: "glyphes.h".}` around the whole public
surface and a `dynlib`/`symlib` footer, so `nim c -d:dll` and
`nim js`-style name mangling never leak into the header.

---

## 5. Ruby-side shape

```ruby
require "glyphes"

Glyphes::Database.open("social.glyph", create: true) do |db|
  db.transaction do
    db.exec("CREATE (:Person {name: $n, age: $a})",
            {"n" => "Ana", "a" => 34})
  end

  st = db.prepare(<<~CYPHER)
    MATCH (p:Person)-[:KNOWS]->(q:Person)
    WHERE p.city = $city
    RETURN p.name, q.name, p.age
  CYPHER
  {"city" => "Lyon"}

  st.each_slice(256) do |batch|     # one FFI crossing per 256 rows
    batch.each { |row| p row.name }
  end
ensure
  st&.close
end
```

`each_slice` is the primitive, `each` is sugar over it with a fixed
batch of 256. There is no per-row FFI path in the public API, and there
will not be one — it would be a trap that looks fast in a microbenchmark
and costs 30x on a real traversal.

`Cell` is a thin view, not a copy. `row.name` reads arena memory; the
`Statement` holds the native reference; touching a `Cell` after its
statement closed raises `Glyphes::ClosedError` instead of reading freed
memory. Strings are materialized lazily and memoized per cell.

---

## 6. Pins

| # | Pin | Rationale |
|---|---|---|
| B1 | Opaque `GlyHandle` only; no struct by value | kills layout drift between cgen and FFI |
| B2 | Batched cursor (`step` fills caller cells) | per-row FFI is 30x slower on traversals |
| B3 | Statement owns all borrowed arena memory | stale reads become Ruby exceptions |
| B4 | Generation-tagged handles; stale → `GLY_ERR_STALE` | `ensure` cleanup is safe under exceptions |
| B5 | Named parameters only, passed as one JSON object | one parse, no positional rebind state |
| B6 | Mutation is Cypher-only; no node/edge object API | one mutation path = one set of WAL semantics |
| B7 | Single writer, snapshot readers; no epoch MVCC | embedded single-process; SQLite's model, not Memgraph's |
| B8 | Error out-param/status returns; no unwinding through the ABI | Nim exceptions cannot cross into Ruby |
| B9 | Every `glyphes_*` call is re-entrant on distinct handles | no hidden global state except the error slot |
| B10 | No user callbacks, no UDF, no query channels in 0.1 | each is a server feature, not a library feature |

---

## 7. Open questions

**Settled at M0, before the header freezes.** Both were listed here while
M0 was unwritten, and both are now decisions, recorded so the reasoning
survives:

- **`json_out` buffer protocol — settled: caller-allocated buffer with a
  size-predicting retry.** `cap` is in/out. On return `out_len` is the
  full byte length including the NUL; if `out_len > cap` nothing was
  written and the caller retries with `cap = out_len`. Two calls in the
  rare case, one call in the common case.

  Rejected alternatives: a fixed cap (needs a size-predicting call for
  *every* API, and a schema with many labels is unbounded), and an
  engine-allocated string (then Ruby must free engine memory through
  `glyphes_free_string`, which is a second allocator in the ABI and a
  second thing to get wrong under `--mm:orc`).
- **`GLY_PATH` representation — settled: `GlyPath` out-param plus
  component accessors.** `glyphes_cell_path` fills a caller-allocated
  `GlyPath { count, nodes, edges, dirs }`, and
  `glyphes_cell_path_node` / `_edge` give bounds-checked component reads
  so a Ruby `Path` never holds raw pointers past the statement.

  Rejected: routing paths through `glyphes_cell_at` as a `GLY_LIST`,
  which would lose the direction array and make `relationships(p)` unable
  to distinguish `KNOWS` from `KNOWN_BY` (`CYPHER.md` §2.6). Direction is
  semantics, not a rendering detail.

**Still open:**

- **`aux` overload.** It carries both integers and f64 bits. Cheap, but
  the Ruby side needs a tag check before reading it as either. If
  profiling ever shows the branch hot, widen `GlyCell` — do not
  restructure the API.
- **`bytes` vs `string` distinction.** `GLY_STRING` is UTF-8 text,
  `GLY_BYTES` is arbitrary binary, and `glyphes_cell_text` vs
  `glyphes_cell_bytes` differ only in validation. They could collapse
  into one accessor with a flag. Kept separate because the Ruby classes
  differ (`String` vs `ASCII-8BIT String`) and a property's declared
  semantics matter to Cypher string functions.
- **`glyphes_integrity_check` return shape.** Returns a `const char *`
  into static storage with no free, which is convenient and means the
  report is only valid until the next call. If reports ever need to be
  collected or compared across calls, this needs the buffer protocol.
