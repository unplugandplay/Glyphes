## ez80asm.nim — a small two-pass assembler for the eZ80.
##
## The Z80 instruction set (the unprefixed, CB, ED, DD and FD pages) plus
## the eZ80's own instructions, plus the four memory-mode suffixes.
##
## ## The suffixes
##
## An eZ80 instruction may carry one of four suffixes, and the suffix is
## part of the mnemonic:
##
##     .SIS   16-bit registers, 2-byte immediates      (prefix 0x40)
##     .LIS   24-bit registers, 2-byte immediates      (prefix 0x49)
##     .SIL   16-bit registers, 3-byte immediates      (prefix 0x52)
##     .LIL   24-bit registers, 3-byte immediates      (prefix 0x5B)
##
## So `LD.LIL HL, 0x123456` assembles to 5B 21 56 34 12, and
## `LD.SIS HL, 0x1234` to 40 21 34 12.
##
## ## The ADL directive
##
## `.ASSUME ADL = 1` says the code is assembled for the ADL memory mode:
## the 16-bit immediate forms then take three bytes, and the 24-bit
## registers are the ones the instructions address. `.ASSUME ADL = 0`
## (the default) is the Z80's own convention.
##
## Directives: ORG, EQU, DB, DW, DL, DS, .ASSUME.
## Expressions: numbers (0x.., decimal), 'c' char literals, symbols, + -.
##
## Usage:  nim c -r ez80asm.nim -- input.asm output.bin

import std/[strutils, sequtils, os, strformat]

type
  Sym = object
    name: string
    val: int

var
  syms: seq[Sym]
  pc: int
  outp: seq[uint8]
  pass: int
  srcFile: string
  adl: bool          ## the assumed memory mode: ADL = 1 or Z80 = 0

proc err(line: int, msg: string) =
  quit &"{srcFile}:{line}: error: {msg}"

proc symLookup(n: string): int =
  for s in syms:
    if s.name == n:
      return s.val
  -1

proc define(n: string, v: int, line: int) =
  if pass == 1:
    if symLookup(n) >= 0:
      err(line, "duplicate symbol '" & n & "'")
    syms.add Sym(name: n, val: v)

# ---- expressions: term (('+'|'-') term)* --------------------------------

proc evalExpr(e: string, line: int): int =
  var i = 0
  var sign = 1
  result = 0
  while i < e.len:
    case e[i]
    of ' ':
      inc i
    of '+':
      inc i
    of '-':
      sign = -sign
      inc i
    of '\'':
      if i + 2 >= e.len or e[i + 2] != '\'':
        err(line, "bad char literal in " & e)
      result += sign * ord(e[i + 1])
      sign = 1
      inc i, 3
    of '0'..'9':
      var j = i
      var v = 0
      if e[i] == '0' and i + 1 < e.len and e[i + 1] in {'x', 'X'}:
        j = i + 2
        while j < e.len and e[j] in HexDigits:
          if e[j] in {'0'..'9'}:
            v = v * 16 + ord(e[j]) - ord('0')
          else:
            v = v * 16 + ord(toUpperAscii(e[j])) - ord('A') + 10
          inc j
      else:
        while j < e.len and e[j] in Digits:
          v = v * 10 + ord(e[j]) - ord('0')
          inc j
      result += sign * v
      sign = 1
      i = j
    else:
      if not (e[i] in Letters + {'_'}):
        err(line, "bad expression: " & e)
      var j = i
      var name = ""
      while j < e.len and e[j] in Letters + Digits + {'_'}:
        name.add e[j]
        inc j
      let v = symLookup(name)
      if v < 0:
        if pass == 2:
          err(line, "undefined symbol '" & name & "'")
        result += 0  # placeholder in pass 1
      else:
        result += sign * v
      sign = 1
      i = j

# ---- register / condition helpers ---------------------------------------

proc r8code(s: string): int =
  case s
  of "B": 0
  of "C": 1
  of "D": 2
  of "E": 3
  of "H": 4
  of "L": 5
  of "(HL)": 6
  of "A": 7
  else: -1

proc rpcode(s: string): int =
  case s
  of "BC": 0
  of "DE": 1
  of "HL": 2
  of "SP": 3
  else: -1

proc rp2code(s: string): int =
  case s
  of "BC": 0
  of "DE": 1
  of "HL": 2
  of "AF": 3
  else: -1

proc cccode(s: string): int =
  case s
  of "NZ": 0
  of "Z": 1
  of "NC": 2
  of "C": 3
  of "PO": 4
  of "PE": 5
  of "P": 6
  of "M": 7
  else: -1

proc isMem(s: string): bool =
  s.len >= 2 and s[0] == '(' and s[^1] == ')'

proc memArg(s: string, line: int): string =
  if not isMem(s):
    err(line, "expected (expr), got '" & s & "'")
  s[1 .. ^2]

proc bt(v: int): uint8 = uint8(v and 0xFF)

proc add16(res: var seq[uint8], v: int) =
  res.add bt(v)
  res.add bt(v shr 8)

proc add24(res: var seq[uint8], v: int) =
  res.add bt(v)
  res.add bt(v shr 8)
  res.add bt(v shr 16)

proc addImm(res: var seq[uint8], v: int) =
  ## An immediate or an address: three bytes in ADL mode, two in Z80 mode.
  if adl: add24(res, v) else: add16(res, v)

proc aluOp(res: var seq[uint8], base: int, arg: string, line: int) =
  let r = r8code(arg)
  if r >= 0:
    res.add bt(base + r)
  else:
    # immediate form: 0xC6 + kind*8, where base = 0x80 + kind*8
    res.add bt(base + 0x46)
    res.add bt(evalExpr(arg, line))

# ---- instruction encoding -----------------------------------------------

proc suffixPrefix(sfx: string, line: int): uint8 =
  ## The one-byte prefix a memory-mode suffix assembles to.
  case sfx
  of "SIS": 0x40'u8
  of "LIS": 0x49'u8
  of "SIL": 0x52'u8
  of "LIL": 0x5B'u8
  else:
    err(line, "unknown memory-mode suffix '." & sfx & "'")
    0'u8

proc encode(mnIn: string, args: seq[string], line: int): seq[uint8] =
  result = @[]
  ## A mnemonic may carry a memory-mode suffix: "LD.LIL".
  var mn = mnIn
  var sfx = ""
  let dot = mnIn.find('.')
  if dot >= 0:
    sfx = mnIn[dot + 1 .. ^1]
    mn = mnIn[0 ..< dot]
  if sfx.len > 0:
    result.add suffixPrefix(sfx, line)
  case mn

  of "LD":
    if args.len != 2:
      err(line, "LD needs 2 operands")
    let d = args[0]
    let s = args[1]
    block done:
      let rd = r8code(d)
      let rs = r8code(s)
      if d.toUpperAscii == "MB" and s.toUpperAscii == "A":
        result.add 0xED'u8
        result.add 0x6D'u8
        break done
      if d.toUpperAscii == "A" and s.toUpperAscii == "MB":
        result.add 0xED'u8
        result.add 0x6E'u8
        break done
      if rd >= 0 and rs >= 0:
        result.add bt(0x40 or (rd shl 3) or rs)
        break done
      if isMem(s):
        let m = memArg(s, line).toUpperAscii
        let dUp = d.toUpperAscii
        if dUp == "HL":
          result.add 0x2A'u8
          addImm(result, evalExpr(m, line))
          break done
        if dUp == "BC" or dUp == "DE" or dUp == "SP":
          result.add 0xED'u8
          result.add bt(0x4B or (rpcode(dUp) shl 4))
          add16(result, evalExpr(m, line))
          break done
        if m == "HL" and rd >= 0:
          result.add bt(0x40 or (rd shl 3) or 6)
          break done
        if rd == 7:
          if m == "BC": result.add 0x0A'u8; break done
          if m == "DE": result.add 0x1A'u8; break done
          result.add 0x3A'u8
          addImm(result, evalExpr(m, line))
          break done
        err(line, "bad LD " & d & "," & s)
      if isMem(d):
        let m = memArg(d, line).toUpperAscii
        let sUp = s.toUpperAscii
        if m == "HL" and rs >= 0:
          result.add bt(0x70 or rs)
          break done
        if m == "BC" and rs == 7: result.add 0x02'u8; break done
        if m == "DE" and rs == 7: result.add 0x12'u8; break done
        if sUp == "HL":
          result.add 0x22'u8
          addImm(result, evalExpr(m, line))
          break done
        if sUp == "BC" or sUp == "DE" or sUp == "SP":
          result.add 0xED'u8
          result.add bt(0x43 or (rpcode(sUp) shl 4))
          add16(result, evalExpr(m, line))
          break done
        if sUp == "A":
          result.add 0x32'u8
          addImm(result, evalExpr(m, line))
          break done
        result.add 0x36'u8
        result.add bt(evalExpr(s, line))
        break done
      if rd >= 0:
        result.add bt(0x06 or (rd shl 3))
        result.add bt(evalExpr(s, line))
        break done
      if d.toUpperAscii == "SP" and s.toUpperAscii == "HL":
        result.add 0xF9'u8
        break done
      let rd16 = rpcode(d)
      if rd16 >= 0:
        result.add bt(0x01 or (rd16 shl 4))
        addImm(result, evalExpr(s, line))
        break done
      err(line, "bad LD " & d & "," & s)

  of "ADD":
    if args[0].toUpperAscii == "HL":
      let rp = rpcode(args[1])
      if rp < 0 or rp == 3:
        err(line, "ADD HL needs BC/DE/HL")
      result.add bt(0x09 or (rp shl 4))
    else:
      if args[0].toUpperAscii != "A":
        err(line, "bad ADD")
      aluOp(result, 0x80, args[1], line)

  of "ADC":
    if args[0].toUpperAscii != "A":
      err(line, "ADC HL not supported (ED page)")
    aluOp(result, 0x88, args[1], line)

  of "SUB":
    if args[0].toUpperAscii == "HL":
      err(line, "SUB HL not supported (ED page)")
    if args[0].toUpperAscii == "A":
      aluOp(result, 0x90, args[1], line)
    else:
      aluOp(result, 0x90, args[0], line)

  of "SBC":
    if args[0].toUpperAscii == "HL":
      err(line, "SBC HL not supported (ED page)")
    if args[0].toUpperAscii == "A":
      aluOp(result, 0x98, args[1], line)
    else:
      aluOp(result, 0x98, args[0], line)

  of "AND", "XOR", "OR", "CP":
    let base = case mn
      of "AND": 0xA0
      of "XOR": 0xA8
      of "OR": 0xB0
      else: 0xB8
    if args[0].toUpperAscii == "A" and args.len > 1:
      aluOp(result, base, args[1], line)
    else:
      aluOp(result, base, args[0], line)

  of "INC", "DEC":
    let base = if mn == "INC": 0x04 else: 0x05
    let r = r8code(args[0])
    if r >= 0:
      result.add bt(base or (r shl 3))
    else:
      let rbase = if mn == "INC": 0x03 else: 0x0B
      let rp = rpcode(args[0])
      if rp < 0:
        err(line, "bad " & mn)
      result.add bt(rbase or (rp shl 4))

  of "JP":
    if args[0][0] == '(':
      result.add 0xE9'u8
    else:
      let cc = cccode(args[0])
      if cc >= 0:
        result.add bt(0xC2 or (cc shl 3))
        addImm(result, evalExpr(args[1], line))
      else:
        result.add 0xC3'u8
        addImm(result, evalExpr(args[0], line))

  of "JR":
    var target: string
    var opc: int
    if args.len == 1:
      opc = 0x18
      target = args[0]
    else:
      let cc = cccode(args[0])
      if cc < 0 or cc > 3:
        err(line, "bad JR condition")
      opc = 0x20 or (cc shl 3)
      target = args[1]
    let rel = evalExpr(target, line) - (pc + 2)
    if pass == 2 and rel notin -128 .. 127:
      err(line, "JR out of range")
    result.add bt(opc)
    result.add bt(rel)

  of "DJNZ":
    let rel = evalExpr(args[0], line) - (pc + 2)
    if pass == 2 and rel notin -128 .. 127:
      err(line, "DJNZ out of range")
    result.add 0x10'u8
    result.add bt(rel)

  of "CALL":
    let cc = cccode(args[0])
    if cc >= 0:
      result.add bt(0xC4 or (cc shl 3))
      addImm(result, evalExpr(args[1], line))
    else:
      result.add 0xCD'u8
      addImm(result, evalExpr(args[0], line))

  of "RET":
    if args.len == 0:
      result.add 0xC9'u8
    else:
      let cc = cccode(args[0])
      if cc < 0:
        err(line, "bad RET")
      result.add bt(0xC0 or (cc shl 3))

  of "PUSH":
    let rp = rp2code(args[0])
    if rp < 0: err(line, "bad PUSH")
    result.add bt(0xC5 or (rp shl 4))

  of "POP":
    let rp = rp2code(args[0])
    if rp < 0: err(line, "bad POP")
    result.add bt(0xC1 or (rp shl 4))

  of "EX":
    if args[0] == "DE" and args[1] == "HL": result.add 0xEB'u8
    elif isMem(args[0]) and args[1] == "HL": result.add 0xE3'u8
    elif args[0] == "AF" and args[1] == "AF'": result.add 0x08'u8
    else: err(line, "bad EX")

  of "IN":
    if args[0] != "A" or not isMem(args[1]):
      err(line, "only IN A,(n) supported")
    result.add 0xDB'u8
    result.add bt(evalExpr(memArg(args[1], line), line))

  of "OUT":
    if not isMem(args[0]) or args[1] != "A":
      err(line, "only OUT (n),A supported")
    result.add 0xD3'u8
    result.add bt(evalExpr(memArg(args[0], line), line))

  of "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL":
    let base = case mn
      of "RLC": 0x00
      of "RRC": 0x08
      of "RL": 0x10
      of "RR": 0x18
      of "SLA": 0x20
      of "SRA": 0x28
      of "SLL": 0x30
      else: 0x38
    let r = r8code(args[0])
    if r < 0:
      err(line, "bad " & mn & " operand")
    result.add 0xCB'u8
    result.add bt(base + r)

  of "BIT", "RES", "SET":
    let base = case mn
      of "BIT": 0x40
      of "RES": 0x80
      else: 0xC0
    let bit = evalExpr(args[0], line)
    let r = r8code(args[1])
    if r < 0 or bit notin 0 .. 7:
      err(line, "bad " & mn)
    result.add 0xCB'u8
    result.add bt(base + (bit shl 3) + r)

  of "LEA":
    ## LEA rr, IX+d / LEA rr, IY+d / LEA IX,IX+d / LEA IY,IY+d /
    ## LEA IX,IY+d / LEA IY,IX+d
    if args.len != 2:
      err(line, "LEA needs 2 operands")
    let dst = args[0].toUpperAscii
    let src = args[1].toUpperAscii
    ## The displacement is written as IX+5, IY-2 and so on.
    var disp = 0
    var base = ""
    if src.len > 2 and src[2] == '+' or (src.len > 2 and src[2] == '-'):
      base = src[0 .. 1]
      disp = evalExpr(src[2 .. ^1], line)
    result.add 0xED'u8
    if dst == "IX" or dst == "IY":
      ## LEA IX,IX+d (0x32), LEA IY,IY+d (0x33), LEA IX,IY+d (0x54),
      ## LEA IY,IX+d (0x55)
      var opc = 0x32'u8
      if dst == "IY" and base == "IY": opc = 0x33'u8
      elif dst == "IX" and base == "IY": opc = 0x54'u8
      elif dst == "IY" and base == "IX": opc = 0x55'u8
      result.add opc
      result.add bt(disp)
    else:
      let rp = rpcode(dst)
      if rp < 0 or rp == 3:
        err(line, "LEA needs BC, DE or HL")
      result.add bt(rp + 0x02)      ## BC 0x02, DE 0x12, HL 0x22
      result.add bt(disp)
  of "PEA":
    if args.len != 1:
      err(line, "PEA needs 1 operand")
    let a = args[0].toUpperAscii
    result.add 0xED'u8
    result.add (if a == "IY": 0x66'u8 else: 0x65'u8)
    let d = if a.len > 2 and a[2 .. ^1].startsWith("+"):
             evalExpr(a[3 .. ^1], line) else: 0
    result.add bt(d)
  of "MLT":
    ## MLT BC/DE/HL/SP: DE:HL = the product of the two register pairs.
    if args.len != 1:
      err(line, "MLT needs 1 operand")
    let rp = rpcode(args[0].toUpperAscii)
    if rp < 0:
      err(line, "MLT needs BC, DE, HL or SP")
    result.add 0xED'u8
    result.add bt(0x4C + (rp shl 4))
  of "TST":
    ## TST A,r / TST A,(HL) / TST A,n
    if args.len != 2 or args[0].toUpperAscii != "A":
      err(line, "TST takes A and a source")
    let s = args[1]
    if isMem(s) and s.toUpperAscii == "(HL)":
      result.add 0xED'u8
      result.add 0x34'u8
    elif s.len > 0 and s[0] in Digits:
      result.add 0xED'u8
      result.add 0x64'u8
      result.add bt(evalExpr(s, line))
    else:
      let r = r8code(s)
      if r < 0:
        err(line, "bad TST source " & s)
      result.add 0xED'u8
      result.add bt(0x04 or (r shl 3))
  of "TSTIO":
    if args.len != 1:
      err(line, "TSTIO needs 1 operand")
    result.add 0xED'u8
    result.add 0x74'u8
    result.add bt(evalExpr(args[0], line))
  of "IN0":
    if args.len != 2:
      err(line, "IN0 needs 2 operands")
    let r = r8code(args[0])
    if r < 0:
      err(line, "IN0 needs a register")
    result.add 0xED'u8
    result.add bt(0x00 + (r shl 3))
    result.add bt(evalExpr(memArg(args[1], line), line))
  of "OUT0":
    if args.len != 2:
      err(line, "OUT0 needs 2 operands")
    let r = r8code(args[1])
    if r < 0:
      err(line, "OUT0 needs a register")
    result.add 0xED'u8
    result.add bt(0x01 + (r shl 3))
    result.add bt(evalExpr(memArg(args[0], line), line))
  of "INIM", "INIMR", "INDM", "INDMR", "OTIM", "OTIMR", "OTDM", "OTDMR",
     "INIRX", "INDRX", "OTIRX", "OTDRX":
    ## The eZ80's block I/O forms.
    let base = case mn
      of "INIM": 0x82'u8
      of "INIMR": 0x92'u8
      of "INDM": 0x8A'u8
      of "INDMR": 0x9A'u8
      of "OTIM": 0x83'u8
      of "OTIMR": 0x93'u8
      of "OTDM": 0x8B'u8
      of "OTDMR": 0x9B'u8
      of "INIRX": 0xC2'u8
      of "INDRX": 0xCA'u8
      of "OTIRX": 0xC3'u8
      else: 0xCBu8
    result.add 0xED'u8
    result.add base
  of "NOP": result.add 0x00'u8
  of "HALT": result.add 0x76'u8
  of "DI": result.add 0xF3'u8
  of "EI": result.add 0xFB'u8
  of "CPL": result.add 0x2F'u8
  of "SCF": result.add 0x37'u8
  of "CCF": result.add 0x3F'u8
  of "DAA": result.add 0x27'u8
  of "RLCA": result.add 0x07'u8
  of "RRCA": result.add 0x0F'u8
  of "RLA": result.add 0x17'u8
  of "RRA": result.add 0x1F'u8

  else:
    err(line, "unknown mnemonic '" & mn & "'")

# ---- line parsing -------------------------------------------------------

proc stripComment(s: string): string =
  var inStr = false
  var inChr = false
  for i, c in s:
    if c == '"':
      inStr = not inStr
    elif c == '\'':
      inChr = not inChr
    if c == ';' and not inStr and not inChr:
      return s[0 ..< i]
  s

proc splitArgs(s: string): seq[string] =
  ## Split on top-level commas (respecting quotes).
  result = @[]
  var cur = ""
  var inStr = false
  var inChr = false
  var depth = 0
  for c in s:
    if c == '"':
      inStr = not inStr
      cur.add c
    elif c == '\'':
      inChr = not inChr
      cur.add c
    elif c == '(' and not inStr:
      inc depth
      cur.add c
    elif c == ')' and not inStr:
      dec depth
      cur.add c
    elif c == ',' and not inStr and not inChr and depth == 0:
      result.add cur.strip
      cur = ""
    else:
      cur.add c
  if cur.strip.len > 0:
    result.add cur.strip

proc processLine(raw: string, line: int) =
  let text = stripComment(raw).strip
  if text.len == 0:
    return
  var rest = text
  var label = ""
  # leading "NAME:" label
  let sp = text.find(' ')
  var first: string
  if sp < 0:
    first = text
  else:
    first = text[0 ..< sp]
  # "NAME EQU expr" form (no colon)
  var afterFirst = ""
  if sp >= 0:
    afterFirst = text[sp + 1 .. ^1].strip
  if first.len > 0 and afterFirst.toUpperAscii.startsWith("EQU"):
    define(first.toUpperAscii, evalExpr(afterFirst[3 .. ^1].strip, line), line)
    return
  if first.endsWith(":"):
    label = first[0 ..< ^1].toUpperAscii
    rest = text[first.len .. ^1].strip
    if label.len > 0:
      define(label, pc, line)
  if rest.len == 0:
    return
  # mnemonic + operand string
  var mn: string
  var argStr: string
  let sp2 = rest.find(' ')
  if sp2 < 0:
    mn = rest.toUpperAscii
    argStr = ""
  else:
    mn = rest[0 ..< sp2].toUpperAscii
    argStr = rest[sp2 + 1 .. ^1].strip

  if mn == "EQU":
    if label.len == 0:
      err(line, "EQU needs a label")
    define(label, evalExpr(argStr, line), line)
    # pass 2 must not redefine
    return

  case mn
  of ".ASSUME":
    ## .ASSUME ADL = 1 (or 0): the memory mode the code is assembled for.
    let up = argStr.toUpperAscii.replace(" ", "")
    if not up.startsWith("ADL="):
      err(line, "only .ASSUME ADL=0/1 is supported")
    let v = evalExpr(up[4 .. ^1], line)
    adl = v != 0
  of "ORG":
    let v = evalExpr(argStr, line)
    pc = v
    if pass == 1:
      outp.setLen(0)
  of "DB":
    for item in splitArgs(argStr):
      if item.startsWith("\""):
        if not item.endsWith("\"") or item.len < 2:
          err(line, "bad string " & item)
        for ch in item[1 ..< ^1]:
          outp.add bt(ord(ch))
          inc pc
      else:
        let v = evalExpr(item, line)
        if pass == 2 and v notin 0 .. 255:
          err(line, "DB value out of range: " & item)
        outp.add bt(v)
        inc pc
  of "DW":
    for item in splitArgs(argStr):
      add16(outp, evalExpr(item, line))
      inc pc, 2
  of "DS":
    let n = evalExpr(argStr, line)
    inc pc, n
    outp.setLen(max(outp.len, pc))
  else:
    if label.len > 0 and not first.endsWith(":"):
      err(line, "expected ':' after label '" & label & "'")
    let code = encode(mn, splitArgs(argStr), line)
    outp.setLen(max(outp.len, pc))
    outp.add code
    inc pc, code.len

proc assemble(inPath, outPath: string) =
  srcFile = inPath
  let lines = readFile(inPath).splitLines()
  for p in 1 .. 2:
    pass = p
    pc = 0
    if p == 2:
      outp.setLen(0)
    for i, ln in lines:
      processLine(ln, i + 1)
  var s = newString(outp.len)
  for i, c in outp:
    s[i] = chr(c)
  writeFile(outPath, s)
  echo &"assembled {inPath} -> {outPath}: {outp.len} bytes, {syms.len} symbols"

when isMainModule:
  let params = commandLineParams()
  if params.len != 2:
    quit "usage: z80asm input.asm output.bin"
  assemble(params[0], params[1])
