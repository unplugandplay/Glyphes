# PRD — GLYPH BASIC: a client language for the graph

> **Status:** proposed. Companion to
> [`PRD-GLYPH-QUERY.md`](PRD-GLYPH-QUERY.md) (the data language) and
> [`discovery.md`](../discovery.md) (the reasoning that produced both).
> The coding plan is [`PLAN-GLYPH-BASIC.md`](PLAN-GLYPH-BASIC.md).

---

## 1. What this is

**GLYPH BASIC** is a small, forgiving, line-oriented language for
*using* a graph: a prompt, a session that remembers where you are, and
the control flow the query language deliberately does not have.

It is a **client**. Every statement it runs becomes a GLYPH QUERY
statement; the engine does the matching. What GLYPH BASIC adds is
everything a *client* has and a *query* has not:

| what a client needs | what the query language has |
|---|---|
| variables — "keep this node" | none (Cypher binds within one statement) |
| a conditional — "if it has a `born` property" | refused: no `CASE`, no `EXISTS` |
| a loop — "for each of these, link it" | refused: no `FOREACH`, no `UNION` |
| a session — "where am I" | none |
| a prompt | none |

That is the whole argument. The engine's language is an *expression*
language; a child needs a *program*. GLYPH BASIC is the program, and
GLYPH QUERY is the expression.

## 2. Why BASIC, specifically

The choice is not nostalgia, and it is not "because it is small". Four
properties of BASIC are exactly right for this use, and one of them is
the reason the eZ80 work happened at all.

**It is the language children already meet.** BASIC is what a child
learns on a BBC Micro, a Commodore 64, an Acorn Electron, a TI-83/84 —
and the BASIC in `ez80/` is *specifically* a Locomotive BASIC 1.0 (the
Amstrad CPC 464's), which is the 1980s children's language, with its
line numbers, its `READY` prompt and its `PRINT`.

**It is line-oriented**, which is exactly what a terminal prompt wants:
one line is one statement. No multi-line parsing, no semicolons, no
brackets, no indentation rules — the three things that make a language
hard for a beginner before the language is even interesting.

**It is forgiving.** An unknown keyword is a syntax error, never a
crash, and the interpreter is a few kilobytes. The property a child's
language needs most is that *being wrong is cheap*.

**It has the right shape for a prompt.** The BASIC in `ez80/` already has
both halves: a stored program (line-numbered) *and* an immediate
execution path (`MNIMM`), where a line that does not start with a digit
runs at once. The prompt is not a new thing to build — it is the
interpreter's other half, already working, already printing `READY`.

**And it fits in a Z80.** The interpreter is 3 091 bytes. A language
that small can be implemented twice — once on the eZ80, once in the
host — and a grammar that can only be implemented once is a script. The
eZ80 version is the *proof of smallness*, and it is also the teaching
vehicle: a child can read 3 KB of assembly and see what a program is.

## 3. The surface

A prompt, one line per statement, and the BASIC's own vocabulary for
control flow.

```
ready> find Person
  2 nodes
ready> for each p : show p : next
  1 :Person
    name Ana
    age 34
    KNOWS -> 2
  2 :Person
    name Bo
    age 41
    KNOWS <- 1
ready> add Company {name "Acme"}
  1 created
ready> for each c : link p KNOWS c : next
  linked 2
```

"For each of these, do that" is the sentence a graph prompt exists to
answer, and `for each` is how the client says it: the loop walks the
cursor and the name it binds is a node for the body's length. The
transcript above is the measured one — the same script is the golden
transcript test.

### 3.1 The statements

| statement | what it does | the GLYPH QUERY it issues |
|---|---|---|
| `find <label> [where <expr>]` | replaces the cursor with a set of nodes | `find <label> [where <expr>]` |
| `go [back] <type> [from <name>]` | replaces the cursor with the nodes one hop away | `go [back] <type> [from $n]` |
| `for each <name> [: ... : next]` | runs the body once per node in the cursor, the name holding its id | — |
| `count` | prints the size of the cursor | `count` (or the client's own count) |
| `show <name>` | prints a node: its id, its label, its properties, its edges | the introspection doors |
| `add <label> [{<prop> <value>}]` | creates a node and puts it in the cursor | `add <label> {...}` |
| `link <name> <type> <name>` | creates a relationship | `link` |
| `set <name> <prop> = <value>` | sets a property | `set` |
| `drop <name>` | deletes a node | `drop` |
| `labels` | prints the labels in the graph | `labels` |
| `help` / `?` | prints the statements | — |

### 3.2 The control flow

The BASIC's, unchanged:

| statement | what it is |
|---|---|
| `if <expr> then <statement>` | the conditional the query language refuses |
| `for <var> = <a> to <b> [step <s>]` | the counting loop the query language refuses |
| `for each <var> [: ... : next]` | the walk over the cursor — "for each of these, do that" |
| `gosub` / `return` | the subroutine: called by name, never by line |
| `print <items>` | output, with `,` and `;` as separators |
| `input` | read a line |
| `let <var> = <expr>` | assignment |
| `rem ...` | a comment |
| `end` | stop the program |

**The expressions are the client's own** (pin GB7): a number, a string, a
name, a comparison (`=` `<>` `<` `>` `<=` `>=`), `and` / `or` / `not`,
`+ - * /`, and parentheses. They are evaluated **in the client**, not by
the engine — the door is for the *graph*, and `1 + 1` is not a graph
query. Null is a value like any other and it is not true: a comparison
with null gives null, and a null condition is false (the engine's
three-valued logic, CYPHER.md §6, inherited — a language that treats
null as false teaches the wrong thing quietly).

**The program model is in.** `goto` is gone for good: a subroutine is
*named* (`SUBROUTINE. NAME.`) and called with `gosub`; `return` is the
way back, and a subroutine that falls off its end is refused by name.
`while` is the unbounded loop. The bodies are still **one line**,
separated by `:` — the separator the eZ80 BASIC already uses — and a
**multi-line** body is the next cut:

    ready> if x = 1 then print "one" : print "and the rest"
    ready> for i = 1 to 5 : t = t + i : next

**A loop inside a loop writes its own `next`.** The client groups a
nested `for` with its marker before running the outer body, so
`for a : for b : show a, b : next : next` is one statement in the outer
body rather than two — without the grouping the outer loop would take
the inner one's `next` and the inner loop would have no body at all.

**`for each` walks a copy of the cursor** and puts the cursor back
afterwards. A body that runs `go` — the natural way to look at a node's
neighbours — therefore does not disturb the walk, and a nested loop
sees the set its own entry found. The name keeps the last node
afterwards, like the counting loop's variable.

A loop that cannot finish **says so** instead of hanging: the client
is a prompt, and a prompt that hangs is a prompt that is broken.

`input <name>` reads a line, and it knows what it read: a line that
reads as a whole number is a **number**, anything else is **text** —
the BASIC's `INPUT`. The alternative (text always) would make
`input n` then `if n > 5` a *text* comparison, which is quietly wrong
rather than refused, and quietly wrong is the worst kind.

### 3.3 The program

A program is **named**, and its subroutines are **named**. There are no
line numbers anywhere, and no `goto` — a subroutine is called by its
name and comes back by its `return`, so there is nothing left that a
line number would be for.

```
PROGRAM-ID. <name>
<the main body>
SUBROUTINE. <name>
<the body>
END PROGRAM.
```

- The **main body ends the program**. There is no falling into the
  first subroutine — that trap is COBOL's, and a child's language
  should not inherit it.
- A subroutine that reaches its end **without a `return` is refused by
  name**. The same rule, the other side of the call.
- A subroutine takes **no arguments**: the session's names are global,
  which is the BASIC's way and COBOL's too.
- The trailing dot of a declaration is punctuation, not part of the
  name: `SUBROUTINE. AFFICHER_TOTAL.` and `gosub AFFICHER_TOTAL` are
  the same name.

The **prompt keeps its immediate mode** — a line runs and prints, as
before — and a program is a block the prompt collects (`PROGRAM-ID.`
starts it, `END PROGRAM.` ends it and runs it). The classic BASIC has
both modes too, and the difference is that this one's program is named
and structured rather than numbered.

**`while <expr> : <statement>`** is the unbounded loop, and it is what
`goto` used to be for. It takes the same optional `next` marker `for`
does, and the same one-million-round cap: a loop that cannot finish
says so rather than hanging.

### 3.4 The session

The BASIC's variables are 26 single letters; a graph session wants
*names*. So the session is a **name table**: `p`, `ada`, `friends` — a
symbol table, which the engine's own property dictionary
(`docs/STORAGE.md` §4) is the precedent for.

A name holds a **node id** (i64) or a **number** (i64) or a **string**.
A name that holds a node id is what `go ... from <name>` and `show
<name>` take.

**The cursor.** `find` and `go` leave a *set* of node ids in the
session, in order, and the client walks it. The cursor is a *client*
concept: the engine's pull model means the client can stop early
(`show` only wants the first row) without the engine materialising
anything.

## 4. The pins

| Pin | Rule |
|---|---|
| **GB1** | **GLYPH BASIC issues GLYPH QUERY; it never touches the store.** The client's only door is the GLYPH QUERY door (and the read-only introspection doors for `show`). A client's bug cannot corrupt the graph. |
| **GB2** | **One cursor, one concept.** The session has exactly one cursor — the current set of node ids — and every command that produces a set replaces it. There is no second "current node": the cursor is a set, and `first`/`last`/`nth` pick from it. |
| **GB3** | **The cursor is the client's.** The engine holds no cursor between statements; the client holds the ids. A client that dies holds nothing. |
| **GB4** | **A statement's writes are visible to the next statement, not to itself** — the engine's pin C4, inherited. So `add person {name "Bo"}` then `show` sees the new node ✓, and a single statement never sees its own write. |
| **GB5** | **The client is transport-agnostic.** The interpreter talks to a *door* — in-process, or a port channel — and the same grammar runs over both. This is what makes the eZ80 guest possible and what keeps the two implementations honest. |
| **GB6** | **Errors name the thing and never crash.** An unknown statement says which one; a bad value says which; a refused query passes the engine's refusal through *unchanged*. |
| **GB7** | **The client's arithmetic is 64-bit** (node ids are i64), and the eZ80 guest uses the ADL mode's 24-bit registers where it can. The host's word size is not the language's data model — the *data* decides. |
| **GB8** | **The prompt is the transaction boundary.** Each line is its own statement and its own transaction unless the client holds one open; a write is visible to the next line. |
| **GB9** | **The language is small enough to be implemented twice.** A grammar that needs a compiler to express is a script. The eZ80 guest is the check. |

## 5. The door, and the guest

The client needs exactly one ability: *send a GLYPH QUERY statement, get
rows back*. So the interpreter's core is a **transport**:

```
GLYPH BASIC (host)          → GLYPH QUERY → the engine, in process
GLYPH BASIC (eZ80 guest)    → GLYPH QUERY → the engine, over a port
```

The guest's transport is the BASIC's existing console discipline: `OUT
(port),A` to send a byte, `IN A,(port)` to read one, with a status port
to say whether a byte is waiting. The channel carries *text* — GLYPH
QUERY — and the results come back as text too (ids and property
values rendered by the client).

**The honest limit:** a guest client pays the *emulator's* ~2 ns per
T-state plus a round trip per byte, so it is far slower than the engine
answers a query (about 10 µs). The guest is therefore the **teaching
vehicle and the proof of smallness**, not the production path. The host
client is what a real user types.

## 6. What is out of scope

- **Unbounded text on the guest.** Text is a first-class value on both
  sides now: a name can hold it, `+` concatenates it, the comparisons
  have the host's case rules, and a text and a number are not equal.
  The guest copies text into a fixed 1 KB arena (a length byte and the
  bytes); a program that makes text faster than it forgets it is
  refused with `?` rather than allowed to overwrite a name. That bound
  is the machine's, not the language's, and it is stated where the
  guest is.
- **Functions and procedures.** `gosub` is enough for a first language,
  and a call stack in the guest is a lot of memory. The host version may
  add `def`.
- **Multi-line bodies.** The program model (§3.3) is in, with named
  subroutines and `goto` gone for good — but a loop whose body is the
  *lines that follow* is not, and needs the indentation or the
  `END-IF` convention that the one-line bodies avoid.
- **The eZ80 guest's remaining half.** The guest now has the names,
  the expressions (arithmetic, text and the comparison operators),
  `and`/`or`/`not`, `show`, `go`, the three loops (`for`, `for each`,
  `while`), `if … then` with the host's line/piece body rule, and the
  writes `add`, `link`, `set` and `drop`; its transcript matches the
  host client's byte for byte on the script that covers them (GB-F).
  Still missing, and refused by name rather than ignored: `input`,
  `gosub`/`return` and the program model. A write the *host* refuses
  (`!`) prints the guest's one-word `?`, because that is its whole
  refusal vocabulary. Its expressions are word-shaped (`1 + 2`, not
  `1+2`) and its numbers are 16-bit, so its `while` guard stops at 65,535
  rounds rather than the host's million — the divergences the guest's
  size buys, documented where the guest is.
- **Replacing the Ruby model layer.** GLYPH BASIC is a *client*; the
  model layer is a *client*. They are peers, and the model layer stays.

## 7. The gates

| Gate | What it proves |
|---|---|
| **GB-A** | The interpreter's statements produce the expected **transcript**, golden file, byte for byte — the same discipline the eZ80's BASIC transcript uses. A language's output is a transcript, not a test count. |
| **GB-B** | The transcript is **identical** whether the client talks to the engine in-process or over the *port channel* — the two transports are the same language. |
| **GB-C** | Every refusal names the construct: a table of bad client lines and the message each produces. |
| **GB-D** | A client value never reaches the query text (with GQ-C). |
| **GB-E** | The client's arithmetic is 64-bit: a node id above 2³¹ round-trips ✓ (the guest's 24-bit limit is documented, not inherited). |
| **GB-F** | The eZ80 guest, when it exists, produces the **same transcript** as the host client (pin GB9). |

## 8. The risk, stated

**A BASIC that is a shell for Cypher is not a language.** The defence is
GB1 and the transcript: the client's value is in what it *is* — a
session, a cursor, control flow, a printed node — and none of that is
in Cypher. If a future GLYPH BASIC were only `find`/`go` with different
words, it would be a veneer, and the test for that is whether removing
the control flow would lose anything.

**The other risk is scope creep towards a real programming language.**
The first version has no functions, no strings-as-values and no
aggregates, and each of those omissions is deliberate: a language that
grows a type system stops being a language a child can hold in their
head, and that is the only property this one is for.
