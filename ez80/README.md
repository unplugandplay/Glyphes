# eZ80 — a Zilog eZ80 emulator and assembler in Nim

This is the Z80 emulator that lived at the root of this repository, grown
into an **eZ80**: the Zilog eZ80 CPU, with its second memory mode, its
24-bit registers, its second register bank and its own instruction set —
plus the BASIC that was written for it.

```
ez80.nim        the CPU: a Z80 superset
ez80asm.nim     the assembler: the Z80 instruction set plus the eZ80's
basic.z80       GLYPHE BASIC 1.0 — a line-numbered BASIC in Z80 assembly
basic.bin       the assembled BASIC
channel.z80     the port channel to a host: send a line, read an answer
channel.bin     the assembled channel
gbasic.z80      GLYPH BASIC — the client's language, on the eZ80
gbasic.bin      the assembled GLYPH BASIC (the transcript gate loads it)
tests/          the test suite
```

## What the eZ80 is

The eZ80 (Zilog, 2001) is an 8-bit CPU that is a **superset** of the Z80:
every Z80 program still runs on it, and the TI-83/TI-84 calculators use it
in 24-bit address mode at 48 MHz.

The differences that matter here:

**Two memory modes.** In **Z80 mode** the addresses are 16-bit and paged
by the 8-bit `MBASE` register, exactly as a Z80 expects. In **ADL mode**
the addresses are 24-bit over 16 MB, and the register pairs, the index
registers, the stack pointer and the program counter are all 24-bit. The
mode is changed by a *suffix* on an instruction:

| suffix | registers | immediates | prefix byte |
|---|---|---|---|
| `.SIS` | 16-bit | 2 bytes | `0x40` |
| `.LIS` | 24-bit | 2 bytes | `0x49` |
| `.SIL` | 16-bit | 3 bytes | `0x52` |
| `.LIL` | 24-bit | 3 bytes | `0x5B` |

On `JP`, `CALL`, `RST` and `RET` the suffix changes the mode *for good*;
on anything else it applies to that instruction only.

Those four prefix bytes are the Z80's `LD B,B`, `LD C,C`, `LD D,D` and
`LD E,E` — no-ops no compiler emits. In Z80 mode the prefix is a no-op
too, so a Z80 program that happens to contain one still behaves.

**A second register bank.** Every register has an alternate: `EX AF,AF'`
swaps A and F, `EXX` swaps the rest, and the `RS` prefix (in the
assembler, `LD` with a suffix) selects the alternate set for one
instruction.

**New instructions.** `LEA` (load an effective address), `MLT` (multiply two
register pairs into `DE:HL`), `TST` (test without storing), `TSTIO`, `PEA`,
the immediate block-I/O forms (`INIM`, `OTIM`, `INIMR`, …), `SBC HL,rr`,
`LD rr,(HL)`, `IN0`/`OUT0`, `LD MB,A`, `STMIX`/`RSMIX`, and `SLL` as a
documented instruction.

## Z80 compatibility

The eZ80 is a superset of the **documented** Z80 instruction set: the
main page, the CB page, the ED page (block transfers, block I/O, the
interrupt and refresh registers) and the DD/FD pages (IX and IY, with the
undocumented `IXH`/`IXL` forms). The Z80's *undocumented* opcodes are
partly reused by the eZ80 — `ED 42/52/62/72` become `SBC HL,rr` and
`ED 4C/5C/6C/7C` become `MLT` — which is legal, because they were
undocumented.

The proof that the Z80 still works is in the test suite: **the BASIC
interpreter, 3000 bytes of hand-written assembly, produces the same
transcript byte for byte** as it did on the Z80 emulator. The BASIC
exercises `FOR`/`NEXT`, `IF`/`THEN` (with all six comparison operators),
`GOSUB`/`RETURN`, `INPUT`, string handling, integer arithmetic and the
console.

## Running it

```
nim c -r tests/test_ez80.nim          # the test suite
nim c -r ez80asm.nim -- basic.z80 out.bin
nimble ez80Bench                      # the interpreter's speed
```

## The benchmark

The same million iterations, twice: once through the interpreter, once
as Z80 assembly.

`bench/loop.bas` is a BASIC program *fed to* GLYPHE BASIC:

```
10 REM ** eZ80 BASIC benchmark: 1000 x 1000 = 1,000,000 loop iterations **
20 FOR I = 1 TO 1000
30 FOR J = 1 TO 1000
40 NEXT
50 NEXT
60 PRINT "DONE"
```

`bench/loop.z80` is the same loop in machine code — assembled by
`ez80asm.nim` and run directly:

```
START:  LD BC, OUTER
OUTERL: LD DE, INNER
INNERL: DEC DE
        LD A, D
        OR E
        JR NZ, INNERL
        DEC BC
        LD A, B
        OR C
        JR NZ, OUTERL
        HALT
```

`bench/bench.nim` runs both — and a third: the same loop written in
Nim, compiled to native code for this machine, which is the floor under
the other two. The clock is taken **before the run starts** and **after
it ends**, so the number is the work's own time and not a measurement of
the harness:

```
                                     wall        cpu    ns/iter     T-states   T/iter
    GLYPHE BASIC (interpreted)    7.575 s    7.451 s    7574.59   3898354435     3898
         Z80 assembly (direct)    0.060 s    0.059 s      59.66     26031009       26
     native Nim (this machine)    0.001 s    0.000 s       0.50            -        -

BASIC vs assembly : 127.0x
assembly vs native: 118.5x
finished          : yes / yes / yes
```

Two things the third row needs to be honest about. The native loop is
run 200 times and the elapsed time divided, because a million
iterations of native code take about a millisecond — below what the clock
resolves in one go — and the repetition index is folded into the result
on purpose, so the compiler cannot hoist one call out of the repetitions
and leave the other 199 as nothing to do (it did exactly that the first
time, and the row read 0.000 s). And the native loop accumulates its
counter, which the machine-code version does not: so the native row
does marginally *more* work than the assembly row, and the floor it
reports is a slight over-estimate rather than a flattering one.

The iteration count is read out of each program — the product of the
BASIC's `FOR` limits, and the assembler's symbol table for the assembly —
so a report cannot claim a million iterations for a program that does
fewer. The BASIC's completion check looks for the *printed* `DONE`: the
echo of the program text contains the word too, and the first version of
the check was fooled by exactly that and reported success on a run that
had never finished.

**Why two loops in the BASIC.** A single loop cannot count to a million
here: the BASIC's integers are 16-bit signed, so a counter tops out at
32767. Two nested loops do it honestly, and they also stand on the `FOR`
stack, which is the part of the interpreter a benchmark should be
measuring.

**What the gap says.** The rows are the same work — a million iterations
of a loop that counts down — and they say three different things.

*Interpretation costs 127×.* The BASIC spends 3898 T-states per `NEXT`
where the machine code spends 26, and the wall clock shows the same
ratio. So the interpreter's overhead is the *work*, not a fixed cost
around it, and nearly all of it is the **keyword dispatch**: every
statement is matched by walking a seventeen-entry table of keywords, so
`NEXT` is the seventeenth one tried. A hashed dispatch would be several
times faster, and this is the measurement that would show it.

*Emulation costs 118×.* The same Z80 program, run on the same machine,
takes 60 ns per iteration as emulated Z80 and 0.5 ns as native code.
The emulator interprets 26 T-states in about 60 ns — roughly 2.3 ns per
T-state — which is the price of the interpreter the eZ80 itself is, and
it is the same order as the BASIC's own dispatch cost per statement.

*And the floor is 0.5 ns.* A million iterations of a decrement, a test
and a branch, in the object code this machine actually runs.

## The BASIC

`basic.z80` is **GLYPHE BASIC 1.0**, a line-numbered BASIC in the spirit
of Locomotive BASIC 1.0 (the Amstrad CPC 464's): `NEW`, `LIST`, `RUN`,
`CLS`, `BYE`, `PRINT`, `INPUT`, `LET`, `IF`…`THEN`, `FOR`/`NEXT`,
`GOTO`, `GOSUB`/`RETURN`, `REM`, `END`, `POKE`, and the functions `RND`,
`ABS`, `INT`, `PEEK`. Sixteen-bit signed integers, variables `A` to `Z`,
uppercase only, no strings as variables and no floats.

The console is two ports: `OUT (1),A` prints a character and `IN A,(2)`
is the status (1 = a character is waiting) with `IN A,(1)` reading it.

### The bugs this work found

The BASIC had never been run to completion, because the emulator it was
written for raised on the DD and ED pages and the BASIC avoided them.
Running it found **nine defects in the BASIC itself**, each of which made
a whole class of program fail:

1. `TOEOL` walked to the end of a line but never wrote the cursor back,
   so a `REM` line's own tail was parsed as more statements.
2. The statement executor pointed the cursor at `ENTRY+1` — the line
   number — instead of `ENTRY+3`, the text, so every line *after the
   first* was a syntax error.
3. The program store advanced the end pointer by the *position* of the
   entry instead of its *size*, so the second program line was written on
   top of the first.
4. `FINDLINE` stepped back two bytes on one path and one on the other,
   so it searched from one byte before each entry and never found a line.
5. `NEXT` restored the text cursor but not the line pointer, so a loop
   stepped past the end of the program instead of back to its body.
6. The comparison operators stored the *character* instead of their
   code, because `GETC` overwrote the accumulator on the way to the
   store — so `<=` and `<>` were silently `=`.
7. The `IF` handler tested the flags *after* popping the condition, so a
   **true** condition read as "no THEN" and every `IF` was a syntax
   error.
8. The `INPUT` handler stored the program cursor as the number the user
   typed.
9. The `GOSUB` stack check compared only the high bytes of the stack
   pointer, so the *first* `GOSUB` was refused as "out of memory".

And the `GOSUB` stack itself pushed the words big-endian while `RETURN`
read them little-endian, so every `RETURN` restored a byte-swapped line
pointer.

## GLYPH BASIC on the eZ80

`gbasic.z80` is the *second* implementation of GLYPH BASIC — the client's
language, not the line-numbered BASIC above. The host client is Nim
(`src/gbasic.nim`); this is Z80 assembly, and the proof that the
language is small enough to be written twice (pin GB9) is the
**transcript**: the same script, run on both, must produce the same
bytes (PLAN-GLYPH-BASIC.md §6, E4).

The graph is not here. The guest sends a GLYPH QUERY line over the port
channel in `channel.z80`, the host compiles it and runs it against a real
graph, and the answer comes back through the same channel — so the guest
needs no compiler and no graph, and 6 KB is enough.

What it has: `find`, `count`, `labels`, `end`, `rem`, `let` and the bare
assignment, `input`, `print`, `show`, `go`, `if … then`,
`while … : … [next]`, `for`, `for each`, and the writes `add`, `link`,
`set`, `drop`; names (eight of seven characters, 16-bit values), the
arithmetic `+ - * /`,
the boolean operators `and`/`or`/`not`, and the comparisons
`= < > <= >= <>` over numbers, quoted text and yes/no values. The writes
ride the channel the reads already use — `add` forwards its property
list as the host forwards it, `set` and `drop` send parameterised `exec`
lines, and `link` is the verb the engine's no-joins rule needs. The
conditional implements the host's own body rule: at the line level it
owns the rest of the line; as one piece of a body it owns only its own
tail (`LEVEL` is the difference). `while` is line-level by the same
rule, and its body takes a `next`, with the statements after it run
once.

The values are the host's own model, not a numeric subset: each name
carries a kind (number, text, yes/no) beside its 16-bit value, a quoted
word is copied into a 1 KB arena (a length byte and its bytes) so it can
outlive the line it was read on, `+` concatenates two texts and refuses
a mixed pair, text ordering ignores case while equality does not, an
empty text is false, and `and`/`or` are eager with `not` binding looser
than a comparison. A full arena is a refusal (`?`), not an overwrite.
`input` reads the next console line into a name — stripped at both ends,
all digits a number, anything else text — using a buffer of its own so
the line or loop body being run is not overwritten.

Three things make it a client rather than a remote control, and they are
also why it fits:

- **the line is tokenized once** — into words, and into statements: a
  statement is a *range of words* (`STARTS`), so a loop body is a range
  and re-running the body re-runs the range, with no re-scan;
- **the names are a table**, not a dictionary: eight slots of a
  seven-character name, a 16-bit value and a kind;
- **the loops keep their state per depth** — the body's range, a copy of
  the cursor and the walking offset — so a nested loop keeps its own
  `next` and its own walk, exactly as the host's does.

What it refuses, rather than pretending: `gosub`/`return` and the
program model. An unknown statement, or one with trailing words the
guest does not understand, prints `?` and abandons the line — it does
not half-run — and an answer the host refuses (`!`) is printed as the
same one-word `?`. So are an unterminated text, a text where a node id
belongs, and a text added to a number. The refusal vocabulary is the
one-word `?`; the host's messages are longer, and that is a documented
divergence.

The other divergence is the shape of an expression: the guest works on
words, so `1 + 2` is three words and the operators have to stand alone —
`1+2` is one word and is not arithmetic. The arithmetic is 16-bit, and
so is `while`'s round guard: it stops at 65,535 rounds where the host
stops at a million, refusing a runaway loop either way. The budget buys
that, and `ez80/tests/test_ez80.nim` measures both the transcript and
the size (5,413 bytes, under the plan's 6 KB mark; the first half fitted
in 3 KB, the writes moved the mark to 4 KB, the value model moved it to
6 KB, `input` landed inside it, and each move is recorded in the plan).

## Known gaps

* The `INI2`/`IND2`/`OUTI2`/`OUTD2` family (the 24-bit-address block
  I/O forms) is **not** implemented: the manual's two opcode tables
  disagree about their encodings, and rather than guess they are left
  out. Everything else in the ED page is there.
* The interrupt modes are implemented (0, 1 and 2, with the `I` register
  and the vector) but there is no interrupt *source* on the bus — the
  host raises `irq`/`nmi` by hand.
* The T-state counts are the Z80's, not the eZ80's: the eZ80's pipeline
  changes them, and nothing here depends on them but the cycle budget.
* The `RS` prefix (select the alternate register set for one
  instruction) is not implemented; `EX AF,AF'` and `EXX` are.
* The `MADL` (mixed-memory) mode is stored but does not change the
  interrupt behaviour.

## The manual

Everything here follows the **Zilog eZ80 CPU User Manual** (UM0077,
revision 15-04-2015), which is the authority for the opcodes, the cycle
counts and the mode semantics. Where the manual's opcode map and its
per-instruction pages disagree, the per-instruction pages were followed —
they are the detailed tables, and the map is the summary.
