## bench.nim — how fast is the interpreter, and how fast is the machine?
##
## The same benchmark twice:
##
## * `loop.bas` — a BASIC program, *fed to* GLYPHE BASIC and interpreted.
## * `loop.z80` — the same million iterations in Z80 assembly, assembled
##   and run directly.
##
## The clock is taken before the interpreter (or the program) starts and
## after it ends, so the number is the work's own time and not a
## measurement of the harness:
##
##     t0 = the clock before the run
##     t1 = the clock after the run
##
## The iteration count is read out of each program — the product of its
## `FOR` limits, and the assembler's symbol table for the assembly — so a
## report cannot claim a million iterations for a program that does
## fewer.
##
## Run it:  nim c -r bench/bench.nim

import std/[times, strutils, os]
import ../ez80
import ../ez80asm

const
  basicProgram = "loop.bas"
  z80Program = "loop.z80"
  ## The BASIC interpreter: the same binary the demo and the tests use.
  interpreter = "../basic.bin"

type
  Result = object
    name: string
    iterations: int
    wall: float
    cpu: float
    cycles: uint64
    finished: bool
    checksum: uint64   ## the native row's result, so it cannot be folded away

proc loopCount(lines: seq[string]): int =
  ## The product of the FOR limits in a BASIC program.
  result = 1
  for ln in lines:
    let up = ln.toUpperAscii
    let at = up.find(" TO ")
    if at < 0 or not up.contains(" FOR "):
      continue
    var n = 0
    var seen = false
    for ch in up[at + 3 .. ^1]:
      if ch in Digits:
        n = n * 10 + (ord(ch) - ord('0'))
        seen = true
      elif seen:
        break
    if seen and n > 0:
      result *= n

proc symbolValue(name: string): int =
  ## A symbol from the last assembly.
  for s in symbols():
    if s.name == name:
      return s.value
  0

proc runBasic(here: string): Result =
  ## The BASIC program, interpreted.
  let src = readFile(here / basicProgram)
  let lines = src.splitLines()
  ## The interpreter is fed the program, then RUN, then BYE: the BASIC
  ## stores the program as it is typed and runs it on the RUN line.
  var input = src.replace("\n", "\r")
  if not input.endsWith("\r"):
    input.add "\r"                ## the last line needs its terminator too
  input.add "RUN\rBYE\r"

  var z: EZ80
  z.reset(0)
  let bin = readFile(here / interpreter)
  for i, c in bin:
    z.mem[i] = c.uint8
  z.mem[0xD6E0] = 1               # echo the input
  z.inBuf = input

  let wall0 = epochTime()
  let cpu0 = cpuTime()
  discard z.run(40_000_000_000'u64)
  let wall1 = epochTime()
  let cpu1 = cpuTime()

  result.name = "GLYPHE BASIC (interpreted)"
  result.iterations = loopCount(lines)
  result.wall = wall1 - wall0
  result.cpu = cpu1 - cpu0
  result.cycles = z.cycles
  ## The echo of the program text contains the word "DONE" too, so the
  ## check looks for the *printed* line: the interpreter prints a string
  ## without its quotes, and the echo shows it with them.
  result.finished = z.outBuf.contains("DONE\r")

proc runZ80(here: string): Result =
  ## The assembly program, run directly.
  let binPath = here.parentDir.parentDir / "tmp" / "ez80_bench_loop.bin"
  assemble(here / z80Program, binPath)
  let code = readFile(binPath)

  var z: EZ80
  z.reset(0)
  for i, c in code:
    z.mem[i] = c.uint8

  let wall0 = epochTime()
  let cpu0 = cpuTime()
  discard z.run(40_000_000_000'u64)
  let wall1 = epochTime()
  let cpu1 = cpuTime()

  result.name = "Z80 assembly (direct)"
  result.iterations = symbolValue("OUTER") * symbolValue("INNER")
  result.wall = wall1 - wall0
  result.cpu = cpu1 - cpu0
  result.cycles = z.cycles
  result.finished = z.halted

proc nativeLoop(outer, inner: int): uint64 =
  ## The same loop, in Nim, compiled to native code for this machine.
  ##
  ## This is the floor under both other rows: no interpreter, no
  ## emulator, no Z80 -- just the loop, in the object code the machine
  ## actually runs. The counts arrive as parameters so the compiler
  ## cannot fold the loop away, and the checksum keeps the result live.
  var bc = outer
  var de = inner
  var acc = 0'u64
  while bc != 0:
    de = inner
    while de != 0:
      dec de
      acc = acc + de.uint64
    dec bc
  result = acc

proc runNative(outer, inner: int): Result =
  ## A million iterations of native code take about a millisecond, which
  ## is below what the clock can resolve in one go, so the loop is run
  ## repeatedly and the elapsed time divided: the number reported is
  ## still the time for *one* million-iteration loop, the same work the
  ## other two rows do.
  const reps = 200
  var checksum = 0'u64
  let wall0 = epochTime()
  let cpu0 = cpuTime()
  for i in 0 ..< reps:
    ## The repetition index is folded into the result on purpose: the
    ## loop is then not loop-invariant, so the compiler cannot hoist one
    ## call out of the repetitions and leave the other 199 as nothing to
    ## do -- which is exactly what it did the first time, and why the
    ## row read 0.000 s.
    checksum = checksum + (nativeLoop(outer, inner) xor (uint64(i) * 0x9E37_79B9_7F4A_7C15'u64))
  let wall1 = epochTime()
  let cpu1 = cpuTime()
  result.name = "native Nim (this machine)"
  result.iterations = outer * inner
  result.wall = (wall1 - wall0) / float64(reps)
  result.cpu = (cpu1 - cpu0) / float64(reps)
  result.checksum = checksum
  result.finished = true

let here = currentSourcePath().parentDir
let basic = runBasic(here)
let direct = runZ80(here)
let native = runNative(symbolValue("OUTER"), symbolValue("INNER"))

echo "program     : ", basicProgram, " (", basic.iterations, " iterations, interpreted)"
echo "             ", z80Program, "  (", direct.iterations, " iterations, assembled)"
echo ""
echo "".align(30), "wall".align(11), "cpu".align(11), "ns/iter".align(11),
     "T-states".align(13), "T/iter".align(9)
for r in [basic, direct, native]:
  let ns = if r.wall > 0: r.wall * 1e9 / float64(r.iterations) else: 0.0
  let per = if r.cycles > 0: r.cycles div uint64(r.iterations) else: 0
  echo r.name.align(30),
       (r.wall.formatFloat(ffDecimal, 3) & " s").align(11),
       (r.cpu.formatFloat(ffDecimal, 3) & " s").align(11),
       (ns.formatFloat(ffDecimal, 2)).align(11),
       (if r.cycles > 0: $r.cycles else: "-").align(13),
       (if per > 0: $per else: "-").align(9)
echo ""
echo "BASIC vs assembly : ", (basic.wall / direct.wall).formatFloat(ffDecimal, 1), "x"
echo "assembly vs native: ", (direct.wall / native.wall).formatFloat(ffDecimal, 1), "x"
echo "finished          : ", (if basic.finished: "yes" else: "NO"), " / ",
     (if direct.finished: "yes" else: "NO"), " / ",
     (if native.finished: "yes" else: "NO")
echo "native checksum   : ", native.checksum, "  (keeps the loop alive) "
