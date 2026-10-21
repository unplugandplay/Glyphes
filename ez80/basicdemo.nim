## basicdemo.nim — boot GLYPHE BASIC (basic.z80) on the eZ80 emulator.
##
##   nim c -r basicdemo.nim        batch demo: feed a program, run, print
##   nim c -r basicdemo.nim -i     interactive BASIC prompt (type BYE to quit)

import std/[strutils, os]
import ez80

proc boot(z: var EZ80, bin: string) =
  z.reset(0)
  for i, c in bin:
    z.mem[i] = c.uint8

const demoProgram = """
10 REM ** GLYPHE BASIC DEMO **
20 PRINT "FOR/NEXT AND MATH"
30 FOR I=1 TO 5
40 PRINT I, I*7
50 NEXT
60 PRINT "ABS(-7)=";ABS(-7)
70 LET X=100
80 PRINT "X/7=";X/7;"RND(10)=";RND(10)
90 IF X>50 THEN PRINT "X IS BIG"
100 GOSUB 200
110 PRINT "BACK FROM SUB"
120 INPUT "FAVORITE NUMBER";N
130 IF N>10 THEN PRINT "THATS BIG"
140 IF N<=10 THEN PRINT "SMALLISH"
150 END
200 PRINT "IN SUBROUTINE"
210 RETURN
RUN
42
LIST
NEW
PRINT 2+3*4
BYE
"""

## The binary sits beside this source, not beside the executable: the
## executable is usually built into tmp/.
let here = currentSourcePath().parentDir
let bin = readFile(here / "basic.bin")

if paramCount() > 0 and paramStr(1) == "-i":
  var z: EZ80
  z.boot(bin)
  z.mem[0xD6E0] = 0            # ECHOFLG off: the terminal already echoes
  z.interactive = true
  discard z.run(1_000_000_000'u64)
else:
  var z: EZ80
  z.boot(bin)
  z.mem[0xD6E0] = 1            # ECHOFLG on: show typed input in transcript
  ## The BASIC reads a line with a carriage return, not a line feed.
  z.inBuf = demoProgram.replace("\n", "\r")
  discard z.run(200_000_000'u64)
  stdout.write z.outBuf.replace("\r", "\n")
