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
