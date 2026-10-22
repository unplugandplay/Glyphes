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

The contract is `src/glyphes.h` — one file, read by the C compiler
(through `{.importc, header: "glyphes.h".}`) and by the Ruby binding
(through the FFI struct layouts), so both sides read one definition.
The copy below is that file, for reading; when it and the file
disagree, the file is right.

```c
/* glyphes - the public C ABI.
 *
 * This header is the contract. src/abi.nim binds to it with
 * {.importc, header: "glyphes.h".} so the C compiler sees these exact
 * declarations; lib/glyphes/ffi.rb binds to the same file with
 * FFI::Struct layouts. Both sides therefore read one definition.
 *
 * Adding to this file means adding to both bindings. Nothing here is
 * generated, and that is deliberate: a header nobody generated is a
 * header nobody can be surprised by.
 *
 * Comments here are C comments and stay ASCII. An em dash in a C header
 * is a hard compile error, not a style nit.
 *
 * Two consequences of being compiled by Nim's C backend, learned the hard
 * way (M0):
 *
 *   - Input string parameters are declared `char *`, not `const char *`.
 *     Nim emits its own declaration for each exported proc as NCSTRING,
 *     which is `char *`, and having both declarations visible makes clang
 *     reject the pair as conflicting types. The engine still copies the
 *     string into Nim-owned memory on entry and never writes through it,
 *     so this is a spelling concession to the code generator, not a
 *     weaker contract. ffi.rb owns the constness on its side.
 *
 *   - Struct types come from this header via {.importc.}, so both the
 *     engine and FFI read one definition of GlyCell, GlyPath and GlyStat.
 *     That part works exactly as intended.
 */
#ifndef GLYPHES_H
#define GLYPHES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- version ----------------------------------------------------- */

#define GLYPHES_VERSION_MAJOR 0
#define GLYPHES_VERSION_MINOR 1
#define GLYPHES_VERSION_PATCH 0

/* ---- status ------------------------------------------------------ */

typedef enum {
  GLY_OK              =  0,
  GLY_MORE            =  1,  /* batch full, more rows remain       */
  GLY_DONE            =  2,  /* row stream exhausted               */
  GLY_ERR             = -1,  /* handle-local error; see gly_error  */
  GLY_ERR_CLOSED      = -2,  /* handle used after close            */
  GLY_ERR_STALE       = -3,  /* handle generation no longer live   */
  GLY_ERR_SQL         = -4,  /* Cypher parse / semantic error      */
  GLY_ERR_CONSTRAINT  = -5,  /* uniqueness / not-null violation    */
  GLY_ERR_IO          = -6,  /* WAL or snapshot filesystem error   */
  GLY_ERR_READONLY    = -7,
  GLY_ERR_BUSY        = -8,  /* writer already active              */
  GLY_ERR_LIMIT       = -9,  /* configured budget exceeded         */
  GLY_ERR_NOMEM       = -10,
  GLY_ERR_UNSUPPORTED = -11  /* valid Cypher, out of contract      */
} GlyStatus;

/* ---- opaque handles and values ----------------------------------- */

typedef uintptr_t GlyHandle;  /* opaque; 0 is never valid             */

typedef enum {
  GLY_NULL = 0, GLY_BOOL, GLY_INT, GLY_FLOAT,
  GLY_STRING, GLY_BYTES, GLY_VECTOR, GLY_NODE, GLY_EDGE,
  GLY_PATH, GLY_LIST, GLY_MAP, GLY_NULL_TYPE,
  GLY_DATE = 13,  /* days since 1970-01-01, in aux (M6.5) */
  GLY_POINT = 14  /* two f64: x in ptr, y in aux (M6.6) */
} GlyType;

/* Write-only from the host: the engine fills these, the host reads
 * them and never constructs one. sizeof == 24 on LP64, asserted at
 * load time by lib/glyphes/ffi.rb (ABI.md B1). */
typedef struct {
  uint32_t    tag;   /* GlyType                                        */
  uint32_t    len;   /* elements (chars, bytes, dims), or 0             */
  const void *ptr;   /* arena memory owned by the statement            */
  uint64_t    aux;   /* i64 payload, or f64 bits, or id                 */
} GlyCell;

/* Path components. A GLY_PATH cell holds three parallel arrays in
 * statement arena memory, reached through glyphes_cell_path*. */
typedef struct {
  uint32_t        count;   /* node count; edge count is count - 1        */
  const int64_t  *nodes;   /* node ids, in traversal order              */
  const int64_t  *edges;   /* edge ids, count-1 entries                 */
  const uint8_t  *dirs;    /* 0 = src->dst, 1 = dst->src, count-1       */
} GlyPath;

/* Counters. Filled by glyphes_stat. */
typedef struct {
  uint64_t nodes;
  uint64_t edges;
  uint64_t labels;
  uint64_t rel_types;
  uint64_t properties;
  uint64_t bytes_resident;
  uint64_t wal_bytes;
  uint64_t generation;
} GlyStat;

/* Per-transaction counters. Filled by glyphes_tx_info. */
typedef struct {
  uint64_t id;
  uint64_t nodes_written;
  uint64_t edges_written;
  uint64_t properties_written;
  uint64_t wal_bytes;
} GlyTxInfo;

/* ---- library ----------------------------------------------------- */

/* All three write through out-params and are safe to call with the
 * pointer set to NULL if you only want the call to validate. */

int32_t glyphes_version(uint32_t *major, uint32_t *minor, uint32_t *patch);

/* Message for the most recent failure on this thread, or "" if none.
 * Valid until the next glyphes_* call on the same thread. */
char *glyphes_global_error(void);
void        glyphes_global_error_clear(void);

/* Per-thread allocator and arena statistics, as JSON. cap is in/out:
 * on return *written is the full length including the NUL, and if that
 * exceeds cap nothing was written — retry with cap = *written. */
int32_t glyphes_stats(char *json_out, size_t cap, size_t *written);

/* ---- database ---------------------------------------------------- */

enum {
  GLY_OPEN_READONLY  = 1 << 0,
  GLY_OPEN_CREATE    = 1 << 1,  /* create if absent                */
  GLY_OPEN_MEMORY    = 1 << 2,  /* ":memory:", no WAL              */
  GLY_OPEN_SNAPSHOT  = 1 << 3   /* mmap snapshot only, no WAL      */
};

int32_t glyphes_open(char *path, int32_t mode, GlyHandle *out_db);
int32_t glyphes_close(GlyHandle db);
int32_t glyphes_stat(GlyHandle db, GlyStat *out);

/* ---- transactions ------------------------------------------------ */

int32_t glyphes_tx_begin(GlyHandle db, GlyHandle *out_tx);
int32_t glyphes_tx_commit(GlyHandle db, GlyHandle tx);
int32_t glyphes_tx_rollback(GlyHandle db, GlyHandle tx);
int32_t glyphes_tx_info(GlyHandle tx, GlyTxInfo *out);

/* ---- statements and cursors -------------------------------------- */

/* Named parameters only, as one JSON object: {"$name": <value>}.
 * null for none. Positional binds would buy nothing and complicate
 * statement reuse (ABI.md B5). */
int32_t glyphes_prepare(GlyHandle db, char *cypher, char *params_json,
                        GlyHandle *out_stmt);
int32_t glyphes_stmt_reset(GlyHandle stmt);

/* Fills out_cells[0..n). Returns GLY_MORE when the batch was filled
 * and more rows remain, GLY_DONE at end of stream. */
int32_t glyphes_stmt_step(GlyHandle stmt, GlyCell *out_cells,
                          size_t cap, size_t *out_rows);

/* Column names, NUL-separated. Caller frees with
 * glyphes_free_columns. Stable for the prepared shape's lifetime. */
int32_t glyphes_stmt_columns(GlyHandle stmt, char **out,
                             size_t *out_len, uint32_t *out_count);
void    glyphes_free_columns(char *cols);

/* -- cell accessors: copy out of arena memory, never borrow -------- */
/* The cell parameter is `GlyCell *`, not `const GlyCell *`: Nim cannot
 * express a const pointer parameter, and a signature the implementation
 * language cannot spell is not a contract. ABI.md records the amendment. */

int32_t glyphes_cell_text(GlyCell *c, char *out, size_t cap,
                          size_t *out_len);
int32_t glyphes_cell_bytes(GlyCell *c, uint8_t *out, size_t cap,
                           size_t *out_len);

/* M4 amendment: len is the *byte* length of the payload for GLY_STRING,
 * GLY_BYTES, GLY_LIST and GLY_MAP (the last two cross as their JSON
 * rendering, and glyphes_cell_text copies by it), and the *element*
 * count only for GLY_VECTOR and GLY_PATH. An earlier comment here said
 * "element count" for list/map; that was a contract the engine does not
 * keep and cell_text depends on breaking. ABI.md §2 records it. */
int32_t glyphes_cell_len(GlyCell *c, uint32_t *out);

/* M7: the three accessors below are REFUSALS with specific statuses, and
 * that is the implemented contract, not a gap. A list/map cell's payload
 * is its JSON rendering, so element access would mean parsing JSON inside
 * the engine and handing back a sub-cell pointing into a buffer the
 * engine would then own — the ownership rule this accessor set exists to
 * uphold. Read the payload once with glyphes_cell_text and walk it in the
 * host, which is what the Ruby binding does. ABI.md records it. */
int32_t glyphes_cell_at(GlyCell *c, uint32_t i, GlyCell *out);   /* GLY_ERR_UNSUPPORTED */
int32_t glyphes_cell_get(GlyCell *c, char *key, GlyCell *out);  /* GLY_ERR_UNSUPPORTED */
int32_t glyphes_cell_blob(GlyCell *c, void **out, size_t *out_len); /* GLY_ERR_UNSUPPORTED */

int32_t glyphes_cell_id(GlyCell *c, int64_t *out);

int32_t glyphes_cell_path(GlyCell *c, GlyPath *out);
int32_t glyphes_cell_path_node(GlyCell *c, uint32_t i, int64_t *out);
int32_t glyphes_cell_path_edge(GlyCell *c, uint32_t i, int64_t *out,
                               uint8_t *out_dir);

int32_t glyphes_stmt_close(GlyHandle stmt);

/* ---- GLYPH QUERY: the surface a child types ---------------------- */

/* GLYPH QUERY is not a second language and not a second engine: it
 * compiles to Cypher and runs on the same statements, the same cells
 * and the same transactions (PRD-GLYPH-QUERY.md). These doors let a
 * client speak the child's language to the engine, and let it ask what
 * a line will run *before* it runs it.
 *
 * The parameters travel as one JSON object, keyed by name without the
 * `$` - the same spelling glyphes_prepare takes. A value is a
 * parameter, never text. */

/* Compile one GLYPH QUERY line to Cypher and parameters, without
 * running it. Two answers, two lengths: "what will run" and "with
 * what".
 *
 * DECIDED (as for glyphes_schema): a caller-allocated buffer with a
 * size-predicting retry. Ask with cap 0, get the length, ask again with
 * a buffer that size; nothing is written when the buffer is too small.
 *
 * A name that collides with the compiler's own (p1, p2, ...) is
 * refused by name: the compiler's parameter and the caller's are
 * different values, and a statement that quietly runs with the wrong
 * one is the failure this layer exists to prevent. */
int32_t glyphes_gq_compile(char *gq, char *params_json,
                           char *cypher_out, size_t cap, size_t *out_len,
                           char *params_out, size_t pcap, size_t *out_plen);

/* Prepare a GLYPH QUERY line as a statement: compile it, then prepare
 * the Cypher. The statement is a Cypher statement - the same cells,
 * the same accessors - so the guarantees above are inherited rather
 * than re-stated.
 *
 * `labels` and `link` are refused here by name: the first is the
 * schema door and the second is glyphes_link, and a door that pretends
 * to be a query is a door whose refusal is a surprise. */
int32_t glyphes_gq_prepare(GlyHandle db, char *gq, char *params_json,
                           GlyHandle *out_stmt);

/* The step and the columns of a GLYPH QUERY statement: the same doors
 * as glyphes_stmt_step and glyphes_stmt_columns, under the GLYPH QUERY
 * names, so a client that knows only the child's language need not
 * learn the engine's to read its rows. */
int32_t glyphes_gq_step(GlyHandle stmt, GlyCell *out_cells,
                        size_t cap, size_t *out_rows);
int32_t glyphes_gq_columns(GlyHandle stmt, char **out,
                           size_t *out_len, uint32_t *out_count);

/* The one write GLYPH QUERY cannot express: two *existing* nodes
 * joined by one relationship. The engine refuses a join (two MATCH
 * clauses) and a cartesian (a comma-MATCH), and a MERGE would *create*
 * a missing endpoint instead of refusing it - so one write door is
 * smaller and more honest than a second execution path.
 *
 * A missing endpoint is refused by name. The edge is written through
 * the transaction, so it is in the log: an edge that a restart forgets
 * is not an edge. Joins an open transaction if there is one, and
 * commits its own otherwise (TXN.md). */
int32_t glyphes_link(GlyHandle db, int64_t from_id, char *type,
                     int64_t to_id, int64_t *out_edge_id);

/* -- mutation without a transaction: autocommit -------------------- */

/* Rows affected via out_n. ~40% faster than the same statement inside
 * an explicit transaction, because it skips per-statement savepoint
 * bookkeeping (TXN.md §9). This is the importer's door. */
int32_t glyphes_exec(GlyHandle db, char *cypher, char *params_json,
                     int64_t *out_n);

/* The write door, and the id of the first created node: the same statement
 * and transaction discipline as glyphes_exec, with the id a
 * `CREATE … RETURN id(n) AS id` produced. The model layer needs this in
 * one crossing (R5) — reading the id back would be a second query racing a
 * concurrent writer for "the node I just made". out_id is 0 when the
 * statement created no node or its first column is not an integer. */
int32_t glyphes_exec_returning(GlyHandle db, char *cypher, char *params_json,
                               int64_t *out_n, int64_t *out_id);

/* ---- schema and meta --------------------------------------------- */

enum {
  GLY_SCHEMA_NODES     = 1 << 0,
  GLY_SCHEMA_EDGES     = 1 << 1,
  GLY_SCHEMA_LABELS    = 1 << 2,
  GLY_SCHEMA_PROPERTIES= 1 << 3,
  GLY_SCHEMA_INDEXES   = 1 << 4
};

/* JSON. Same cap in/out protocol as glyphes_stats.
 *
 * DECIDED (was open question, ABI.md section 7): a caller-allocated
 * buffer with a size-predicting retry, not a fixed cap and not an
 * engine-allocated string. On return out_len is the full length
 * including the NUL; if the buffer was too small nothing was written
 * and the caller retries with cap = out_len. */
int32_t glyphes_schema(GlyHandle db, int32_t what, char *json_out,
                       size_t cap, size_t *out_len);

/* ---- indices ----------------------------------------------------- */

enum { GLY_IDX_RANGE = 0, GLY_IDX_TEXT = 1, GLY_IDX_VECTOR = 2 };

/* options_json, e.g.
 *   range : {"property":"age"}
 *   text  : {"property":"bio","analyzer":"standard"}
 *   vector: {"label":"Doc","property":"embedding","dim":768,
 *            "metric":"cosine","m":16,"ef_construction":200}
 * An empty target leaves the index empty until built or written; a
 * populated target backfills. */
int32_t glyphes_index_create(GlyHandle db, int32_t kind, char *options_json);
int32_t glyphes_index_drop(GlyHandle db, char *name);
int32_t glyphes_index_list(GlyHandle db, char *json_out,
                           size_t cap, size_t *out_len);
int32_t glyphes_index_rebuild(GlyHandle db, char *name);

/* Bulk load. 10-40x faster than incremental inserts (INDEX.md §4.2). */
int32_t glyphes_index_build(GlyHandle db, char *name);

/* ---- durability -------------------------------------------------- */

enum {
  GLY_CHECKPOINT_TRUNCATE = 1 << 0,
  GLY_CHECKPOINT_FSYNC    = 1 << 1
};

int32_t glyphes_checkpoint(GlyHandle db, int32_t flags);
int32_t glyphes_wal_size(GlyHandle db, uint64_t *out_bytes);

/* Report valid until the next glyphes_* call on this thread. */
int32_t glyphes_integrity_check(GlyHandle db, char **out_report);

/* Checkpoint-then-copy, so the result is a consistent pair rather than a
 * file copied mid-commit (WAL.md §3). Fails on a memory database, which
 * has nothing to copy. */
int32_t glyphes_backup(GlyHandle db, char *dest);

/* Rebuild every index from live records and write the snapshot
 * (INDEX.md I14). O(store), and explicit on purpose. */
int32_t glyphes_vacuum(GlyHandle db);

/* Node reads without Cypher (RUBY.md §4.2): labels as a JSON array,
 * properties as a JSON object. The cap protocol: pass cap = 0, get the
 * length in *out_len, retry. A node that does not exist is GLY_ERR_SQL,
 * not an empty object — a deleted node's labels must be distinguishable
 * from a live node that has none. */
int32_t glyphes_node_labels(GlyHandle db, int64_t id, char *json_out,
                            size_t cap, size_t *out_len);
int32_t glyphes_node_props(GlyHandle db, int64_t id, char *json_out,
                           size_t cap, size_t *out_len);

/* An edge's type and endpoints, as JSON: {"id":n,"type":"KNOWS",
 * "src":a,"dst":b}. What makes a Ruby Edge a view rather than an id. */
int32_t glyphes_edge_info(GlyHandle db, int64_t id, char *json_out,
                          size_t cap, size_t *out_len);
int32_t glyphes_edge_props(GlyHandle db, int64_t id, char *json_out,
                           size_t cap, size_t *out_len);

/* ---- follower (PRD-SHARED F2) -------------------------------------
 *
 * A read-only observer of a database's commit history. A follower maps the
 * writer's watermark, replays the .vhist sidecar up to the generation that
 * watermark names, and answers how far it has seen. It holds no nodes,
 * issues no Cypher, takes no write lock, and — deliberately — has no entry
 * point that writes: there is no glyphes_follower_commit, so a caller
 * cannot commit through a follower by mistake or malice. The write-defense
 * is the absence of the symbol, not a check on one that exists.
 *
 * A follower handle is not a database handle: passing one where a database
 * is expected (e.g. glyphes_close) is GLY_ERR_STALE, the same type error a
 * statement handle gets. head is a commit id; generation is the watermark
 * generation; the two advance together and are numbered independently. */
int32_t glyphes_follower_open(char *path, GlyHandle *out_follower);
int32_t glyphes_follower_close(GlyHandle follower);
/* out_advanced is 1 when new commits were folded in, 0 when current or
 * when no watermark is available yet (poll again; attaching early is a
 * race, not an error). */
int32_t glyphes_follower_refresh(GlyHandle follower, int32_t *out_advanced);
int32_t glyphes_follower_head(GlyHandle follower, uint64_t *out_head);
int32_t glyphes_follower_generation(GlyHandle follower, uint64_t *out_gen);
int32_t glyphes_follower_lsn(GlyHandle follower, uint64_t *out_lsn);
/* Why the watermark is unavailable, or "". Same copy-immediately contract
 * as glyphes_global_error. */
char *glyphes_follower_error(GlyHandle follower);

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

    gq.nim               the GLYPH QUERY compiler: a surface line ->
                         Cypher text + parameters (PRD-GLYPH-QUERY.md)
    gbasic.nim           the GLYPH BASIC client: session, cursor, the
                         control flow (PRD-GLYPH-BASIC.md)
    gbasic_expr.nim      the client's own expressions
    gbasic_types.nim     the values a client's name can hold
    gbasic_store.nim     the in-process door: the client reaches the
                         graph only through a door (pin GB1)

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

And the GLYPH QUERY doors, which are the same surface under the names a
client that speaks the child's language uses:

```ruby
db.gq_compile("find Person where age > 30")
# => ["MATCH (n:Person) WHERE n.age > 30 RETURN id(n) AS id", "{}"]

st = db.gq("find Person")          # a Statement, with the same cells
db.link(1, "KNOWS", 2)             # => the new edge's id
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
| B11 | A GLYPH QUERY statement *is* a Cypher statement | the child's language is a surface, not a second engine: one execution path, one set of WAL semantics (B6) |
| B12 | The GLYPH QUERY doors refuse `labels` and `link` by name | each has its own door; a door that pretends to be a query is a door whose refusal is a surprise |

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
