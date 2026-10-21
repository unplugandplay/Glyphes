## ez80.nim — a Zilog eZ80 CPU emulator in a single Nim file.
##
## The eZ80 is a Z80 superset: every Z80 instruction still works, and on
## top of it there is a second memory mode, 24-bit registers, a second
## register bank for every register, and a set of new instructions.
##
## ## The two memory modes
##
## * **Z80 mode** (the ADL bit clear) — 16-bit addresses, 16-bit registers,
##   and the 8-bit MBASE register paging memory: the effective address is
##   {MBASE, addr16}. This is the mode a Z80 program expects, and it is
##   the mode the CPU starts in.
## * **ADL mode** (the ADL bit set) — 24-bit linear addressing over 16 MB,
##   24-bit BC/DE/HL/IX/IY/SPL/PC, and a 24-bit ALU. The stack pointer
##   becomes SPL and can live anywhere in memory.
##
## The mode is changed by the *suffix* mechanism: an instruction may carry
## .SIS, .SIL, .LIS or .LIL, and the suffix says what the instruction does
## with registers (S = 16-bit, L = 24-bit) and with its immediates (IS = 2
## bytes, IL = 3 bytes). On a control-transfer instruction (JP, CALL, RST,
## RET, RETI, RETN) the suffix changes the mode *persistently*; on any
## other instruction it applies to that instruction only.
##
## The four suffixes are encoded as one-byte prefixes, which is why the
## eZ80 gives up four Z80 opcodes to them:
##
##     0x40  .SIS   16-bit registers, 2-byte immediates
##     0x49  .LIS   24-bit registers, 2-byte immediates
##     0x52  .SIL   16-bit registers, 3-byte immediates
##     0x5B  .LIL   24-bit registers, 3-byte immediates
##
## (On the real Z80 those four bytes are LD B,B / LD C,C / LD D,D / LD E,E —
## no-ops that no compiler emits, so nothing is lost. A Z80 program that
## does contain one gets the prefix, which in Z80 mode means "the next
## instruction, unchanged" — the same no-op.)
##
## ## Z80 compatibility
##
## The whole Z80 instruction set is here: the main page, the CB page, the
## ED page (block transfers, block I/O, the interrupt and refresh
## registers) and the DD/FD pages (IX and IY). The undocumented Z80
## opcodes are here too, except the ones the eZ80 itself reuses — the
## eZ80 gives ED 42/52/62/72 to SBC HL,rr and ED 4C/5C/6C/7C to MLT, and
## uses ED 07/17/27/31/37 for LD rr,(HL). Every *documented* Z80 opcode
## keeps its meaning; that is what "superset" means here.
##
## Try it:   nim c -r ez80.nim
## Use it:   import ez80

import std/strformat

const
  # Bits inside the F (flags) register.
  fc* = 0x01'u8  # C  carry
  fn* = 0x02'u8  # N  add/subtract
  fp* = 0x04'u8  # P/V parity / overflow
  fh* = 0x10'u8  # H  half carry
  fz* = 0x40'u8  # Z  zero
  fs* = 0x80'u8  # S  sign

  # The four memory-mode suffixes, as one-byte prefixes.
  pfxSIS* = 0x40'u8
  pfxLIS* = 0x49'u8
  pfxSIL* = 0x52'u8
  pfxLIL* = 0x5B'u8

  # T-states for the unprefixed opcodes. Conditional RET/CALL count as
  # taken (corrected in `step` when not taken); JR/DJNZ count as not
  # taken (+5 in `step` when the branch is taken).
  tStates*: array[256, int] = [
    4, 10, 7, 6, 4, 4, 7, 4, 4, 11, 7, 6, 4, 4, 7, 4,
    8, 10, 7, 6, 4, 4, 7, 4, 12, 11, 7, 6, 4, 4, 7, 4,
    7, 10, 16, 6, 4, 4, 7, 4, 7, 11, 16, 6, 4, 4, 7, 4,
    7, 10, 13, 6, 4, 4, 7, 4, 7, 11, 13, 6, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    7, 7, 7, 7, 7, 7, 4, 7, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
    11, 10, 10, 10, 17, 11, 7, 11, 11, 10, 10, 4, 17, 17, 7, 11,
    11, 10, 10, 11, 17, 11, 7, 11, 11, 4, 10, 11, 17, 17, 7, 11,
    11, 10, 10, 19, 17, 11, 7, 11, 11, 4, 10, 4, 17, 17, 7, 11,
    11, 10, 10, 4, 17, 11, 7, 11, 11, 6, 10, 4, 17, 17, 7, 11,
  ]

type
  EZ80Error* = object of CatchableError
    ## Raised on an undefined or unimplemented opcode.

  EZ80* = object
    ## CPU state plus 16 MB of memory.
    ##
    ## Two register banks: the main set (a, f, b, c, d, e, h, l) and the
    ## alternate set (a2, f2, ...), exactly as the eZ80 has. The `2` suffix
    ## names the alternate set; `EX AF,AF'` and `EXX` swap whole banks.
    a*, f*, b*, c*, d*, e*, h*, l*: uint8
    a2*, f2*, b2*, c2*, d2*, e2*, h2*, l2*: uint8
    ## The upper bytes of the 24-bit pairs, used in ADL mode.
    bcu*, deu*, hlu*: uint8
    bcu2*, deu2*, hlu2*: uint8
    ix*, iy*: uint32   ## 24-bit index registers (16-bit in Z80 mode)
    sp*: uint32        ## SPS (16-bit) in Z80 mode, SPL (24-bit) in ADL
    pc*: uint32
    i*, r*: uint8       ## the interrupt vector register and the refresh counter
    mbase*: uint8       ## the Z80-mode page register
    adl*: bool          ## the memory mode: false = Z80, true = ADL
    madl*: bool         ## mixed-memory mode
    ief1*, ief2*: bool  ## the interrupt enable flags
    im*: int            ## the interrupt mode: 0, 1 or 2
    halted*: bool       ## set by HALT
    sleeping*: bool     ## set by SLP
    nmi*: bool          ## a non-maskable interrupt is waiting
    irq*: bool          ## a maskable interrupt is waiting
    irqVector*: uint8   ## the interrupt's vector byte
    ## 16 MB of memory, on the heap: the eZ80's address bus is 24 bits, and
    ## a 16 MB array as a *local* would overflow the stack.
    mem*: seq[uint8]
    cycles*: uint64     ## total T-states since reset
    # the instruction's own mode, set per instruction by the prefixes
    dm*: bool           ## the data block is 24-bit (the .L half of a suffix)
    sm*: bool           ## the instruction stream is 3 bytes (the .IL half)
    # simple console, used by IN/OUT (see portIn/portOut):
    outBuf*: string   ## everything written via OUT
    inBuf*: string    ## characters queued for IN
    inPos*: int
    interactive*: bool  ## when true and inBuf is empty, read a line from stdin

# ---- memory ---------------------------------------------------------------

## The address bus is 24 bits wide, so every access is masked to 24 bits:
## the eZ80 has no address above 0xFFFFFF, and a 3-byte read at the very top
## of memory must wrap rather than walk off the end of the array.
proc rd8(z: EZ80, ad: uint32): uint8 {.inline.} = z.mem[ad and 0x00FF_FFFF'u32]

proc wr8(z: var EZ80, ad: uint32, v: uint8) {.inline.} =
  z.mem[ad and 0x00FF_FFFF'u32] = v

proc rd16(z: EZ80, ad: uint32): uint32 {.inline.} =
  let a = ad and 0x00FF_FFFF'u32
  z.mem[a].uint32 or (z.mem[a + 1].uint32 shl 8)

proc rd24(z: EZ80, ad: uint32): uint32 {.inline.} =
  let a = ad and 0x00FF_FFFF'u32
  z.mem[a].uint32 or (z.mem[a + 1].uint32 shl 8) or (z.mem[a + 2].uint32 shl 16)

proc wr16(z: var EZ80, ad: uint32, v: uint32) {.inline.} =
  let a = ad and 0x00FF_FFFF'u32
  z.mem[a] = v.uint8
  z.mem[a + 1] = (v shr 8).uint8

proc wr24(z: var EZ80, ad: uint32, v: uint32) {.inline.} =
  let a = ad and 0x00FF_FFFF'u32
  z.mem[a] = v.uint8
  z.mem[a + 1] = (v shr 8).uint8
  z.mem[a + 2] = (v shr 16).uint8

# ---- the mode-aware helpers -----------------------------------------------

proc mask(z: EZ80): uint32 {.inline.} =
  ## The width of a register pair in this instruction's data mode.
  if z.dm: 0x00FF_FFFF'u32 else: 0x0000_FFFF'u32

proc addr(z: EZ80, a: uint32): uint32 {.inline.} =
  ## The effective address of a memory operand. In Z80 mode the 16-bit
  ## address is paged by MBASE; in ADL mode the address is already 24-bit.
  if z.dm: a else: (z.mbase.uint32 shl 16) or (a and 0xFFFF'u32)

proc fetch8(z: var EZ80): uint8 {.inline.} =
  result = z.mem[z.pc and 0x00FF_FFFF'u32]
  inc z.pc

proc fetch16(z: var EZ80): uint32 {.inline.} =
  result = z.rd16(z.pc)
  z.pc = z.pc + 2

proc fetchN(z: var EZ80): uint32 {.inline.} =
  ## An immediate: two bytes, or three when the instruction stream is long.
  if z.sm:
    result = z.rd24(z.pc)
    z.pc = z.pc + 3
  else:
    result = z.rd16(z.pc)
    z.pc = z.pc + 2

proc disp(z: var EZ80): int {.inline.} =
  ## Fetch a signed pc-relative displacement.
  int(cast[int8](z.fetch8()))

# ---- register pairs -------------------------------------------------------

proc pairGet(z: EZ80; p: int; alt: bool): uint32 {.inline.} =
  ## BC, DE, HL or SP, in this instruction's data mode.
  if alt:
    case p
    of 0: (z.bcu2.uint32 shl 16) or (z.b2.uint32 shl 8) or z.c2.uint32
    of 1: (z.deu2.uint32 shl 16) or (z.d2.uint32 shl 8) or z.e2.uint32
    of 2: (z.hlu2.uint32 shl 16) or (z.h2.uint32 shl 8) or z.l2.uint32
    else: z.sp
  else:
    case p
    of 0: (z.bcu.uint32 shl 16) or (z.b.uint32 shl 8) or z.c.uint32
    of 1: (z.deu.uint32 shl 16) or (z.d.uint32 shl 8) or z.e.uint32
    of 2: (z.hlu.uint32 shl 16) or (z.h.uint32 shl 8) or z.l.uint32
    else: z.sp

proc pairSet(z: var EZ80; p: int; alt: bool; value: uint32) {.inline.} =
  ## In a 16-bit data mode the upper byte of the pair is undefined on the
  ## real part; here it is zeroed, which is one of the legal choices and
  ## keeps the register's value a function of the instruction rather than of
  ## what was in it before.
  var v = value
  if not z.dm:
    v = v and 0xFFFF'u32
  if alt:
    case p
    of 0:
      z.bcu2 = (v shr 16).uint8
      z.b2 = (v shr 8).uint8
      z.c2 = v.uint8
    of 1:
      z.deu2 = (v shr 16).uint8
      z.d2 = (v shr 8).uint8
      z.e2 = v.uint8
    of 2:
      z.hlu2 = (v shr 16).uint8
      z.h2 = (v shr 8).uint8
      z.l2 = v.uint8
    else:
      z.sp = v
  else:
    case p
    of 0:
      z.bcu = (v shr 16).uint8
      z.b = (v shr 8).uint8
      z.c = v.uint8
    of 1:
      z.deu = (v shr 16).uint8
      z.d = (v shr 8).uint8
      z.e = v.uint8
    of 2:
      z.hlu = (v shr 16).uint8
      z.h = (v shr 8).uint8
      z.l = v.uint8
    else:
      z.sp = v

proc bc*(z: EZ80): uint32 {.inline.} = z.pairGet(0, false)
proc `bc=`*(z: var EZ80, v: uint32) {.inline.} = z.pairSet(0, false, v)
proc de*(z: EZ80): uint32 {.inline.} = z.pairGet(1, false)
proc `de=`*(z: var EZ80, v: uint32) {.inline.} = z.pairSet(1, false, v)
proc hl*(z: EZ80): uint32 {.inline.} = z.pairGet(2, false)
proc `hl=`*(z: var EZ80, v: uint32) {.inline.} = z.pairSet(2, false, v)
proc af*(z: EZ80): uint32 {.inline.} =
  (z.a.uint32 shl 8) or z.f.uint32
proc `af=`*(z: var EZ80, v: uint32) {.inline.} =
  z.a = (v shr 8).uint8
  z.f = v.uint8

proc rpGet(z: EZ80; p: int): uint32 =
  ## BC, DE, HL, SP (used by LD rr,nn / INC rr / ADD HL,rr).
  z.pairGet(p, false)

proc rpSet(z: var EZ80; p: int; v: uint32) =
  z.pairSet(p, false, v)

proc rp2Get(z: EZ80; p: int): uint32 =
  ## BC, DE, HL, AF (used by PUSH/POP).
  if p == 3: z.af else: z.pairGet(p, false)

proc rp2Set(z: var EZ80; p: int; v: uint32) =
  if p == 3: z.af = v else: z.pairSet(p, false, v)

proc rIdx(z: EZ80; i: int; alt: bool): uint8 =
  ## B, C, D, E, H, L, (HL), A — the 8-bit register map used by most ops.
  if alt:
    case i
    of 0: z.b2
    of 1: z.c2
    of 2: z.d2
    of 3: z.e2
    of 4: z.h2
    of 5: z.l2
    of 6: z.mem[z.addr(z.pairGet(2, false))]
    else: z.a2
  else:
    case i
    of 0: z.b
    of 1: z.c
    of 2: z.d
    of 3: z.e
    of 4: z.h
    of 5: z.l
    of 6: z.mem[z.addr(z.pairGet(2, false))]
    else: z.a

proc setR(z: var EZ80; i: int; alt: bool; v: uint8) =
  if alt:
    case i
    of 0: z.b2 = v
    of 1: z.c2 = v
    of 2: z.d2 = v
    of 3: z.e2 = v
    of 4: z.h2 = v
    of 5: z.l2 = v
    of 6: z.mem[z.addr(z.pairGet(2, false))] = v
    else: z.a2 = v
  else:
    case i
    of 0: z.b = v
    of 1: z.c = v
    of 2: z.d = v
    of 3: z.e = v
    of 4: z.h = v
    of 5: z.l = v
    of 6: z.mem[z.addr(z.pairGet(2, false))] = v
    else: z.a = v

# ---- flags ---------------------------------------------------------------

proc putFlag(z: var EZ80, mask: uint8, on: bool) {.inline.} =
  if on:
    z.f = z.f or mask
  else:
    z.f = z.f and (not mask)

proc evenParity(v: uint8): bool {.inline.} =
  var x = v
  result = true
  while x != 0:
    result = not result
    x = x and (x - 1)

proc szp(z: var EZ80, v: uint8) {.inline.} =
  ## Set S, Z and P from a result byte.
  z.putFlag(fs, (v and 0x80) != 0)
  z.putFlag(fz, v == 0)
  z.putFlag(fp, evenParity(v))

proc cond(z: EZ80; i: int): bool =
  ## CC conditions: NZ Z NC C PO PE P M.
  case i
  of 0: (z.f and fz) == 0
  of 1: (z.f and fz) != 0
  of 2: (z.f and fc) == 0
  of 3: (z.f and fc) != 0
  of 4: (z.f and fp) == 0
  of 5: (z.f and fp) != 0
  of 6: (z.f and fs) == 0
  else: (z.f and fs) != 0

# ---- 8-bit ALU -----------------------------------------------------------

proc addA(z: var EZ80, v: uint8, withCarry: bool) =
  let ci = ord(withCarry and (z.f and fc) != 0).uint8
  let a = z.a
  let full = a.uint16 + v.uint16 + ci.uint16
  let res = full.uint8
  z.putFlag(fh, (a and 0x0F) + (v and 0x0F) + ci > 0x0F)
  z.putFlag(fc, full > 0xFF)
  z.putFlag(fp, ((a xor res) and (v xor res) and 0x80) != 0)
  z.putFlag(fn, false)
  z.szp(res)
  z.a = res

proc subA(z: var EZ80, v: uint8, withCarry: bool, store: bool) =
  ## SUB/SBC/CP share this; CP just skips storing the result.
  let ci = ord(withCarry and (z.f and fc) != 0).uint8
  let a = z.a
  let res = (a.int - v.int - ci.int).uint8
  z.putFlag(fh, (a and 0x0F).int - (v and 0x0F).int - ci.int < 0)
  z.putFlag(fc, a.int - v.int - ci.int < 0)
  z.putFlag(fp, ((a xor v) and (a xor res) and 0x80) != 0)
  z.putFlag(fn, true)
  z.szp(res)
  if store:
    z.a = res

proc andA(z: var EZ80, v: uint8) =
  z.a = z.a and v
  z.f = (z.f and (not (fc or fn))) or fh
  z.szp(z.a)

proc xorA(z: var EZ80, v: uint8) =
  z.a = z.a xor v
  z.f = z.f and (not (fc or fn or fh))
  z.szp(z.a)

proc orA(z: var EZ80, v: uint8) =
  z.a = z.a or v
  z.f = z.f and (not (fc or fn or fh))
  z.szp(z.a)

proc alu(z: var EZ80, kind: int, v: uint8) =
  ## ADD ADC SUB SBC AND XOR OR CP (index into this list).
  case kind
  of 0: z.addA(v, false)
  of 1: z.addA(v, true)
  of 2: z.subA(v, false, true)
  of 3: z.subA(v, true, true)
  of 4: z.andA(v)
  of 5: z.xorA(v)
  of 6: z.orA(v)
  else: z.subA(v, false, false)

proc inc8(z: var EZ80, v: uint8): uint8 =
  result = v + 1
  z.putFlag(fh, (v and 0x0F) == 0x0F)
  z.putFlag(fp, v == 0x7F)
  z.putFlag(fn, false)
  z.szp(result)

proc dec8(z: var EZ80, v: uint8): uint8 =
  result = v - 1
  z.putFlag(fh, (v and 0x0F) == 0)
  z.putFlag(fp, v == 0x80)
  z.putFlag(fn, true)
  z.szp(result)

proc addHL(z: var EZ80, v: uint32) =
  ## ADD HL, rr — only C and H are affected. The width is this
  ## instruction's data mode: 16 bits in Z80 mode, 24 in ADL mode.
  let m = z.mask()
  let hl0 = z.hl
  let full = hl0 + v
  let half = (hl0 and (m shr 4)) + (v and (m shr 4))
  z.putFlag(fh, half > (m shr 4))
  z.putFlag(fc, full > m)
  z.putFlag(fn, false)
  z.hl = full and m

proc adcHL(z: var EZ80, v: uint32) =
  ## ADC HL, rr — the eZ80's 16/24-bit add with carry.
  let m = z.mask()
  let ci = ord((z.f and fc) != 0).uint32
  let hl0 = z.hl
  let full = hl0 + v + ci
  let res = full and m
  z.putFlag(fs, (res and (m shr 8)) != 0)
  z.putFlag(fz, res == 0)
  z.putFlag(fh, ((hl0 and 0x0F) + (v and 0x0F) + ci) > 0x0F)
  z.putFlag(fp, ((hl0 xor res) and (v xor res) and (m shr 8)) != 0)
  z.putFlag(fn, false)
  z.putFlag(fc, full > m)
  z.hl = res

proc sbcHL(z: var EZ80, v: uint32) =
  ## SBC HL, rr.
  let m = z.mask()
  let ci = ord((z.f and fc) != 0).uint32
  let hl0 = z.hl
  let full = hl0 + m - v - ci
  let res = full and m
  z.putFlag(fs, (res and (m shr 8)) != 0)
  z.putFlag(fz, res == 0)
  z.putFlag(fh, ((hl0 and 0x0F).int - (v and 0x0F).int - ci.int) < 0)
  z.putFlag(fp, ((hl0 xor v) and (hl0 xor res) and (m shr 8)) != 0)
  z.putFlag(fn, true)
  z.putFlag(fc, hl0 < v + ci)
  z.hl = res

# ---- rotates / shifts / DAA ------------------------------------------

proc rlca(z: var EZ80) =
  let c = (z.a and 0x80) != 0
  z.a = (z.a shl 1) or ord(c).uint8
  z.f = z.f and (not (fh or fn))
  z.putFlag(fc, c)

proc rrca(z: var EZ80) =
  let c = (z.a and 1) != 0
  z.a = (z.a shr 1) or (if c: 0x80'u8 else: 0'u8)
  z.f = z.f and (not (fh or fn))
  z.putFlag(fc, c)

proc rla(z: var EZ80) =
  let c = (z.a and 0x80) != 0
  let oldC = (z.f and fc) != 0
  z.a = (z.a shl 1) or ord(oldC).uint8
  z.f = z.f and (not (fh or fn))
  z.putFlag(fc, c)

proc rra(z: var EZ80) =
  let c = (z.a and 1) != 0
  let oldC = (z.f and fc) != 0
  z.a = (z.a shr 1) or (if oldC: 0x80'u8 else: 0'u8)
  z.f = z.f and (not (fh or fn))
  z.putFlag(fc, c)

proc daa(z: var EZ80) =
  let c0 = (z.f and fc) != 0
  let h0 = (z.f and fh) != 0
  let sub = (z.f and fn) != 0
  var corr: uint8 = 0
  if h0 or (z.a and 0x0F) > 9:
    corr = corr or 0x06
  if c0 or z.a > 0x99:
    corr = corr or 0x60
  let a0 = z.a
  if sub:
    z.a = z.a - corr
    z.putFlag(fh, (a0 and 0x0F) < (corr and 0x0F))
  else:
    z.a = z.a + corr
    z.putFlag(fh, (a0 and 0x0F) + (corr and 0x0F) > 0x0F)
  z.putFlag(fc, c0 or (a0 > 0x99))
  z.szp(z.a)

# ---- stack ---------------------------------------------------------------

proc push(z: var EZ80, v: uint32) =
  ## Push a value. The size is the data mode: two bytes in Z80 mode,
  ## three in ADL mode (the stack pointer is SPL there).
  let size = if z.dm: 3'u32 else: 2'u32
  z.sp = (z.sp - size) and 0x00FF_FFFF'u32
  if z.dm:
    z.wr24(z.sp, v)
  else:
    z.wr16(z.sp, v)

proc pop(z: var EZ80): uint32 =
  let size = if z.dm: 3'u32 else: 2'u32
  if z.dm:
    result = z.rd24(z.sp)
  else:
    result = z.rd16(z.sp)
  z.sp = (z.sp + size) and 0x00FF_FFFF'u32

# ---- CB page: RLC RRC RL RR SLA SRA SLL SRL, BIT, RES, SET ------------

proc doCB(z: var EZ80; ixMode: bool; dispVal: int): int =
  ## The CB page. With a DD/FD prefix the operand is (IX+d) or (IY+d).
  let sub = int(z.fetch8())
  let y = (sub shr 3) and 7  # bit number / rotate op
  let r = sub and 7          # target register (6 = (HL))
  ## The whole instruction's time, prefix included: 8 for a register, 15
  ## for (HL), 23 for (IX+d).
  result = if r == 6: 15 else: 8
  if ixMode:
    result = result + 8      # the DD/FD prefix and the displacement
  if (sub and 0xC0) == 0x40:  # BIT y, r
    var v: uint8
    if ixMode:
      v = z.mem[z.addr(z.ix + uint32(dispVal))]
    else:
      v = z.rIdx(r, false)
    let bitSet = ((v shr y) and 1) != 0
    z.putFlag(fz, not bitSet)
    z.putFlag(fp, not bitSet)  # P/V copies Z here (simple model)
    z.putFlag(fs, y == 7 and bitSet)
    z.putFlag(fh, true)
    z.putFlag(fn, false)
    return
  var v: uint8
  if ixMode:
    v = z.mem[z.addr(z.ix + uint32(dispVal))]
  else:
    v = z.rIdx(r, false)
  var c = false
  case sub and 0xC0
  of 0x00:  # rotate / shift
    case y
    of 0:  # RLC
      c = (v and 0x80) != 0
      v = (v shl 1) or ord(c).uint8
    of 1:  # RRC
      c = (v and 1) != 0
      v = (v shr 1) or (if c: 0x80'u8 else: 0'u8)
    of 2:  # RL
      c = (v and 0x80) != 0
      v = (v shl 1) or ord((z.f and fc) != 0).uint8
    of 3:  # RR
      c = (v and 1) != 0
      v = (v shr 1) or (if (z.f and fc) != 0: 0x80'u8 else: 0'u8)
    of 4:  # SLA
      c = (v and 0x80) != 0
      v = v shl 1
    of 5:  # SRA
      c = (v and 1) != 0
      v = (v shr 1) or (v and 0x80)
    of 6:  # SLL (undocumented)
      c = (v and 0x80) != 0
      v = (v shl 1) or 1'u8
    else:  # SRL
      c = (v and 1) != 0
      v = v shr 1
    z.putFlag(fc, c)
    z.f = z.f and (not (fh or fn))
    z.szp(v)
  of 0x80:  # RES y, r
    v = v and (not (1'u8 shl y))
  else:     # SET y, r
    v = v or (1'u8 shl y)
  if ixMode:
    z.mem[z.addr(z.ix + uint32(dispVal))] = v
  else:
    z.setR(r, false, v)

# ---- public API -------------------------------------------------------

proc reset*(z: var EZ80, entry: uint32 = 0) =
  ## Clear all state (including memory) and set PC to `entry`.
  z = EZ80(sp: 0xFFFF'u32, pc: entry)
  z.mem = newSeq[uint8](1 shl 24)

proc portOut*(z: var EZ80, port: uint8, v: uint8) =
  ## Console: every OUT writes a character (13 = newline).
  z.outBuf.add chr(v)
  if z.interactive:
    if v == 13:
      stdout.write "\n"
    elif v != 12:                   # form feed (CLS): skip on a stream
      stdout.write chr(v)
    flushFile(stdout)

proc portIn*(z: var EZ80, port: uint8): uint8 =
  ## Console: port 1 = next char, port 2 = status (1 = char available).
  if port == 2 and z.inPos >= z.inBuf.len and z.interactive:
    if stdin.endOfFile:
      z.inBuf.add "BYE\r"           # EOF: politely stop the interpreter
      z.interactive = false
    else:
      z.inBuf.add stdin.readLine()
      z.inBuf.add '\r'
  if port == 1:
    if z.inPos < z.inBuf.len:
      result = z.inBuf[z.inPos].uint8
      inc z.inPos
  else:
    result = if z.inPos < z.inBuf.len: 1 else: 0

proc load*(z: var EZ80, at: uint32, code: openArray[uint8]) =
  ## Copy machine code into memory at `at`.
  for i, b in code:
    z.mem[int(at) + i] = b

proc `$`*(z: EZ80): string =
  &"AF={z.af:04X} BC={z.bc:04X} DE={z.de:04X} HL={z.hl:04X} SP={z.sp:04X} PC={z.pc:04X} {z.cycles} T"


# ---- helpers the pages share ----------------------------------------------

proc readPair(z: EZ80; ad: uint32): uint32 {.inline.} =
  ## Read a 16- or 24-bit value from memory, per the data mode.
  if z.dm: z.rd24(ad) else: z.rd16(ad)

proc writePair(z: var EZ80; ad: uint32, v: uint32) {.inline.} =
  if z.dm: z.wr24(ad, v) else: z.wr16(ad, v)

proc mulPairs(z: EZ80; p1, p2: int): uint32 =
  ## MLT: a 16x16 multiply into 32 bits, for the pair register and SP.
  let a = z.pairGet(p1, false) and 0xFFFF'u32
  let b = z.pairGet(p2, false) and 0xFFFF'u32
  result = a * b

proc tstAcc(z: var EZ80, v: uint8) =
  ## TST: A AND v, with the flags set and nothing stored.
  let r = z.a and v
  z.putFlag(fs, (r and 0x80) != 0)
  z.putFlag(fz, r == 0)
  z.putFlag(fh, true)
  z.putFlag(fp, evenParity(r))
  z.putFlag(fn, false)
  z.putFlag(fc, false)

# ---- the ED page ---------------------------------------------------------

proc blockTransfer(z: var EZ80, sub: int): int =
  ## LDI, LDD, LDIR, LDDR.
  let step = if (sub and 0x08) != 0: -1 else: 1
  let repeat = (sub and 0x10) != 0
  var count = z.pairGet(0, false) and 0xFFFF'u32
  while true:
    ## LDIR copies (HL) to (DE): HL is the source, DE the destination.
    let src = z.addr(z.pairGet(2, false))
    let dst = z.addr(z.pairGet(1, false))
    z.mem[dst] = z.mem[src]
    z.pairSet(1, false, (z.pairGet(1, false) + uint32(step)) and z.mask())
    z.pairSet(2, false, (z.pairGet(2, false) + uint32(step)) and z.mask())
    count = (count - 1) and 0xFFFF'u32
    z.pairSet(0, false, count)
    z.putFlag(fp, count != 0)
    z.putFlag(fn, false)
    if not (repeat and count != 0):
      break
  result = if repeat: 21 else: 16

proc blockCompare(z: var EZ80, sub: int): int =
  ## CPI, CPD, CPIR, CPDR.
  let step = if (sub and 0x08) != 0: -1 else: 1
  let repeat = (sub and 0x10) != 0
  var count = z.pairGet(0, false) and 0xFFFF'u32
  while true:
    let v = z.mem[z.addr(z.pairGet(2, false))]
    z.subA(v, false, false)                 # the flags, but A is not stored
    z.pairSet(2, false, (z.pairGet(2, false) + uint32(step)) and z.mask())
    count = (count - 1) and 0xFFFF'u32
    z.pairSet(0, false, count)
    z.putFlag(fp, count != 0)
    if not (repeat and count != 0 and (z.f and fz) == 0):
      break
  result = if repeat: 21 else: 16

proc blockInput(z: var EZ80, sub: int): int =
  ## INI, IND, INIR, INDR — and the eZ80's INIM, INIMR, INDM, INDMR and
  ## INIRX, INDRX.
  let step = if (sub and 0x08) != 0: -1 else: 1
  let repeat = (sub and 0x10) != 0
  let immediate = (sub and 0xC0) == 0x80     # INIM/INIMR/INDM/INDMR
  let stationary = (sub and 0xC0) == 0xC0    # INIRX/INDRX: the port is DE
  var count = z.pairGet(0, false) and 0xFFFF'u32
  while true:
    var port: uint8
    if immediate:
      port = z.c
    elif stationary:
      port = (z.pairGet(1, false) and 0xFF'u32).uint8
    else:
      port = (z.pairGet(0, false) and 0xFF'u32).uint8
    let v = z.portIn(port)
    z.mem[z.addr(z.pairGet(2, false))] = v
    if immediate:
      z.c = z.c + 1
    z.pairSet(2, false, (z.pairGet(2, false) + uint32(step)) and z.mask())
    if stationary:
      count = (count - 1) and 0xFFFF'u32
      z.pairSet(0, false, count)
    else:
      z.b = z.b - 1
    z.putFlag(fz, (if stationary: count else: z.b.uint32) == 0)
    z.putFlag(fn, (v and 0x80) != 0)
    var more = false
    if repeat:
      more = (if stationary: count != 0 else: z.b != 0)
    if not more:
      break
  result = if repeat: 21 else: 16

proc blockOutput(z: var EZ80, sub: int): int =
  ## OUTI, OUTD, OTIR, OTDR — and the eZ80's OTIM, OTIMR, OTDM, OTDMR
  ## and OTIRX, OTDRX.
  let step = if (sub and 0x08) != 0: -1 else: 1
  let repeat = (sub and 0x10) != 0
  let immediate = (sub and 0xC0) == 0x80
  let stationary = (sub and 0xC0) == 0xC0
  var count = z.pairGet(0, false) and 0xFFFF'u32
  while true:
    let v = z.mem[z.addr(z.pairGet(2, false))]
    var port: uint8
    if immediate:
      port = z.c
    elif stationary:
      port = (z.pairGet(1, false) and 0xFF'u32).uint8
    else:
      port = (z.pairGet(0, false) and 0xFF'u32).uint8
    z.portOut(port, v)
    if immediate:
      z.c = z.c + 1
    z.pairSet(2, false, (z.pairGet(2, false) + uint32(step)) and z.mask())
    if stationary:
      count = (count - 1) and 0xFFFF'u32
      z.pairSet(0, false, count)
    else:
      z.b = z.b - 1
    z.putFlag(fz, (if stationary: count else: z.b.uint32) == 0)
    z.putFlag(fn, (v and 0x80) != 0)
    var more = false
    if repeat:
      more = (if stationary: count != 0 else: z.b != 0)
    if not more:
      break
  result = if repeat: 21 else: 16

proc doED(z: var EZ80): int =
  ## The ED page: the Z80's block transfers, block I/O, interrupt and
  ## refresh registers — plus the eZ80's own instructions, which reuse the
  ## Z80's *undocumented* opcodes (ED 42/52/62/72 for SBC HL,rr and
  ## ED 4C/5C/6C/7C for MLT) and add LEA, TST, PEA and the immediate
  ## block-I/O forms.
  let sub = int(z.fetch8())
  let m = z.mask()
  case sub
  of 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78:   # IN r,(C)
    z.a = z.portIn((z.pairGet(0, false) and 0xFF'u32).uint8)
    result = 12
  of 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79:   # OUT (C),r
    z.portOut((z.pairGet(0, false) and 0xFF'u32).uint8,
              z.rIdx((sub shr 3) and 7, false))
    result = 12
  of 0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x38:       # IN0 r,(n)
    z.a = z.portIn(z.fetch8())
    result = 12
  of 0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x39:       # OUT0 (n),r
    let n = z.fetch8()
    z.portOut(n, z.rIdx((sub shr 3) and 7, false))
    result = 12
  of 0x42: z.sbcHL(z.pairGet(0, false))            # SBC HL,BC
  of 0x52: z.sbcHL(z.pairGet(1, false))            # SBC HL,DE
  of 0x62: z.sbcHL(z.pairGet(2, false))            # SBC HL,HL
  of 0x72: z.sbcHL(z.pairGet(3, false))            # SBC HL,SP
  of 0x4A: z.adcHL(z.pairGet(0, false))            # ADC HL,BC
  of 0x5A: z.adcHL(z.pairGet(1, false))
  of 0x6A: z.adcHL(z.pairGet(2, false))
  of 0x7A: z.adcHL(z.pairGet(3, false))
  of 0x43: z.writePair(z.addr(z.fetchN()), z.pairGet(0, false)); result = 20   # LD (Mmn),BC
  of 0x53: z.writePair(z.addr(z.fetchN()), z.pairGet(1, false)); result = 20
  of 0x63: z.writePair(z.addr(z.fetchN()), z.pairGet(2, false)); result = 20
  of 0x73: z.writePair(z.addr(z.fetchN()), z.pairGet(3, false)); result = 20
  of 0x4B: z.pairSet(0, false, z.readPair(z.addr(z.fetchN()))); result = 20   # LD BC,(Mmn)
  of 0x5B: z.pairSet(1, false, z.readPair(z.addr(z.fetchN()))); result = 20
  of 0x6B: z.pairSet(2, false, z.readPair(z.addr(z.fetchN()))); result = 20
  of 0x7B: z.pairSet(3, false, z.readPair(z.addr(z.fetchN()))); result = 20
  of 0x07: z.pairSet(0, false, z.readPair(z.addr(z.hl)))           # LD BC,(HL)
  of 0x17: z.pairSet(1, false, z.readPair(z.addr(z.hl)))
  of 0x27: z.pairSet(2, false, z.readPair(z.addr(z.hl)))
  of 0x31: z.pairSet(2, false, z.readPair(z.addr(z.hl)))           # LD IY,(HL)
  of 0x37: z.pairSet(2, false, z.readPair(z.addr(z.hl)))           # LD IX,(HL)

  of 0x0F: z.writePair(z.addr(z.hl), z.pairGet(0, false))          # LD (HL),BC
  of 0x1F: z.writePair(z.addr(z.hl), z.pairGet(1, false))
  of 0x2F: z.writePair(z.addr(z.hl), z.pairGet(2, false))
  of 0x3E: z.writePair(z.addr(z.hl), z.pairGet(2, false))          # LD (HL),IY
  of 0x3F: z.writePair(z.addr(z.hl), z.pairGet(2, false))          # LD (HL),IX
  of 0x44:                                           # NEG
    let v = z.a
    z.a = 0
    z.subA(v, false, true)
  of 0x45:                                           # RETN
    z.pc = z.pop()
    z.ief2 = z.ief1
  of 0x4D:                                           # RETI
    z.pc = z.pop()
    z.ief2 = z.ief1
  of 0x46: z.im = 0
  of 0x56: z.im = 1
  of 0x5E: z.im = 2
  of 0x47: z.i = z.a
  of 0x4F: z.r = z.a
  of 0x57: z.a = z.i
  of 0x5F: z.a = z.r
  of 0xC7: z.i = (z.pairGet(2, false) and 0xFF'u32).uint8
  of 0xD7: z.pairSet(2, false, z.i.uint32)
  of 0x67:                                           # RRD
    let ad = z.addr(z.hl)
    let v = z.mem[ad]
    z.mem[ad] = (v shr 4) or (z.a shl 4)
    z.a = (z.a and 0xF0) or (v and 0x0F)
    z.szp(z.a)
  of 0x6F:                                           # RLD
    let ad = z.addr(z.hl)
    let v = z.mem[ad]
    z.mem[ad] = (v shl 4) or (z.a and 0x0F)
    z.a = (z.a and 0xF0) or (v shr 4)
    z.szp(z.a)
  of 0x4C:                                           # MLT BC
    let p = z.mulPairs(0, 2)
    z.pairSet(1, false, p shr 16)
    z.pairSet(2, false, p and 0xFFFF'u32)
  of 0x5C:                                           # MLT DE
    let p = z.mulPairs(1, 2)
    z.pairSet(1, false, p shr 16)
    z.pairSet(2, false, p and 0xFFFF'u32)
  of 0x6C:                                           # MLT HL
    let p = z.mulPairs(2, 2)
    z.pairSet(1, false, p shr 16)
    z.pairSet(2, false, p and 0xFFFF'u32)
  of 0x7C:                                           # MLT SP
    let p = z.mulPairs(3, 2)
    z.pairSet(1, false, p shr 16)
    z.pairSet(2, false, p and 0xFFFF'u32)
  of 0x02, 0x12, 0x22:                               # LEA BC/DE/HL,IX+d
    let d = z.disp()
    z.pairSet((sub shr 4) and 3, false, z.ix + uint32(d))
  of 0x03, 0x13, 0x23:                               # LEA BC/DE/HL,IY+d
    let d = z.disp()
    z.pairSet((sub shr 4) and 3, false, z.iy + uint32(d))
  of 0x32:                                           # LEA IX,IX+d
    let d = z.disp()
    z.ix = z.ix + uint32(d)
  of 0x33:                                           # LEA IY,IY+d
    let d = z.disp()
    z.iy = z.iy + uint32(d)
  of 0x54:                                           # LEA IX,IY+d
    let d = z.disp()
    z.ix = z.iy + uint32(d)
  of 0x55:                                           # LEA IY,IX+d
    let d = z.disp()
    z.iy = z.ix + uint32(d)
  of 0x65:                                           # PEA IX+d
    let d = z.disp()
    z.push(z.ix + uint32(d))
  of 0x66:                                           # PEA IY+d
    let d = z.disp()
    z.push(z.iy + uint32(d))
  of 0x34:                                           # TST A,(HL)
    z.tstAcc(z.mem[z.addr(z.hl)])
  of 0x64:                                           # TST A,n
    z.tstAcc(z.fetch8())
  of 0x74:                                           # TSTIO n
    z.tstAcc(z.portIn(z.fetch8()))
  of 0x6D: z.mbase = z.a                             # LD MB,A
  of 0x6E: z.a = z.mbase                             # LD A,MB
  of 0x7D: z.madl = true                            # STMIX
  of 0x7E: z.madl = false                           # RSMIX
  of 0x76: z.sleeping = true                        # SLP
  of 0xA0, 0xA8, 0xB0, 0xB8:                        # LDI/LDD/LDIR/LDDR
    return z.blockTransfer(sub)
  of 0xA1, 0xA9, 0xB1, 0xB9:                        # CPI/CPD/CPIR/CPDR
    return z.blockCompare(sub)

  of 0xA2, 0xAA, 0xB2, 0xBA, 0x82, 0x8A, 0x92, 0x9A,
     0xC2, 0xCA:                                    # INI/IND/INIR/INDR and
    return z.blockInput(sub)                       # the eZ80's INIM/INIMR/
  of 0xA3, 0xAB, 0xB3, 0xBB, 0x83, 0x8B, 0x93, 0x9B,
     0xC3, 0xCB:                                    # OUTI/OUTD/OTIR/OTDR and
    return z.blockOutput(sub)                      # the eZ80's OTIM/OTIMR/
  else: discard
  ## TST A,r — ED 04, 0C, 14, 1C, 24, 2C, 34, 3C.
  if (sub and 0xC7) == 0x04 and ((sub shr 3) and 7) != 6:
    z.tstAcc(z.rIdx((sub shr 3) and 7, false))
  result = 8

# ---- the DD/FD pages -----------------------------------------------------

proc doIndexed(z: var EZ80; isIY: bool): int =
  ## The DD and FD pages: the same instructions with IX or IY in place of
  ## HL, and the Z80's undocumented IXH/IXL register forms.
  let op = int(z.fetch8())
  let m = z.mask()
  var t = 8
  when defined(ez80Debug):
    echo "  doIndexed op=", op, " isIY=", isIY, " pc=", z.pc
  # The index register and its high/low bytes. The eZ80 keeps IX and IY
  # in one place, so the page is written once and told which one it is.
  var ixv: uint32 = if isIY: z.iy else: z.ix
  template setIxv(v: uint32) =
    ## The argument is bound once: a template substitutes its argument at
    ## every use, so an argument with a side effect — "LD IX, nn" — was
    ## evaluated twice and the program counter moved four bytes instead of
    ## two.
    let vv = v
    if isIY: z.iy = vv else: z.ix = vv
    ixv = vv
  template ixh(): uint8 = (if isIY: z.iy else: z.ix).shr(8).uint8
  template ixl(): uint8 = (if isIY: z.iy else: z.ix).uint8
  template setIxh(v: uint8) =
    if isIY: z.iy = (z.iy and 0xFFFF'u32) or (v.uint32 shl 8)
    else: z.ix = (z.ix and 0xFFFF'u32) or (v.uint32 shl 8)
  template setIxl(v: uint8) =
    if isIY: z.iy = (z.iy and 0xFFFF_FF00'u32) or v.uint32
    else: z.ix = (z.ix and 0xFFFF_FF00'u32) or v.uint32
  case op
  of 0x09:                                       # ADD IX,BC
    let v = z.pairGet(0, false)
    let base = ixv
    let full = base + v
    z.putFlag(fh, ((base and (m shr 4)) + (v and (m shr 4))) > (m shr 4))
    z.putFlag(fc, full > m)
    z.putFlag(fn, false)
    setIxv(full and m)
    t = 15
  of 0x21:                                       # LD IX,nn
    setIxv(z.fetchN() and m)
    t = 14
  of 0x22:                                       # LD (nn),IX
    z.writePair(z.addr(z.fetchN()), ixv)
    t = 20
  of 0x23:                                       # INC IX
    setIxv((ixv + 1) and m)
    t = 10
  of 0x2A:                                       # LD IX,(nn)
    setIxv(z.readPair(z.addr(z.fetchN())) and m)
    t = 20
  of 0x2B:                                       # DEC IX
    setIxv((ixv - 1) and m)
    t = 10
  of 0x39:                                       # ADD IX,SP
    let v = z.pairGet(3, false)
    let base = ixv
    let full = base + v
    z.putFlag(fh, ((base and (m shr 4)) + (v and (m shr 4))) > (m shr 4))
    z.putFlag(fc, full > m)
    z.putFlag(fn, false)
    setIxv(full and m)
    t = 15
  of 0x24, 0x34:                                 # INC (IX+d)
    let d = z.disp()
    let ad = z.addr(ixv + uint32(d))
    z.mem[ad] = z.inc8(z.mem[ad])
    t = 23
  of 0x25, 0x35:                                 # DEC (IX+d)
    let d = z.disp()
    let ad = z.addr(ixv + uint32(d))
    z.mem[ad] = z.dec8(z.mem[ad])
    t = 23
  of 0x36:                                       # LD (IX+d),n
    let d = z.disp()
    let n = z.fetch8()
    z.mem[z.addr(ixv + uint32(d))] = n
    t = 19
  of 0xE1:                                       # POP IX
    setIxv(z.pop() and m)
    t = 14
  of 0xE5:                                       # PUSH IX
    z.push(ixv)
    t = 15
  of 0xE3:                                       # EX (SP),IX
    let v = z.readPair(z.sp)
    z.writePair(z.sp, ixv)
    setIxv(v and m)
    t = 23
  of 0xE9:                                       # JP (IX)
    z.pc = z.addr(ixv)
    t = 8
  of 0xF9:                                       # LD SP,IX
    z.sp = ixv and m
    t = 10
  of 0xCB:
    ## The DD CB dd kk form: the shift or bit operation acts on (IX+d).
    let d = z.disp()
    t = z.doCB(true, d)
  of 0x40..0x7F:
    let d = z.disp()
    let ad = z.addr(ixv + uint32(d))
    when defined(ez80Debug):
      echo "    range branch: d=", d, " ad=", ad, " ixv=", ixv, " mem=", z.mem[ad]
    let dest = (op shr 3) and 7
    let src = op and 7
    if src == 4 or src == 5:                    # LD r,IXH/IXL (undocumented)
      let v = (if src == 4: ixh() else: ixl())
      z.setR(dest, false, v)
      t = 8
    elif dest == 4 or dest == 5:                # LD IXH/IXL,r (undocumented)
      let v = z.rIdx(src, false)
      if dest == 4: setIxh(v) else: setIxl(v)
      t = 8
    elif src == 6:                               # LD r,(IX+d)
      z.setR(dest, false, z.mem[ad])
      t = 19
    else:                                        # LD (IX+d),r
      z.mem[ad] = z.rIdx(dest, false)
      t = 19
  of 0x80..0xBF:                                 # ALU A,(IX+d)
    let d = z.disp()
    z.alu((op shr 3) and 7, z.mem[z.addr(ixv + uint32(d))])
    t = 19
  else: discard
  result = t

# ---- interrupts -----------------------------------------------------------

proc serviceInterrupt(z: var EZ80): int =
  ## Take a pending interrupt, if one is accepted.
  ##
  ## The non-maskable one first: it is not masked by EI/DI. Then the
  ## maskable one, which needs IEF1 and takes its vector from the
  ## interrupt mode.
  if z.nmi:
    z.nmi = false
    z.ief1 = false
    z.ief2 = false
    z.push(z.pc)
    z.pc = 0x000066'u32
    return 11
  if z.irq and z.ief1:
    z.ief1 = false
    z.ief2 = false
    z.push(z.pc)
    case z.im
    of 1:
      z.pc = 0x000038'u32
    of 2:
      let vec = z.rd8(z.addr((z.i.uint32 shl 8) or z.irqVector.uint32))
      z.pc = z.addr((z.i.uint32 shl 8) or vec.uint32)
    else:
      z.pc = z.addr(z.irqVector.uint32)
    return 13
  result = 0

# ---- one instruction ------------------------------------------------------

proc step*(z: var EZ80): int =
  ## Execute one instruction. Returns the T-states consumed.
  if z.halted:
    z.cycles += 4
    return 4
  if z.sleeping:
    z.cycles += 4
    return 4
  let irq = z.serviceInterrupt()
  if irq > 0:
    z.cycles += irq.uint64
    return irq
  ## The memory-mode suffix prefixes. They cost one T-state and say what
  ## the instruction that follows does with registers and immediates.
  var op = int(z.fetch8())
  var t = 0
  var suffixed = false
  if op == int(pfxSIS) or op == int(pfxLIS) or op == int(pfxSIL) or op == int(pfxLIL):
    suffixed = true
    case op
    of int(pfxSIS): z.dm = false; z.sm = false
    of int(pfxLIS): z.dm = true;  z.sm = false
    of int(pfxSIL): z.dm = false; z.sm = true
    else:            z.dm = true;  z.sm = true
    t = 1
    op = int(z.fetch8())
  else:
    z.dm = z.adl
    z.sm = z.adl
  let m = z.mask()
  t += tStates[op]                # the instruction's own cost
  case op
  of 0x00: discard  # NOP
  of 0x08:  # EX AF, AF'
    swap z.a, z.a2
    swap z.f, z.f2
  of 0x10:  # DJNZ d
    z.b = z.b - 1
    let d = z.disp()
    if z.b != 0:
      z.pc = (z.pc + uint32(d)) and 0x00FF_FFFF'u32
      t += 5
  of 0x18:  # JR d
    let d = z.disp()
    z.pc = (z.pc + uint32(d)) and 0x00FF_FFFF'u32
  of 0x20, 0x28, 0x30, 0x38:  # JR cc, d
    let d = z.disp()
    if z.cond((op shr 3) and 3):
      z.pc = (z.pc + uint32(d)) and 0x00FF_FFFF'u32
      t += 5
  of 0x01, 0x11, 0x21, 0x31:  # LD rr, nn
    z.rpSet((op shr 4) and 3, z.fetchN() and m)
  of 0x02, 0x12:  # LD (BC/DE), A
    z.wr8(z.addr(z.rpGet((op shr 4) and 3)), z.a)
  of 0x0A, 0x1A:  # LD A, (BC/DE)
    z.a = z.rd8(z.addr(z.rpGet((op shr 4) and 3)))
  of 0x22:  # LD (nn), HL
    z.writePair(z.addr(z.fetchN()), z.hl)
  of 0x2A:  # LD HL, (nn)
    z.hl = z.readPair(z.addr(z.fetchN())) and m
  of 0x32:  # LD (nn), A
    z.wr8(z.addr(z.fetchN()), z.a)
  of 0x3A:  # LD A, (nn)
    z.a = z.rd8(z.addr(z.fetchN()))
  of 0x03, 0x13, 0x23, 0x33:  # INC rr
    let p = (op shr 4) and 3
    z.rpSet(p, (z.rpGet(p) + 1) and m)
  of 0x0B, 0x1B, 0x2B, 0x3B:  # DEC rr
    let p = (op shr 4) and 3
    z.rpSet(p, (z.rpGet(p) - 1) and m)
  of 0x09, 0x19, 0x29, 0x39:  # ADD HL, rr
    z.addHL(z.rpGet((op shr 4) and 3))
  of 0x04..0x06, 0x0C..0x0E, 0x14..0x16, 0x1C..0x1E,
     0x24..0x26, 0x2C..0x2E, 0x34..0x36, 0x3C..0x3E:
    let i = (op shr 3) and 7
    case op and 7
    of 4: z.setR(i, false, z.inc8(z.rIdx(i, false)))  # INC r
    of 5: z.setR(i, false, z.dec8(z.rIdx(i, false)))  # DEC r
    else: z.setR(i, false, z.fetch8())         # LD r, n
  of 0x07: z.rlca()
  of 0x0F: z.rrca()
  of 0x17: z.rla()
  of 0x1F: z.rra()
  of 0x27: z.daa()
  of 0x2F:  # CPL
    z.a = not z.a
    z.f = z.f or fh or fn
  of 0x37:  # SCF
    z.f = (z.f and (not (fh or fn))) or fc
  of 0x3F:  # CCF
    let wasC = (z.f and fc) != 0
    z.f = z.f and (not (fh or fn)) and (not fc)
    if wasC:
      z.f = z.f or fh
    else:
      z.f = z.f or fc
  of 0x40..0x7F:  # LD r, r' / HALT
    if op == 0x76:
      z.halted = true
    else:
      z.setR((op shr 3) and 7, false, z.rIdx(op and 7, false))
  of 0x80..0xBF:  # ALU A, r
    z.alu((op shr 3) and 7, z.rIdx(op and 7, false))
  of 0xC0..0xFF:
    let y = (op shr 3) and 7
    case op and 7
    of 0:  # RET cc
      if z.cond(y):
        z.pc = z.pop()
        if suffixed: z.adl = z.dm
      else:
        t -= 6
    of 1:
      if (y and 1) == 0:  # POP rp2
        let v = z.pop()
        z.rp2Set(y shr 1, v)
      else:
        case y shr 1
        of 0: z.pc = z.pop()  # RET
        of 1:  # EXX
          swap z.b, z.b2
          swap z.c, z.c2
          swap z.d, z.d2
          swap z.e, z.e2
          swap z.h, z.h2
          swap z.l, z.l2
          swap z.bcu, z.bcu2
          swap z.deu, z.deu2
          swap z.hlu, z.hlu2
        of 2: z.pc = z.addr(z.hl)  # JP (HL)
        else: z.sp = z.hl  # LD SP, HL
    of 2:  # JP cc, nn
      let a = z.fetchN()
      if z.cond(y):
        z.pc = z.addr(a)
        if suffixed: z.adl = z.dm
    of 3:
      case y
      of 0:  # JP nn
        let a = z.fetchN()
        z.pc = z.addr(a)
        if suffixed: z.adl = z.dm
      of 1: t = z.doCB(false, 0)                    # CB page
      of 2:                                 # OUT (n), A
        let port = z.fetch8()
        z.portOut(port, z.a)
      of 3:                                 # IN A, (n)
        let port = z.fetch8()
        z.a = z.portIn(port)
      of 4:  # EX (SP), HL
        let v = z.readPair(z.sp)
        z.writePair(z.sp, z.hl)
        z.hl = v and m
      of 5:  # EX DE, HL
        let tmp = z.de
        z.de = z.hl
        z.hl = tmp
      of 6: z.ief1 = false  # DI
      else: z.ief1 = true   # EI
    of 4:  # CALL cc, nn
      let a = z.fetchN()
      if z.cond(y):
        z.push(z.pc)
        z.pc = z.addr(a)
        if suffixed: z.adl = z.dm
      else:
        t -= 7
    of 5:
      if (y and 1) == 0:  # PUSH rp2
        z.push(z.rp2Get(y shr 1))
      elif y == 1:        # CALL nn
        let a = z.fetchN()
        z.push(z.pc)
        z.pc = z.addr(a)
        if suffixed: z.adl = z.dm
      elif y == 5:        # ED page
        t = z.doED()
      elif y == 3:        # DD page
        t = z.doIndexed(false)
      elif y == 4:        # FD page
        t = z.doIndexed(true)
      else:
        raise newException(EZ80Error,
          &"opcode 0x{op:02X} is not defined on the eZ80 (pc=0x{z.pc:04X})")
    of 6:  # ALU A, n
      z.alu(y, z.fetch8())
    of 7:  # RST y*8
      z.push(z.pc)
      z.pc = z.addr(uint32(y * 8))
      if suffixed: z.adl = z.dm
    else: discard  # unreachable
  else:
    raise newException(EZ80Error,
      &"unimplemented opcode 0x{op:02X} at 0x{z.pc - 1:04X}")
  z.cycles += t.uint64
  result = t

proc run*(z: var EZ80, maxCycles: uint64 = 10_000_000): uint64 =
  ## Step until HALT (or the T-state budget runs out).
  while not z.halted and result < maxCycles:
    result += z.step().uint64
