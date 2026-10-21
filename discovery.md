# Discovery — what a graph query language for children inherits from a BASIC
> on an eZ80

> *The record of what was proposed, what was checked, and what the checking
> found. Written before the implementation, revised after it, and kept
> because the sequence of wrong turns is more useful than the final shape.*

**Status:** discovery. It proposes a shape; it does not specify one.
The companion that would specify it does not exist yet.

This is written in the first person deliberately, for the reason
[`docs/DISCOVERY-SHARED-MODE.md`](docs/DISCOVERY-SHARED-MODE.md) gives:
this document's job is to be honest about a specific failure mode — a
design that sounded right, was checked against the code, and turned out to
be wrong in ways that only running it could show.

---

## 1. The arc, in the order it happened

**The request.** Turn the Z80 emulator into an eZ80; then benchmark a
million BASIC iterations; then benchmark the same loop in Z80 assembly;
then the same loop in native code. All of it done, and all of it in
`ez80/`.

**Then the real reason surfaced**, and it reframed everything above: the
BASIC is not a toy. It is the candidate for a *graph query language* — a
`psql`-like prompt over the graph, in a language a child could play with,
where you can "chase with nodes". The eZ80 and the BASIC are the
*evidence* for that idea, not the deliverable.

**What the work had already found** (the eZ80 and the BASIC arc):

- The BASIC had never been run to completion. Running it found **nine
  defects in the BASIC** and **three in the eZ80** — every one of them a
  "where am I" mistake.
- The BASIC's interpreter loop **is** a `psql` prompt: read a line, match
  a keyword, execute, print `READY`, read again. The prompt is not a
  feature to add; it is the shape the thing already has.
- The BASIC's cost is **entirely** its dispatch: 3 898 T-states per `NEXT`
  against 26 for the same loop in machine code, and 132× on the wall
  clock. The interpreter is 127× slower than the code it interprets, and
  the gap is a seventeen-entry linear keyword scan.

**What the graph engine says** (checked against the tree, not assumed):

- The engine is **fast**: 92 000–97 000 single-hop queries/s over 10⁶
  nodes, 65 µs for a 2-hop (`docs/ROADMAP.md`, pin C9). A single query
  costs about as much as **one** interpreted BASIC statement.
- The query language is **narrow on purpose**: nineteen Cypher
constructs are refused *by name* (`docs/CYPHER.md` §5) — no
  joins, no cartesian products, one label per node, no path binding, no
  `CASE`, no `EXISTS`, no `FOREACH`, no `UNION`.
- The surface is **already complete enough**: the ABI has
  `glyphes_prepare` / `glyphes_stmt_step` / `glyphes_stmt_columns`, the
  cell accessors (text, id, path), and the introspection calls
  `glyphes_node_labels`, `glyphes_node_props`, `glyphes_edge_info`,
  `glyphes_edge_props` (`src/glyphes.h`).
- A row **can be a node**: the Ruby `Statement` cell answers `node?`,
  `edge?`, `value`, `to_s`, `path` (`lib/glyphes/statement.rb`). So
  "show me this node" is a *printing* problem, not a *query* problem.
- There is **no query prompt at all**: the `glyphes` CLI has exactly one
  subcommand, `follow` (`bin/glyphes`). A `psql` for the graph does not
  exist and would have to be written.

---

## 2. Where reality disagreed with the design

Every row is a claim that was checked against the tree, the manual or the
clock before being believed. Several did not survive.

| claim | reality | where |
|---|---|---|
| "the BASIC is a game; the eZ80 was a detour" | the BASIC's interpreter loop is a REPL with a prompt (`READY`), variables (a session), and line-oriented statements — the three things a `psql` needs | `ez80/basic.z80` |
| "the engine is the slow part" | the engine does ~100 000 queries/s (10 µs each); the *interpreter* does 127 000 statements/s — the language layer and the engine are the same order of magnitude, and the engine is the faster of the two | pin C9, `ez80/bench` |
| "a graph query language needs joins to be useful" | joins are *refused*; a chase is a **chain**, which the engine already does in one pattern with any number of hops — the language's central motion is the one the engine is built around | `docs/CYPHER.md` §0.1, §5 |
| "a child-language needs the engine to grow first" | the ABI already has everything a prompt needs: prepare/step/columns, cell ids, node labels, node properties, edge info, edge properties, schema, index list | `src/glyphes.h` |
| "the BASIC's 16-bit integers are a problem for a graph language" | they are — but the eZ80's **ADL mode** makes the registers 24-bit and the address space 16 MB, and the engine's fixture is 10⁶ nodes, so a 24-bit id holds every node in the test corpus | `ez80/ez80.nim`, `docs/STORAGE.md` §7 |
| "the BASIC's 127× overhead is a BASIC problem" | it is a *dispatch* problem, and it is the first thing a graph language must get right: a hashed or switch-dispatched verb table is a day's work | `ez80/bench/bench.nim` |
| "the psql analogy means rows" | a graph's unit is the *node*, and a row can *be* one; a `psql` that returns rows is the wrong shape for chasing | `lib/glyphes/statement.rb` |
| "the language would sit *above* Cypher" | it has to sit *beside* it and use it as the wire format for the graph work: the engine speaks Cypher and nothing else, and re-implementing matching in a new language is a second implementation of the hardest part | `src/cypher/` |
| "the eZ80 could host the language" | it can, and it should — but a guest BASIC talking to the host over a port pays the *emulator's* ~2 ns per T-state and a port round trip per value, which puts the guest far behind the engine for anything interactive | `ez80/bench` |

---

## 3. What the BASIC actually is, now that it runs

The interpreter is a few kilobytes of Z80 assembly (the whole image,
interpreter included, is 3 091 bytes), and its shape is the argument for
it as a query language:

| BASIC feature | what it is in a query language |
|---|---|
| a line is a statement | one line is one command — no multi-line parsing, no semicolons, no brackets |
| `READY` after every line | the prompt |
| 26 single-letter variables | the session's state; in a graph language these are *the current node* and friends |
| `IF … THEN` | the conditional the query language refuses to have (`CASE`, `EXISTS`) |
| `FOR … NEXT` | the loop the query language refuses to have (`FOREACH`, `UNION`) |
| `GOSUB` / `RETURN` | sub-commands |
| `PRINT` | the row printer |
| `INPUT` | the argument reader (the `psql` `\d` prompt) |
| `POKE` | the escape hatch — and the engine's own name for raw access |
| unknown keyword → `?SYNTAX ERROR` | forgiving, never a crash |

And the limits, which a graph language must not inherit:

- **16-bit signed integers** (ceiling 32 767) — the eZ80's ADL mode
  removes this for a guest; a host implementation has no excuse.
- **No strings as variables** — and a graph language is *made* of names.
  This is the single hardest gap between the BASIC as it is and the
  language it wants to become.
- **No floats** — fine, a graph's ids and counts are integers.
- **Uppercase only** — fine, and it is a kindness to a six-year-old
  typist.
- **Line-numbered** — the BASIC is a *stored program* first. But it
  already has the second mode a prompt needs: `MAIN` reads a line, and a
  line that does **not** start with a digit is executed immediately
  (`MNIMM`), unnumbered and unstored. The prompt is not a new thing to
  build; it is the interpreter's other half, already working.

---

## 4. The nine BASIC bugs are the specification of "finished"

Every one of the nine was a **cursor** mistake, and every one of them
would have been a bug in a query language too:

| BASIC bug | what it is in a query language |
|---|---|
| `TOEOL` never wrote the cursor back | the parser's position after a comment |
| the executor pointed at `ENTRY+1` (the line number) instead of `ENTRY+3` (the text) | the parser's position on the *second* line of a program |
| the program store advanced by the *position* instead of the *size* | the store's end pointer after an insert |
| `FINDLINE` stepped back two bytes on one path and one on the other | a lookup that reads a length from the wrong place |
| `NEXT` restored the text cursor but not the line pointer | a loop that steps past the end instead of back to its body |
| the comparison operators stored the *character* instead of their code | `AND`/`OR`/`NOT` that quietly compare the wrong thing |
| the `IF` handler tested the flags *after* popping the condition | a true condition read as false — the *worst* possible bug in a language whose whole job is conditionals |
| `INPUT` stored the cursor as the number typed | a value confused with a position |
| the `GOSUB` stack check compared only the high bytes | a limit check that refuses the first call |

**The lesson for the design:** a small language has exactly one hard
problem — *knowing where you are* — and it must be solved **once**, in one
place, and every command must go through it. The BASIC solved it nine
times, differently, and got eight of them wrong.

The second lesson is from the measurement: the language's *cost* is its
dispatch, and the fix is a table lookup, not cleverness elsewhere.

---

## 5. The discovery: a query language and a client language are
## different languages, and the BASIC is the second one

Cypher is an **expression** language. It has no variables, no control
flow, no session. Everything it cannot do, it refuses by name: no
`CASE`, no `EXISTS`, no `FOREACH`, no `UNION`, no joins.

A child's language for a graph needs precisely those things:

- "keep this node, and show me its friends" — a **variable**;
- "if it has a `born` property, show that" — a **conditional**;
- "for each of these twenty nodes, link them to this one" — a **loop**.

The BASIC has all three, natively, and they are *the* reason the eZ80
work matters. A language that sits above the engine does not need to
re-implement matching, or the planner, or the index seeks, or the
transaction rules. It needs to:

1. hold a **cursor** over a result (a set of nodes), and
2. drive the engine in small steps, and
3. print what it finds.

That is not a query language. It is a **client** language — and the BASIC
is one, already written, already debugged, and already 3 KB.

**So the shape the work points at is two languages, not one:**

- **GLYPH QUERY** (the engine's): the existing Cypher subset, used as the
  wire format, not as the user-facing language. It stays exactly as it is.
- **GLYPH BASIC** (the user's): a line-oriented, forgiving, session-
  holding client language with a `psql`-shaped prompt, whose commands
  compile down to single engine calls.

The child types:

```
ready> find person
  2 people
ready> p = first
ready> show p
  3 :Ada, age 36
ready> go knows from p
  1 :Bo
ready> count
  1
```

and what happens underneath is `MATCH (n:Person)`, `MATCH (n) RETURN n LIMIT
1`, `MATCH (a)-[:KNOWS]->(b) WHERE a = $p`, and a `MATCH (n:Person) RETURN
count(n)`.

**Why the engine does not have to change for the first version:** every
command above is a *single* Cypher statement plus a client-side
iteration. `find` is one `MATCH`. `show` is one `MATCH` by id plus the
introspection calls (`glyphes_node_labels`, `glyphes_node_props`).
`go` is one `MATCH` with the current node as a parameter. `count` is one
`MATCH … RETURN count(n)`. The *client* provides what Cypher refuses:
the loop, the conditional, the variable.

---

## 6. The design sketch, and what each piece leans on

### 6.1 The surface

A prompt, one line per command, an optional `:` to continue a line (the
BASIC already uses `:` as its statement separator), and a `?`/`help`
command. The prompt word should be the BASIC's own: **`ready>`**.

### 6.2 The session

The BASIC has 26 single-letter variables; a graph session wants *names*
(`p`, `ada`, `friends`). Two routes:

- **Host implementation** (Ruby or Nim, in-process): names are free — a
  hash. The engine's own property dictionary (`docs/STORAGE.md` §4) is the
  precedent for interning them.
- **Guest implementation** (the eZ80): the BASIC has *no string
  variables*, so names would have to live in a string arena, and the
  eZ80's 16 MB (ADL mode) is more than enough for it. This is the
  largest single piece of work in the guest, and it is the price of the
  guest being a guest.

### 6.3 The verbs

A small set, each one engine call, each one a Cypher statement:

| verb | what it does | the engine call |
|---|---|---|
| `find <label> [where …]` | a cursor over nodes of a label | `MATCH (n:<Label>)` |
| `go <type> [from …]` | chase one hop — the centre of the language | `MATCH (a)-[:<TYPE>]->(b)` |
| `show [n]` | print a node: label, id, properties, and its edges | `MATCH (n) WHERE id(n)=$id` + `glyphes_node_props` |
| `count` | how many in the cursor | `MATCH … RETURN count(n)` |
| `where <prop> <op> <value>` | filter the cursor | the same `MATCH`, re-planned |
| `add <label> [props]` / `link a <type> b` / `set n <prop> = <v>` / `drop n` | the writes | `CREATE` / `MERGE` / `SET` / `DELETE` |
| `history` / `diff` | what changed — the engine's own superpower | the versioning surface (`docs/PRD-VERSIONING.md`) |

Two of these deserve the child's attention, because they are things the
engine has that Cypher does not express well: **`show`** (a node
*printed*, with its properties and its edges — the `psql` `\d` of a graph)
and **`history`** (the durable version history — the follower's
`followDiff` idea, `docs/FOLLOWER-SURFACE-PLAN.md`).

### 6.4 The printing, which is the whole "chase" experience

A row can *be* a node (`lib/glyphes/statement.rb`). So the printer
decides what a node looks like:

```
3 :Ada
  age 36
  knows -> 4 :Bo
```

That is `glyphes_node_props` and `glyphes_edge_info` — the calls that
already exist. **No engine change is needed to print a node well.** The
introspection calls are there today for other reasons; a child-facing
language is simply the first caller that wants them for *showing* rather
than for bookkeeping.

### 6.5 The rules that make it feel small

- **One line, one command.** No multi-line syntax, ever.
- **A command is one engine call.** No batching, no pipelines, no
  sub-queries. Every command can be explained in one sentence.
- **The client loops, the engine matches.** The engine's pull model
  (`docs/EXEC.md` §0) means the client can walk a cursor a row at a time
  and stop early — which is what `LIMIT` and `show` want.
- **Errors name the thing.** The engine's rule (pin C1) already is: refuse
  by name, never approximate. A child-facing language inherits that
  exactly — `?SYNTAX ERROR` style, but naming the command.
- **The prompt decides the transaction boundary.** Each line is its own
  statement; the engine starts one unless a transaction is open (pin
  C4), and the ABI has `glyphes_tx_begin` / `_commit` / `_rollback` if the
  prompt wants to hold one across lines. A write is then visible to the
  *next* line and not to itself — which is what a REPL wants.

---

## 7. Where the eZ80 fits, honestly

**It is the teaching vehicle and the proof of smallness, not the
production path.** The numbers say so:

| | wall clock | per iteration | T-states |
|---|---|---|---|
| GLYPHE BASIC, interpreted | 7.47 s | 7 474 ns | 3 898 |
| the same loop in Z80 assembly | 0.056 s | 56 ns | 26 |
| the same loop in native code | 0.001 s | 0.5 ns | — |

A guest BASIC driving the engine pays the *emulator's* ~2 ns per T-state
and a port round trip per value. The engine answers a query in 10 µs; a
guest would spend longer *asking* than the answer costs. So:

- the **language** is the deliverable;
- the **eZ80 BASIC** is where it is implemented first, because a language
  small enough to fit in 3 KB of Z80 assembly is small enough to be
  taught — and because the guest version *forces* the language to stay
  small (no strings, no floats, one label per thing), which is the
  discipline the language needs anyway;
- the **host prompt** (Ruby or Nim, in-process) is what a real user
  types, and it is a *port* of the same grammar, not a different
  language.

The two implementations are also the test: a grammar that can be
implemented twice — once on a Z80, once in Ruby — is a grammar, and a
grammar that can only be implemented once is a script.

---

## 8. What the eZ80 work says about how to build the language

Ten findings, and each one is a rule for the implementation:

1. **Dispatch in O(1).** The BASIC's seventeen-entry linear scan is why
   it is 127× slower than the machine code. A verb table keyed by a
   first character, or a switch, is the difference.
2. **One cursor concept, in one place.** Eight of the nine BASIC bugs
   were "where am I".
3. **Positions are sizes, not offsets.** The program store's bug was
   advancing by a position instead of a size.
4. **Never test a flag after overwriting it.** The `IF` bug: the
   condition's flags were tested after the value was popped.
5. **Store codes, not characters.** The comparison-operator bug.
6. **A value is not a position.** The `INPUT` bug.
7. **Compare whole values.** The `GOSUB` limit check compared half a
   16-bit value.
8. **Write the cursor back.** The `REM` bug.
9. **The host's word size is the language's data model.** 16-bit
   integers → 32 767. Pick the language's widths on purpose.
10. **Prove compatibility with a transcript, not a test count.** The
    golden BASIC transcript is byte-for-byte identical between the Z80
    and the eZ80 — a stronger statement than any number of assertions.

---

## 9. The open questions, and the next things to check

1. **Strings.** The single hardest gap. The host has them; the guest
   does not. Does the language need a string *type*, or only string
   *literals* in commands? A child typing `find person "Ana"` needs
   literals; a session holding `ana = find person "Ana"` needs a type.
2. **The one-label rule.** Pin C13 says a node carries exactly one
   label. For a child that is arguably a *feature* ("a thing is one kind
   of thing") — but `find person who is also a teacher` cannot be
   asked. Is that acceptable? The store's structures assume it, so this
   is an engine question, not a language one.
3. **Paths.** Path binding is refused in Cypher, so "show me the path I
   took" is client-side. Does the client accumulate it, or does the
   language grow a `path` concept?
4. **Writes.** `add`, `link`, `set` are one statement each, so a batch
   update is a *loop of statements* — slow (one transaction each) but
   correct and explainable. Is that the right trade for a child?
5. **The follower and the history.** `history` and `diff` are the
   engine's most distinctive capabilities and they have no spelling in
   any query language. They are the best candidates for a command a
   child would love, and they need the structured timeline reads
   (`docs/FOLLOWER-SURFACE-PLAN.md`) to exist on the ABI first.
6. **What "psql" gets wrong.** `psql`'s unit is the relation and its
   unit of work is the transaction. A graph's unit is the node, and the
   prompt's real state is *where you are*. The prompt should feel like
   walking, not like a table.

---

## 10. Where this leaves the product

The claim this document makes is narrow and checkable:

> A graph query language for children does not need a new *query*
> engine. It needs a new *client* language — one with variables,
> conditionals and loops — over the engine that already exists, and a
> printer that shows a node as a node.

Everything the eZ80 and BASIC work contributes to that claim:

- the **shape** (a line, a prompt, a session, a `READY`) ✓;
- the **cost model** (dispatch is the language, 127×) ✓;
- the **correctness checklist** (nine cursor bugs, each one a rule) ✓;
- the **proof of smallness** (3 KB of Z80 assembly, 16 MB of address
> space, 24-bit registers) ✓;
- the **measurement** (the engine is 100 000 queries/s; the language must
  not be the bottleneck) ✓.

And the one thing it does not yet contain: a grammar. The next artifact
should be a page of GLYPH BASIC commands with their engine calls, written
against the verbs in §6.3, and then a host-side prompt that runs them —
because the first version of a language should be *typed at*, and the
eZ80 version is the one that comes after.
