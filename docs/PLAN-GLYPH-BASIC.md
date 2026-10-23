# PLAN — GLYPH BASIC: the coding plan

> Companion to [`PRD-GLYPH-BASIC.md`](PRD-GLYPH-BASIC.md). The plan for
> the data language is [`PLAN-GLYPH-QUERY.md`](PLAN-GLYPH-QUERY.md).
>
> **This plan and that one are cut from the same cloth.** GLYPH BASIC
> issues GLYPH QUERY, so the client needs the data language's grammar to
> exist — but not its *code*, because the client talks to the *door*.
> That is what lets the two be built at the same time: the client is
> written against a door, and the door is filled in behind it.

---

## 1. The shape of the work

| # | Cut | What it delivers | Gate |
|---|---|---|---|
| **B1** | the grammar, on paper | the statements, the values, the refusals — the *client's* language, in full | a review |
| **B2** | the interpreter core | the session, the cursor, the statements, the transport | GB-A, GB-C |
| **B3** | the prompt | the `READY>` loop, the transcript, the errors | GB-A |
| **B4** | the in-process door | the client talking to the engine | GB-B, GB-D, GB-E |
| **B5** | the eZ80 guest | the same language on the eZ80, over a port channel | GB-B, GB-F |

**B5 is a separate cut with its own plan**, because it is a second
implementation of the same grammar and the interesting part of it is the
*transport*, not the language. It is listed here so the dependency is
visible, and it is scheduled last ✓.

## 2. B1 — the grammar, before the code

A page, in `docs/`, that fixes:

- the **statement table**: every client statement, its operands, and the
  GLYPH QUERY it issues (the PRD §3.1 table is the draft);
- the **value rules**: what a literal may be, and what a *name* may
  hold (a node id, a number, a string);
- the **control flow**: `if`, `for`, `goto`, `gosub`, `print`, `input` —
  the BASIC's, spelled out;
- the **refusal table**: every malformed client line and the message it
  produces.

**The two rules that decide the language:**

1. **A client statement is either a GLYPH QUERY statement or a control
   statement.** There is no third kind. `find person` is GLYPH QUERY;
   `if … then …` is control; a line that is neither is a refusal that
   names both possibilities.
2. **A name in the session is a value; a name in a GLYPH QUERY
   statement is a parameter.** The client resolves names to values
   *before* issuing, so GLYPH QUERY never sees a client-level name
   (pin GB1, pin GQ4).

## 3. B2 — the interpreter core

New module `src/gbasic/`:

| File | What it holds |
|---|---|
| `src/gbasic.nim` | the client: the session (the names, the cursor), the values, the statement loop, the printing |
| `src/gbasic_store.nim` | the in-process **door** — the one implementation of the transport |
| `tools/glyphbasic.nim` | the prompt: `glyphbasic <database>` |

The door is a set of **callbacks** rather than a class with methods:
Nim does not allow method declarations inside an object, and a class
hierarchy would be the wrong shape anyway — the guest transport is not
a subclass of the in-process one, it is a different way to reach the
same engine.

**The transport is the seam that makes B5 possible** (pin GB5): the
interpreter never touches the engine. It *issues GLYPH QUERY* and gets
rows back. The in-process transport calls the GLYPH QUERY door; the
guest transport writes the line to a port and reads the answer.

**The cursor is a list of ids** (pin GB2, GB3) — the client holds them,
the engine holds nothing between statements ✓. `show` wants one node, so
the client asks for one row and stops ✓ — the engine's pull model means
nothing is materialised ✓.

**The printing is the "chase" experience**, and it is worth getting
right: a node prints as its id, its label and its properties, and its
edges as `type -> other` ✓ — using the engine's *read-only
introspection* doors (`glyphes_node_props`, `glyphes_edge_info`) ✓,
which the ABI already has ✓✓.

**The control flow, as it came out.** Two modules, because the
expressions and the statements both need the *values* and a cycle
would not do: `src/gbasic_types.nim` holds the value kinds, and
`src/gbasic_expr.nim` holds the evaluator, which works on the session's
*names* rather than on the session — so the evaluator and the client
never import each other.

The grammar, as shipped:

    if <expr> then <statement>[: <statement>...]
    for <var> = <a> to <b> [step <s>] : <statement>... : next
    input <name>
    print <expression>
    <name> = <expression>

Bodies are **one line**, separated by `:`. The reason is the program
model, not the effort: `goto` names a line, and a client line has no
number — it has a position in a session — so subroutines and
multi-line bodies wait for the client to hold a numbered program, and
they wait together (PRD §3.2).

Two details that are worth their own line, because both were bugs
before they were rules: the right-hand side of an assignment is the
**rest of the line** (`t = t + 1` — taking the third word alone quietly
drops the `+ 1`), and a loop that cannot finish **refuses** after a
million rounds rather than hanging.

## 4. B3 — the prompt

- The `READY>` loop: read a line, run it, print the result, print
  `READY>` again ✓ — the BASIC's own prompt word ✓.
- The **transcript** is the artefact (GB-A): a golden file, byte for
  byte ✓ — the same discipline the eZ80's BASIC transcript uses ✓✓.
- The errors: a refusal prints the message and the prompt returns ✓;
  nothing crashes ✓ (pin GB6) ✓.

## 5. B4 — the in-process door

The transport implementation:

- in-process: compile the GLYPH QUERY line, run it through the GLYPH
  QUERY door, and keep the rows;
- the *introspection* calls for `show`.

**GB-E (64-bit arithmetic)** is checked here: a node id above 2³¹ must
round-trip ✓ — the client's values are i64 ✓, and the *eZ80 guest* is
where the narrower register shows up ✓ (documented, not inherited ✓,
pin GB7).

## 6. B5 — the eZ80 guest

The second implementation, and the reason pin GB9 exists. Its plan:

| # | Cut | What it delivers |
|---|---|---|
| **E1** | the channel | a port discipline: send a line, read a reply, with a status port ✓ |
| **E2** | the transport | the GLYPH QUERY line goes out; the ids come back ✓ — the guest needs *no* compiler ✓ |
| **E3** | the grammar | the same statements, in Z80 assembly — the interpreter's *other* half |
| **E4** | the transcript | **the same transcript as the host client**, byte for byte (GB-F) ✓ |
| **E5** | the client's own half | the names, the expressions, `show`, `go` and both loops — the grammar the prompt writes ✓ |
| **E6** | the writes | `add`, `link`, `set`, `drop` and `rem` — the channel's `exec` and `link` verbs, and the mark moves to 4 KB ✓ |
| **E7** | the conditional | comparisons (`= < > <= >= <>`) and `if … then`, with the host's line-level-versus-piece body rule ✓ |
| **E8** | the unbounded loop | `while … : … [next]`, line-level like the host's, with the after-`next` statement and the guest's 16-bit round guard ✓ |
| **E9** | the values | quoted text and yes/no: a kind byte per name, a 1 KB text arena, text `+` and the host's case rules, `and`/`or`/`not`, and the mark moves to 6 KB ✓ |
| **E10** | the input | `input <name>`: strip both ends, all digits is a number, anything else text, in a buffer of its own ✓ |

**What E1 and E2 are, as shipped.** The channel is three ports: the
guest writes a request to port 3 and ends it with CR; the host answers;
the guest reads the answer from port 4 after polling port 5. The
*request* is one line, so one CR ends it; the *answer* is a run of
lines, so it ends with an empty one — a guest that cannot tell where
an answer stops is a guest that will print the next answer's first
byte as part of this one.

The host's end is `src/gbasic_channel.nim`, and its vocabulary is
deliberately small — the guest has to *parse* the answers, and a guest
that parses JSON is a guest that needs a JSON parser in 6 KB of
assembly:

| request | answer |
|---|---|
| `gq <line>` | the ids it matched, comma-separated |
| `exec <line>` | how many entities the write touched |
| `props <id>` | the label, then `key value` per property |
| `edges <id>` | `TYPE -> other` / `TYPE <- other` per edge |
| `link <a> <t> <b>` | the new edge's id |

A `gq` request may carry parameters after a TAB, as `name=value`
fields: the guest's names hold node ids, and a value is a parameter on
this side of the channel just as it is on every other side (pin GQ4).
An answer that begins with `!` is a refusal, and the rest is the
message. The guest does not parse that message: it prints its own `?`
and abandons the line. A refusal the guest can see is the point; the
host's words stay the host's, and the one-word vocabulary is one of the
guest's documented divergences (the others are the word-shaped
expression and the 16-bit `while` guard).

**The guest sends GLYPH QUERY, not Cypher** ✓ — so the guest needs no
Cypher compiler, and the host compiles ✓ (which is the point ✓: the
language is small enough to *send*, and the engine's is not).

**What E3–E10 are, as shipped.** The guest is `ez80/gbasic.z80` —
GLYPH BASIC in Z80 assembly, 5,413 bytes for the grammar it covers. It
reads a line, splits it into words and statements, runs them, and sends
a GLYPH QUERY line over the channel for the graph work; the answer comes
back and it prints what the host client prints.

The statements it covers are `find`, `count`, `labels`, `end`, `rem`,
`let` and the bare assignment, `print`, `show`, `go`, `if … then`,
`while … : … [next]`, `for`, `for each`, and the writes `add`, `link`,
`set` and `drop`; the expressions are `+ - * /`, `and`/`or`/`not` and
the comparisons `= < > <= >= <>` over numbers, quoted text and yes/no
values. That is the grammar the prompt sketch writes — the client's
*own* half, as opposed to the graph work the host does.

The writes needed no new channel vocabulary: `add` forwards its
property list as the host forwards it (`gq add Company {name "Cid"}`,
the host still the parser), `set` and `drop` send parameterised `exec`
lines with the id and the value after a TAB, and `link` is the verb the
engine's no-joins rule has always needed.

The conditional brought the host's subtlest rule with it, and the guest
implements the rule rather than a guess: at the *line* level an `if`
owns the rest of the line, because the host hands it the rest of the
string; inside a body the host hands it one piece, so it owns only its
own tail. `LEVEL` (how many `RUNFROM` frames are open) is the
difference, and the transcript's nested-if and for-body cases are the
proof.

The unbounded loop reuses the same machinery rather than adding a
second kind of loop: its condition is a word range and its body another,
found by the same `FINDBODY` that gives `for` its body, with the
statement after the `next` run once at the end. It is line-level by
construction — a `while` piece inside a body has no colon after its
condition, and the host refuses it; `LEVEL` gives the guest the same
refusal rather than a second grammar. The round guard is 16 bits (the
guest's register width) rather than the host's million; the transcript
reaches neither.

The value model is E9's, and it is the host's rather than a simpler
one: each name slot has a kind byte beside its 16-bit value (0 number,
1 text, 2 yes/no), and each expression result carries the same kind in
`RK`. A quoted word is copied into a 1 KB arena (a length byte, then
its bytes) so a name can outlive the line it was read on; `+` is text
concatenation when both sides are text and arithmetic when both are
numbers, mixed kinds are refused for arithmetic and unequal for
equality, text ordering ignores case while text equality does not, and
a text is false only when empty. `and` and `or` are eager, as the
host's evaluator is; `not` binds looser than a comparison. A full arena
is a refusal (`?`), never a silent overwrite.

`input` is the console's own door, and it gets a buffer of its own
(`INBUF`): the line being executed, or a loop body still to run, must
not be overwritten by the line being typed. It strips both ends, reads
an all-digit line as a 16-bit number and everything else — empty, a
sign, a word — as text, which is the host's rule. A program that types
text into `input n` and then asks `n > 5` gets a mixed-kind refusal, not
a quiet numeric comparison, because `n` really is text.

What the guest cannot do it does not pretend to: `gosub` and `return` are
not implemented and are refused by `?`, an unknown name is refused
rather than created, and an answer the host refuses (`!`) is a refusal
the guest prints in its own one word. A quoted string that is
unterminated, a text used as a node id, a text added to a number, and
`input` with the wrong number of words are all refused rather than
half-read.

Three things make it the client rather than a remote control, and all
three are E5's:

- **the name table** — eight names of seven characters, each with a
  16-bit value and a kind; a number in an expression may be a literal or
  a name;
- **the statement table** — the line is tokenized once, and a statement
  is a *range of words* (`STARTS`); the loop body is therefore a range,
  and re-running the body is re-running the range, with no re-scan and
  no second copy of the text;
- **the loop's per-depth state** — the body's range, the cursor's copy
  and the walking offset are kept per open loop, so a nested loop keeps
  its own `next` and its own walk (the host's rule).

What the guest still does not have is in PRD §6, and it is *refused*
rather than ignored: an unknown statement prints `?` and abandons the
line; a statement with trailing words the guest does not understand is
refused rather than half-run; `gosub` and `return` are refused;
an expression is word-shaped (`1 + 2`, not `1+2`), because the guest
tokenizes into words and has no character-by-character parser. The
refusal vocabulary is the guest's one-word `?` — the host's messages are
longer, and that is a documented divergence, not an accident. The
`while` guard is the guest's 16-bit register: it stops after 65,535
rounds where the host stops after a million. The number differs because
the register does; the promise — a runaway loop is refused, not hung —
is the same. The text arena is finite in the same honest way: a program
that makes text faster than it forgets it is refused, not corrupted.

The transcript gate's script covers exactly this cut: `let` and the
bare assignment, `print` of a name, an expression, a text and a yes/no,
`find` and `print` of the cursor, `for each` walking the cursor with
`show`, `go ... from` a name, `count`, `labels`, the counting loop,
every comparison operator, text equality and case-insensitive ordering,
empty-text truthiness, `and`/`or`/`not` with their precedence, a yes/no
compared with itself, `if` at the line level and inside a body
(including the nested-if piece rule), `while` with a body, a `next`,
statements after the `next`, and a `for` inside its body, and the writes
(`add` and its cursor, `link`, `set` with a number, a text and a yes/no,
`drop`) with a `rem` in front of them. `input` has its own
host-vs-guest test, because its typed lines are interleaved with the
statements. `gosub`/`return` and the program model are not in it, and
the guest says so by refusing them — a gate that claims more than it
checks is a gate that rots.

**E4 is the gate, and it is a byte-for-byte comparison**: the same
script runs on the host client and on the guest, and the two transcripts
must be identical. The fixture is the same graph for both, so the ids
are the same ids. It is the same discipline as the eZ80 BASIC's golden
transcript ✓ — *the same work, two ways, compared* ✓.

Two things the guest learned the hard way, and both are the client's
rules rather than the guest's:

- **A request is built from parts and ends once.** The guest sends
  `gq find ` and `Person` as two parts and one CR at the end; a CR
  after each part is two requests, and the compiler's answer to the
  second one is "a GLYPH QUERY statement is one line" ✓.
- **The answer's lines are NUL-separated and end with an empty line**,
  because the guest has to know where an answer stops ✓.

**E3 is where the size of the language is proved.** The first half
(the names, the expressions, `show`, `go`, both loops) fitted in 3 KB;
the writes took the guest past it, so the published mark moved to 4 KB —
deliberately, with the number in the plan and the ceiling in the test.
The conditional then landed at 3,956 bytes, and `while` at 4,087. The
value model (text, yes/no, `and`/`or`/`not`) took the guest past 4 KB, so
the mark moved again to 6 KB, and the cut landed at 5,230 bytes; `input`
landed at 5,413, still inside it. Each move is a measurement, not a
silent drift: a mark that never moves is a mark nobody measured. The
point of the instrument stands — if the grammar cannot be written twice,
it is too big, and the host client has taught us that by being too big.
That is the honest use of the guest: not a production path, a *measuring
instrument* ✓.

## 7. The tests

New file `tests/unit/test_gbasic.nim`:

| test | what it holds |
|---|---|
| the transcript | a scripted session produces the golden transcript, byte for byte (GB-A) ✓ |
| the helpfulness | a label that matches nothing says which labels there are (the case is exact, and silence would read as "there is nobody here") ✓ |
| the refusals | every bad client line produces the message the table names (GB-C) ✓ |
| the parameters | a client value never reaches the query text — checked at the transport boundary (GB-D) ✓ |
| the arithmetic | a node id above 2³¹ round-trips (GB-E) ✓ |
| the cursor | `find`/`go` replace the cursor; `for each` walks it; `count` prints its size ✓ |
| the control flow | the conditional runs the statement that follows it; the loop counts up and down; the cursor loop walks the set; a loop that cannot finish says so ✓ |
| the null | a null condition is false ✓ |
| the durability | a link survives a reopen, because it went through the log ✓ |

The durability test is the one that earned its keep: the door's link
wrote straight to the store, which is *in memory and nowhere else*, and
the fixture's nodes did the same — so a fixture built that way hides
the bug the test is looking for. Both now go through the transaction
(`tx.createNode`, `tx.createEdge`), which is the path that reaches the
log.

## 8. Running the two plans together

The dependency is one-directional and it is at the **door**, not the
code:

```
GLYPH BASIC ──issues──▶ GLYPH QUERY ──compiles to──▶ Cypher ──▶ the engine
     │                        │
     └──transport────────────┘
        (in-process, or a port)
```

So the client can be written and tested **before** the GLYPH QUERY
compiler exists, against a *stub* transport that records what it was
asked ✓ — and that stub is the test's oracle ✓✓: the transcript test
asserts the exact GLYPH QUERY lines the client issued ✓, which is a
*stronger* test than asserting the rows ✓ (it pins the client's
*intent*, not just its output ✓).

And when the compiler lands, the stub is replaced by the real door and
the same transcript must still hold ✓ (GB-B: the two transports are the
same language ✓✓).

**That is the whole plan for working on them at once:** the client is
written against a door, the door has two implementations (a stub now, the
engine later), and the tests pin what crosses it.

## 9. The definition of done

- [ ] the grammar page is written and reviewed (B1) ✓
- [ ] the session, the cursor and the statements run, and the transcript
      is a golden file (B2, B3, GB-A) ✓
- [ ] every refusal in the table is produced by the code (B2, GB-C) ✓
- [ ] the transport is the *only* way the client reaches the engine
      (B2, pin GB1) ✓
- [ ] the in-process transport runs the real GLYPH QUERY door and the
      transcript is unchanged (B4, GB-B) ✓
- [ ] a client value never reaches the query text (B4, GB-D) ✓
- [ ] a node id above 2³¹ round-trips (B4, GB-E) ✓
- [ ] the control flow runs: the conditional, the loop, `input`, and the
      client's own expressions (B2) ✓
- [ ] a client's write survives a reopen, because it went through the
      log (B4) ✓
- [ ] the eZ80 guest produces the same transcript as the host client
      (B5, GB-F) ✓
- [ ] `docs/ABI.md` records the doors the client uses ✓
