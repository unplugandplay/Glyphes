## test_ez80.nim — the eZ80's test suite.
##
## Two kinds of test, and the split matters:
##
## * **Z80 compatibility** — the same program must give the same answer on
##   the eZ80 as it did on the Z80. The proof is the BASIC: a whole
##   interpreter, 3000 bytes of hand-written assembly, run to the same
##   transcript byte for byte.
## * **The eZ80's own features** — the second memory mode, the 24-bit
##   registers, the mode suffixes, the new instructions, the second
##   register bank, the block instructions and the interrupts.
##
## Run it:   nim c -r tests/test_ez80.nim

import std/[unittest, strutils, os]
import ../ez80
import ../../src/abi
import ../../src/database
import ../../src/txn/txn
import ../../src/gbasic_channel

const
  ## The Z80 transcript of the BASIC demo, captured from the Z80 emulator
  ## before the eZ80 existed. The eZ80 must reproduce it exactly.
  basicGolden = """
GLYPHE BASIC 1.0
READY
10 REM ** GLYPHE BASIC DEMO **20 PRINT "FOR/NEXT AND MATH"30 FOR I=1 TO 540 PRINT I, I*750 NEXT60 PRINT "ABS(-7)=";ABS(-7)70 LET X=10080 PRINT "X/7=";X/7;"RND(10)=";RND(10)90 IF X>50 THEN PRINT "X IS BIG"100 GOSUB 200110 PRINT "BACK FROM SUB"120 INPUT "FAVORITE NUMBER";N130 IF N>10 THEN PRINT "THATS BIG"140 IF N<=10 THEN PRINT "SMALLISH"150 END200 PRINT "IN SUBROUTINE"210 RETURNRUNFOR/NEXT AND MATH
 1       7
 2       14
 3       21
 4       28
 5       35
ABS(-7)= 7
X/7= 14RND(10)= 9
X IS BIG
IN SUBROUTINE
BACK FROM SUB
FAVORITE NUMBER? 42THATS BIG
READY
LISTNEWPRINT 2+3*4 14
BYE"""

proc runCode(code: openArray[uint8]; setup: proc (z: var EZ80) = nil): EZ80 =
  ## Run a program and hand back the machine.
  var z: EZ80
  z.reset(0)
  if setup != nil: setup(z)
  z.load(0, code)
  discard z.run(1_000_000)
  z

suite "Z80 compatibility — the same answers as the Z80 gave":

  test "the three demos of the original emulator still hold":
    ## These are the demos the Z80 emulator shipped with, unchanged.
    var z: EZ80
    z.reset(0)
    z.load(0, [0x3E'u8, 0x07,      # LD A, 7
               0xC6, 0x05,         # ADD A, 5
               0x32, 0x00, 0x10,   # LD (0x1000), A
               0x76])              # HALT
    let t1 = z.run()
    check z.a == 12
    check z.mem[0x1000] == 12
    check t1 == 31

    z.reset(0)
    z.load(0, [0x06'u8, 0x05,      # LD B, 5
               0xAF,               # XOR A
               0x80,               # sum:   ADD A, B
               0x10, 0xFD,         #        DJNZ sum
               0x76])              # HALT
    let t2 = z.run()
    check z.a == 15
    check z.b == 0
    check t2 == 95

    z.reset(0)
    z.load(0, [0x3E'u8, 0x81,      # LD A, 0x81
               0xCB, 0x2F,         # SRA A
               0x76])              # HALT
    let t3 = z.run()
    check z.a == 0xC0
    check (z.f and fc) != 0
    check t3 == 19

  test "the BASIC interpreter gives the Z80's transcript, byte for byte":
    ## The strongest compatibility statement available: a 3000-byte
    ## hand-written BASIC, exercising FOR/NEXT, IF/THEN, GOSUB/RETURN,
    ## INPUT, the arithmetic and the string handling, must produce the
    ## same transcript it produced on the Z80.
    let here = currentSourcePath().parentDir.parentDir    # the ez80 directory
    let bin = readFile(here / "basic.bin")
    let input = here / "tests" / "basic_input.txt"
    var z: EZ80
    z.reset(0)
    for i, c in bin:
      z.mem[i] = c.uint8
    z.mem[0xD6E0] = 1                                # echo the input
    z.inBuf = readFile(input)
    discard z.run(200_000_000'u64)
    let got = z.outBuf.replace("\r", "\n").strip
    check got == basicGolden.strip

  test "the DD page addresses memory through IX with a displacement":
    var z: EZ80
    z.reset(0)
    z.load(0x2000, [0x42'u8, 0x00, 0x99])              # the byte at IX+2
    z.load(0, [0xDD'u8, 0x21, 0x00, 0x20,             # LD IX, 0x2000
               0xDD, 0x7E, 0x02,                     # LD A, (IX+2)
               0x76])                              # HALT
    discard z.run()
    check z.a == 0x99
    check z.ix == 0x2000

  test "the ED page's block copy moves a block and counts it down":
    var z: EZ80
    z.reset(0)
    for i in 0 ..< 8:
      z.mem[0x3000 + i] = uint8(i + 1)
    z.load(0, [0x21'u8, 0x00, 0x30,                 # LD HL, 0x3000
               0x11, 0x00, 0x40,                     # LD DE, 0x4000
               0x01, 0x08, 0x00,                     # LD BC, 8
               0xED, 0xB0,                           # LDIR
               0x76])                              # HALT
    discard z.run()
    for i in 0 ..< 8:
      check z.mem[0x4000 + i] == uint8(i + 1)
    check (z.bc() and 0xFFFF) == 0

  test "the ED page's ADC/SBC on HL carries between them":
    var z: EZ80
    z.reset(0)
    z.load(0, [0x21'u8, 0xFF, 0xFF,                 # LD HL, 0xFFFF
               0x01, 0x01, 0x00,                     # LD BC, 1
               0xED, 0x4A,                           # ADC HL, BC
               0x76])                              # HALT
    discard z.run()
    check (z.hl() and 0xFFFF) == 0x0000            ## the sum wrapped
    check (z.f and fc) != 0                        ## and it carried

suite "the eZ80's second memory mode":

  test "ADL mode gives the registers 24 bits":
    ## LD HL, nnn in ADL mode fetches three bytes, and HL keeps all of
    ## them; in Z80 mode the same instruction fetches two.
    var z: EZ80
    z.reset(0)
    z.adl = true
    z.load(0, [0x21'u8, 0x56, 0x34, 0x12,           # LD HL, 0x123456
               0x76])
    discard z.run()
    check z.hl() == 0x123456

  test "ADL mode addresses 16 MB, and Z80 mode pages by MBASE":
    var z: EZ80
    z.reset(0)
    z.adl = true
    z.load(0, [0x21'u8, 0x00, 0x00, 0x20,           # LD HL, 0x200000
               0x36, 0x5A,                         # LD (HL), 0x5A
               0x76])
    discard z.run()
    check z.mem[0x200000] == 0x5A

    var y: EZ80
    y.reset(0)
    y.mbase = 0x12
    y.load(0, [0x21'u8, 0x00, 0x00,                 # LD HL, 0x0000
               0x36, 0x77,                         # LD (HL), 0x77
               0x76])
    discard y.run()
    check y.mem[0x120000] == 0x77

  test "the .SIS suffix runs one instruction in 16-bit mode":
    ## LD.LIL HL, nnn in ADL mode keeps 24 bits; LD.SIS HL, mn does not.
    var z: EZ80
    z.reset(0)
    z.adl = true
    z.load(0, [0x40'u8, 0x21, 0x34, 0x12,           # .SIS LD HL, 0x1234
               0x76])
    discard z.run()
    check z.hl() == 0x1234                           ## the upper byte is zero

  test "the .LIL suffix fetches a 24-bit immediate in Z80 mode":
    var z: EZ80
    z.reset(0)
    z.adl = false
    z.load(0, [0x5B'u8, 0x21, 0x56, 0x34, 0x12,     # .LIL LD HL, 0x123456
               0x76])
    discard z.run()
    check z.hl() == 0x123456                         ## the .L half: 24-bit
                                                  ## registers keep it all

  test "a suffixed JP changes the mode for good":
    ## The mode change is persistent: the instruction that follows the
    ## jump runs in the new mode.
    var z: EZ80
    z.reset(0)
    z.adl = true
    z.load(0, [0x5B'u8, 0xC3, 0x05, 0x00, 0x00,     # .LIL JP 0x000005
               0x21, 0x56, 0x34, 0x12,              # LD HL, 0x123456
               0x76])
    discard z.run()
    check z.hl() == 0x123456                          ## the target is in ADL mode
    check z.adl

suite "the eZ80's own instructions":

  test "LEA computes an effective address into a register":
    var z: EZ80
    z.reset(0)
    z.load(0, [0xDD'u8, 0x21, 0x00, 0x20,           # LD IX, 0x2000
               0xED, 0x02, 0x10,                     # LEA BC, IX+16
               0x76])
    discard z.run()
    check (z.bc() and 0xFFFF) == 0x2010

  test "LEA IX,IX+d adds the displacement to the index register":
    var z: EZ80
    z.reset(0)
    z.load(0, [0xDD'u8, 0x21, 0x00, 0x20,           # LD IX, 0x2000
               0xED, 0x32, 0x05,                     # LEA IX, IX+5
               0x76])
    discard z.run()
    check z.ix == 0x2005

  test "MLT multiplies two register pairs into DE:HL":
    var z: EZ80
    z.reset(0)
    z.load(0, [0x21'u8, 0x02, 0x00,                 # LD HL, 2
               0x01, 0x03, 0x00,                     # LD BC, 3
               0xED, 0x4C,                           # MLT BC
               0x76])
    discard z.run()
    check (z.de() and 0xFFFF) == 0                    ## the high word
    check (z.hl() and 0xFFFF) == 6                    ## the low word

  test "TST tests without storing":
    var z: EZ80
    z.reset(0)
    z.load(0, [0x3E'u8, 0x0F,                       # LD A, 0x0F
               0xED, 0x64, 0x00,                     # TST A, 0
               0x76])
    discard z.run()
    check z.a == 0x0F                               ## A is unchanged
    check (z.f and fz) != 0                         ## 0x0F AND 0 == 0

  test "the second register bank is a whole bank, not one register":
    ## EX AF,AF' swaps A and F; EXX swaps the rest.
    var z: EZ80
    z.reset(0)
    z.load(0, [0x3E'u8, 0x11,                       # LD A, 0x11
               0x06, 0x22,                           # LD B, 0x22
               0x08,                                 # EX AF,AF'
               0xD9,                                 # EXX
               0x76])
    discard z.run()
    check z.a2 == 0x11
    check z.b2 == 0x22
    check z.a == 0x00                               ## the old A, in the bank

  test "the block I/O forms move a byte and count down":
    ## INI reads the port into (HL), decrements B and increments HL.
    var z: EZ80
    z.reset(0)
    z.inBuf = "Q"
    z.load(0, [0x21'u8, 0x00, 0x30,                 # LD HL, 0x3000
               0x06, 0x03,                           # LD B, 3
               0x0E, 0x01,                           # LD C, 1 (the input port)
               0xED, 0xA2,                           # INI
               0x76])
    discard z.run()
    check z.mem[0x3000] == uint8('Q')
    check z.b == 2

suite "the interrupts":

  test "a maskable interrupt in mode 1 jumps to 0x0038":
    var z: EZ80
    z.reset(0)
    z.im = 1
    z.load(0, [0xFB'u8,                             # EI
               0x00])                              # NOP
    z.irq = true
    z.irqVector = 0x38
    discard z.step()                                # EI
    discard z.step()                                # NOP -> the interrupt
    check z.pc == 0x0038

  test "the interrupt leaves the return address on the stack":
    var z: EZ80
    z.reset(0)
    z.im = 1
    z.load(0, [0xFB'u8, 0x00])
    z.irq = true
    z.irqVector = 0x38
    discard z.step()
    discard z.step()
    check (z.sp and 0xFFFF) == 0xFFFD               ## the stack moved
    check z.mem[0xFFFD] == 0x01                     ## and the NOP's address
                                                    ## is on it


suite "the port channel — the guest's way of asking the host":

  test "the guest sends a request and the host's answer comes back":
    ## The channel in one test: the guest writes a request to port 3,
    ## the host answers, the guest reads the answer from port 4 and
    ## shows it. The host's answer is the *host's* — the guest knows
    ## nothing about what it means.
    let here = currentSourcePath().parentDir.parentDir
    let bin = readFile(here / "channel.bin")
    var z: EZ80
    z.reset(0)
    for i, c in bin:
      z.mem[i] = c.uint8
    var seen = ""
    z.chanHandler = proc(request: string): string =
      seen = request
      "Person,Company"
    discard z.run(1_000_000)
    check seen == "labels"
    ## The reply's last line has no CR of its own: the CR that ends it
    ## is the empty line that ends the answer, and the guest consumes
    ## it.
    check z.outBuf == "Person,Company"

  test "the request is not on the console":
    ## The transcript is the transcript: a request echoed into it would
    ## be a lie about what the guest said.
    let here = currentSourcePath().parentDir.parentDir
    let bin = readFile(here / "channel.bin")
    var z: EZ80
    z.reset(0)
    for i, c in bin:
      z.mem[i] = c.uint8
    z.chanHandler = proc(request: string): string = "ok"
    discard z.run(1_000_000)
    check "labels" notin z.outBuf

  test "the host is asked only when the request is finished":
    ## A request that has not ended with CR is not a request yet: the
    ## handler is called from the guest's poll, and the poll is what
    ## decides the exchange is ready.
    let here = currentSourcePath().parentDir.parentDir
    let bin = readFile(here / "channel.bin")
    var z: EZ80
    z.reset(0)
    for i, c in bin:
      z.mem[i] = c.uint8
    var calls = 0
    z.chanHandler = proc(request: string): string =
      inc calls
      "ok"
    discard z.run(1_000_000)
    ## One request, one answer — the guest polls, and the poll after the
    ## answer finds the queue empty and does not ask again.
    check calls == 1

suite "the port channel — the guest and the real host":

  test "the guest asks the real host, and the answer is the graph's":
    ## The two halves meet: the guest sends a GLYPH QUERY line over the
    ## channel, the host compiles it and runs it against a real graph,
    ## and the answer comes back through the same channel.
    ##
    ## This is the whole of the transport (PLAN-GLYPH-BASIC.md §5, E2):
    ## the guest needs no compiler, because the host has one.
    let path = "tmp" / "ez80-channel.glyph"
    removeFile(path)
    removeFile(path & "-wal")
    let db = openDatabase(path, GLY_OPEN_CREATE)
    let tx = db.beginTransaction()
    discard tx.createNode("Person")
    discard tx.createNode("Company")
    discard db.commitTransaction(tx)

    let here = currentSourcePath().parentDir.parentDir
    let bin = readFile(here / "channel.bin")
    var z: EZ80
    z.reset(0)
    for i, c in bin:
      z.mem[i] = c.uint8
    z.chanHandler = proc(request: string): string = channelAnswer(db, request)
    discard z.run(1_000_000)
    check z.outBuf == "Person\rCompany"
    close(db)

