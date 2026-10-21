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

`bench/loop.bas` is a BASIC program the interpreter runs, and
`bench/bench.nim` times it:

```
10 REM ** eZ80 BASIC benchmark: 1000 x 1000 = 1,000,000 loop iterations **
20 FOR I = 1 TO 1000
30 FOR J = 1 TO 1000
40 NEXT
50 NEXT
60 PRINT "DONE"
```

The harness takes the clock **before the interpreter starts** and
**after it ends**, and reports the delta — so the number is the
interpreter's own time, not a measurement of the harness:

```
iterations  : 1000000
wall clock  : 13.733 s
cpu time    : 13.605 s
rate        : 72816. iterations/s (wall)
finished    : yes
```

The iteration count is read out of the program (the product of its `FOR`
limits) rather than repeated in the harness, so the report cannot claim a
million iterations for a program that does fewer. The program prints
`DONE` when it arrives at the end, and the harness checks for that
*printed* line — the echo of the program text contains the word too.

**Why two loops.** A single loop cannot count to a million here: the
BASIC's integers are 16-bit signed, so a counter tops out at 32767. Two
nested loops do it honestly, and they also stand on the `FOR` stack,
which is the part of the interpreter a benchmark should be measuring.

The number is worth reading for what it says about the interpreter rather
than about the CPU: a million iterations of `NEXT` cost about 3900
T-states each, and most of that is the **keyword dispatch** — every
statement is matched by walking a seventeen-entry table of keywords, so
`NEXT` is the seventeenth one tried. An interpreter with a hashed
dispatch would be several times faster, and this is the measurement that
would show it.

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
