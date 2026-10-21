## bench.nim — how fast is the BASIC interpreter?
##
## The benchmark is a BASIC program (loop.bas) fed to GLYPHE BASIC; the
## harness times the interpreter around it:
##
##     t0 = the clock before the interpreter starts
##     t1 = the clock after the interpreter has finished
##
## and reports the delta, so the number is the interpreter's own time and
## not a measurement of the harness.
##
## The iteration count is read out of the program itself — the product of
## its FOR limits — so the report cannot claim a million iterations for a
## program that does fewer.
##
## Run it:  nim c -r bench/bench.nim

import std/[times, strutils, os]
import ../ez80

const
  program = "loop.bas"
  ## The BASIC interpreter: the same binary the demo and the tests use.
  interpreter = "../basic.bin"

proc loopCount(lines: seq[string]): int =
  ## The product of the FOR limits in the program.
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

let here = currentSourcePath().parentDir
let src = readFile(here / program)
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
z.mem[0xD6E0] = 1                       # echo the input
z.inBuf = input

let iterations = loopCount(lines)

## The measurement: the clock before the interpreter starts and the clock
## after it has finished.
let wall0 = epochTime()
let cpu0 = cpuTime()
discard z.run(40_000_000_000'u64)
let wall1 = epochTime()
let cpu1 = cpuTime()

let wall = wall1 - wall0
let cpu = cpu1 - cpu0
## The echo of the program text contains the word "DONE" too, so the check
## looks for the *printed* line: the interpreter prints the string
## without its quotes, and the echo shows it with them.
let done = z.outBuf.contains("DONE\r")

echo "program     : ", program, "  (", lines.len, " lines)"
echo "iterations  : ", iterations
echo "wall clock  : ", wall.formatFloat(ffDecimal, 3), " s"
echo "cpu time    : ", cpu.formatFloat(ffDecimal, 3), " s"
if wall > 0:
  echo "rate        : ", (iterations.float / wall).formatFloat(ffDecimal, 0),
       " iterations/s (wall)"
  echo "             : ", (iterations.float / cpu).formatFloat(ffDecimal, 0),
       " iterations/s (cpu)"
echo "finished    : ", (if done: "yes" else: "NO -- the program did not reach its end")
echo "emulator    : ", z.cycles, " T-states, ", z.outBuf.len,
     " characters of console output"
