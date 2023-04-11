// z80.dart -- implements the Zilog Z80 processor core
//
// Reference notes:
//
// The Z80 microprocessor user manual can be downloaded from Zilog:
//    http://tinyurl.com/z80manual
//
// An excellent additional reference is "The Undocumented Z80 Documented", at:
//    http://www.z80.info/zip/z80-documented.pdf

import 'memory.dart';
import 'utility.dart';

// We use register names for the fields and we don't fuss too much about this.
// ignore_for_file: non_constant_identifier_names

typedef PortReadCallback = int Function(int);
typedef PortWriteCallback = void Function(int, int);

int _defaultPortReadFunction(int port) => highByte(port);
void _defaultPortWriteFunction(int addr, int value) {}

// Opcodes that can be prefixed with DD or FD, but are the same as the
// unprefixed versions (albeit slower).
const _extendedCodes = [
  0x04, 0x05, 0x06, 0x0c, 0x0d, 0x0e,
  0x14, 0x15, 0x16, 0x1c, 0x1d, 0x1e,
  0x3c, 0x3d, 0x3e, // inc/dec
  0x40, 0x41, 0x42, 0x43, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4f,
  0x50, 0x51, 0x52, 0x53, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5f, // ld
  0x78, 0x79, 0x7a, 0x7b, 0x7f,
  0x80, 0x81, 0x82, 0x83, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8f,
  0x90, 0x91, 0x92, 0x93, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9f,
  0xa0, 0xa1, 0xa2, 0xa3, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xaf,
  0xb0, 0xb1, 0xb2, 0xb3, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbf // add/sub/and/or
];

/// The Zilog Z80 emulator.
class Z80 {
  final MemoryBase _memory;

  /// Callback for a port read (IN instruction).
  ///
  /// This should be used by an emulator to handle peripherals or ULA access,
  /// including keyboard or storage input.
  final PortReadCallback onPortRead;

  /// Callback for a port write (OUT instruction).
  ///
  /// This should be used by an emulator to handle peripherals or ULA access,
  /// such as a printer or storage output.
  final PortWriteCallback onPortWrite;

  // Core registers
  int a, f, b, c, d, e, h, l;
  int ix, iy;

  // The alternate register set (A', F', B', C', D', E', H', L')
  int a_, f_, b_, c_, d_, e_, h_, l_;

  /// Interrupt Page Address register (I).
  int i;

  /// Memory Refresh register (R).
  int r;

  /// Program Counter (PC).
  int pc;

  /// Stack Pointer (SP).
  int sp;

  /// Interrupt Flip-Flop (IFF1).
  bool iff1;

  /// Interrupt Flip-Flop (IFF2).
  ///
  /// This is used to cache the value of the Interrupt Flag when a Non-Maskable
  /// Interrupt occurs.
  bool iff2;

  /// Interrupt Mode (IM).
  ///
  /// This can be a value between 0 and 2.
  int im;

  /// Number of clock cycles that have occurred since the last clock reset.
  int tStates;

  bool halt = false;

  /// Initializes the Z80 emulator.
  Z80(
    this._memory, {
    int startAddress = 0,
    this.onPortRead = _defaultPortReadFunction,
    this.onPortWrite = _defaultPortWriteFunction,
  })  : a = 0xFF,
        f = 0xFF,
        b = 0xFF,
        c = 0xFF,
        d = 0xFF,
        e = 0xFF,
        h = 0xFF,
        l = 0xFF,
        a_ = 0xFF,
        f_ = 0xFF,
        b_ = 0xFF,
        c_ = 0xFF,
        d_ = 0xFF,
        e_ = 0xFF,
        h_ = 0xFF,
        l_ = 0xFF,
        ix = 0xFFFF,
        iy = 0xFFFF,
        sp = 0xFFFF,
        pc = startAddress,
        iff1 = false,
        iff2 = false,
        im = 0,
        i = 0xFF,
        r = 0xFF,
        tStates = 0;

  /// Reset the Z80 to an initial power-on configuration.
  void reset() {
    // Initial register states are set per section 2.4 of
    //  http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
    af = af_ = 0xFFFF;
    bc = bc_ = 0xFFFF;
    de = de_ = 0xFFFF;
    hl = hl_ = 0xFFFF;
    ix = 0xFFFF;
    iy = 0xFFFF;
    sp = 0xFFFF;
    pc = 0x0000;
    iff1 = iff2 = false;
    im = 0;
    i = r = 0xFF;

    tStates = 0;
  }

  void nonMaskableInterrupt() {
    // Per "The Undocumented Z80 Documented", shen a NMI is accepted, IFF1 is
    // reset. At the end of the routine, IFF1 must be restored (so the running
    // program is not affected). That’s why IFF2 is there; to keep a copy of
    // IFF1.
    iff1 = false;
    r = (r + 1) % 0x100;
    pc = 0x0066;
  }

  /// Generate an interrupt.
  void maskableInterrupt() {
    if (iff1) {
      r = (r + 1) % 0x100;
      iff1 = false;
      iff2 = false;
      print('maskable interrupt: $iff1 $iff2 $im');
      switch (im) {
        case 0:
          // Not used on the ZX Spectrum
          tStates += 13;
        case 1:
          PUSH(pc);
          pc = 0x0038;
          tStates += 13;
        case 2:
          PUSH(pc);
          final address = createWord(0, i);
          pc = _memory.readWord(address);
          tStates += 19;
      }
    }
  }

  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
  // REGISTERS
  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***

  // Flags: SZ5H3PNC
  final flags = const {
    'C': 0x01, // carry flag (bit 0)
    'N': 0x02, // add/subtract flag (bit 1)
    'P': 0x04, // parity/overflow flag (bit 2)
    'F3': 0x08, // undocumented flag
    'H': 0x10, // half carry flag (bit 4)
    'F5': 0x20, // undocumented flag
    'Z': 0x40, // zero flag (bit 6)
    'S': 0x80 // sign flag (bit 7)
  };

  int get af => (a << 8) + f;
  set af(int value) {
    a = highByte(value);
    f = lowByte(value);
  }

  /// The AF' register.
  int get af_ => (a_ << 8) + f_;
  set af_(int value) {
    a_ = highByte(value);
    f_ = lowByte(value);
  }

  int get bc => (b << 8) + c;
  set bc(int value) {
    b = highByte(value);
    c = lowByte(value);
  }

  /// The BC' register
  int get bc_ => (b_ << 8) + c_;
  set bc_(int value) {
    b_ = highByte(value);
    c_ = lowByte(value);
  }

  int get de => (d << 8) + e;
  set de(int value) {
    d = highByte(value);
    e = lowByte(value);
  }

  /// The DE' register
  int get de_ => (d_ << 8) + e_;
  set de_(int value) {
    d_ = highByte(value);
    e_ = lowByte(value);
  }

  int get hl => (h << 8) + l;
  set hl(int value) {
    h = highByte(value);
    l = lowByte(value);
  }

  /// The HL' register
  int get hl_ => (h_ << 8) + l_;
  set hl_(int value) {
    h_ = highByte(value);
    l_ = lowByte(value);
  }

  int get ixh => (ix & 0xFF00) >> 8;
  set ixh(int value) {
    final lo = lowByte(ix);
    ix = ((value & 0xFF) << 8) + lo;
  }

  int get ixl => ix & 0x00FF;
  set ixl(int value) {
    final hi = highByte(ix);
    ix = (hi << 8) + (value & 0xFF);
  }

  int get iyh => (iy & 0xFF00) >> 8;
  set iyh(int value) {
    final lo = lowByte(iy);
    iy = ((value & 0xFF) << 8) + lo;
  }

  int get iyl => iy & 0x00FF;
  set iyl(int value) {
    final hi = highByte(iy);
    iy = (hi << 8) + (value & 0xFF);
  }

  /// The carry (C) flag.
  ///
  /// Set if there was a carry after the most significant bit.
  bool get fC => f & flags['C']! == flags['C'];
  set fC(bool value) => f = (value ? (f | flags['C']!) : (f & ~flags['C']!));

  /// The add/subtract (N) flag.
  ///
  /// Shows whether the last operation was an addition (false) or a subtraction
  /// (true).
  bool get fN => f & flags['N']! == flags['N'];
  set fN(bool value) => f = (value ? (f | flags['N']!) : (f & ~flags['N']!));

  /// The parity / overflow (P/V) flag.
  ///
  /// Either the parity of the result, or the twos-complement overflow (set if
  /// the twos-complement value doesn't fit in the register).
  bool get fPV => f & flags['P']! == flags['P'];
  set fPV(bool value) => f = (value ? (f | flags['P']!) : (f & ~flags['P']!));

  /// The undocumented (X) flag.
  ///
  /// A copy of bit 3 of the result.
  bool get f3 => f & flags['F3']! == flags['F3'];
  set f3(bool value) => f = (value ? (f | flags['F3']!) : (f & ~flags['F3']!));

  /// The half-carry (H) flag.
  ///
  /// Used for BCD correction with the `DAA` instruction.
  bool get fH => f & flags['H']! == flags['H'];
  set fH(bool value) => f = (value ? (f | flags['H']!) : (f & ~flags['H']!));

  /// The undocumented (Y) flag.
  ///
  /// A copy of bit 5 of the result.
  bool get f5 => f & flags['F5']! == flags['F5'];
  set f5(bool value) => f = (value ? (f | flags['F5']!) : (f & ~flags['F5']!));

  /// The zero (Z) flag.
  ///
  /// Set if the result is zero.
  bool get fZ => f & flags['Z']! == flags['Z'];
  set fZ(bool value) => f = (value ? (f | flags['Z']!) : (f & ~flags['Z']!));

  /// The signed (S) flag.
  ///
  /// Set if the twos-complement value is negative. That is, set if the most
  /// significant bit is set.
  bool get fS => f & flags['S']! == flags['S'];
  set fS(bool value) => f = (value ? (f | flags['S']!) : (f & ~flags['S']!));

  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
  // INSTRUCTIONS
  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***

  /// Load and Increment
  void LDI() {
    final byteRead = _memory.readByte(hl);
    _memory.writeByte(de, byteRead);

    fPV = (bc - 1) != 0;

    de = (de + 1) % 0x10000;
    hl = (hl + 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    fH = false;
    fN = false;
    f5 = isBitSet((byteRead + a) & 0xFF, 1);
    f3 = isBitSet((byteRead + a) & 0xFF, 3);

    tStates += 16;
  }

  /// Load and Decrement
  void LDD() {
    final byteRead = _memory.readByte(hl);
    _memory.writeByte(de, byteRead);

    de = (de - 1) % 0x10000;
    hl = (hl - 1) % 0x10000;
    bc = (bc - 1) % 0x10000;
    fH = false;
    fN = false;
    fPV = bc != 0;
    f5 = isBitSet((byteRead + a) & 0xFF, 1);
    f3 = isBitSet((byteRead + a) & 0xFF, 3);

    tStates += 16;
  }

  /// Load, Increment and Repeat
  void LDIR() {
    final byteRead = _memory.readByte(hl);
    _memory.writeByte(de, byteRead);

    de = (de + 1) % 0x10000;
    hl = (hl + 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    if (bc != 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
    f5 = isBitSet((byteRead + a) & 0xFF, 1);
    f3 = isBitSet((byteRead + a) & 0xFF, 3);
    fH = false;
    fPV = bc != 0;
    fN = false;
  }

  /// Load, Decrement and Repeat
  void LDDR() {
    final byteRead = _memory.readByte(hl);
    _memory.writeByte(de, byteRead);

    de = (de - 1) % 0x10000;
    hl = (hl - 1) % 0x10000;
    bc = (bc - 1) % 0x10000;
    if (bc > 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
    f5 = isBitSet((byteRead + a) & 0xFF, 1);
    f3 = isBitSet((byteRead + a) & 0xFF, 3);
    fH = false;
    fPV = bc != 0;
    fN = false;
  }

  // Arithmetic operations

  /// Increment
  int INC(int reg) {
    final oldReg = reg;
    fPV = reg == 0x7F;
    reg = (reg + 1) % 0x100;
    fH = isBitSet(reg, 4) != isBitSet(oldReg, 4);
    fZ = isZero(reg);
    fS = isSign8(reg);
    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fN = false;

    tStates += 4;

    return reg;
  }

  /// Decrement
  int DEC(int reg) {
    final oldReg = reg;
    fPV = reg == 0x80;
    reg = (reg - 1) % 0x100;
    fH = isBitSet(reg, 4) != isBitSet(oldReg, 4);
    fZ = isZero(reg);
    fS = isSign8(reg);
    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fN = true;

    tStates += 4;

    return reg;
  }

  /// Add with Carry (8-bit)
  int ADC8(int x, int y) => ADD8(x, y, withCarry: fC);

  /// Add with Carry (16-bit)
  int ADC16(int xx, int yy) {
    // overflow in add only occurs when operand polarities are the same
    final overflowCheck = isSign16(xx) == isSign16(yy);

    xx = ADD16(xx, yy, withCarry: fC);

    // if polarity is now different then add caused an overflow
    if (overflowCheck) {
      fPV = isSign16(xx) != isSign16(yy);
    } else {
      fPV = false;
    }
    fS = isSign16(xx);
    fZ = isZero(xx);
    return xx;
  }

  /// Add (8-bit)
  int ADD8(int x, int y, {bool withCarry = false}) {
    final carry = withCarry ? 1 : 0;
    fH = (((x & 0x0F) + (y & 0x0F) + carry) & 0x10) == 0x10;

    // overflow in add only occurs when operand polarities are the same
    final overflowCheck = isSign8(x) == isSign8(y);

    fC = x + y + carry > 0xFF;
    x = (x + y + carry) % 0x100;
    fS = isSign8(x);

    // if polarity is now different then add caused an overflow
    if (overflowCheck) {
      fPV = fS != isSign8(y);
    } else {
      fPV = false;
    }

    f5 = isBitSet(x, 5);
    f3 = isBitSet(x, 3);
    fZ = isZero(x);
    fN = false;

    tStates += 4;

    return x;
  }

  /// Add (16-bit)
  int ADD16(int xx, int yy, {bool withCarry = false}) {
    final carry = withCarry ? 1 : 0;

    fH = (xx & 0x0FFF) + (yy & 0x0FFF) + carry > 0x0FFF;
    fC = xx + yy + carry > 0xFFFF;
    xx = (xx + yy + carry) % 0x10000;
    f5 = isBitSet(xx, 13);
    f3 = isBitSet(xx, 11);
    fN = false;

    tStates += 11;

    return xx;
  }

  /// Subtract with Carry (8-bit)
  int SBC8(int x, int y) => SUB8(x, y, withCarry: fC);

  /// Subtract with Carry (16-bit)
  int SBC16(int xx, int yy) {
    final carry = fC ? 1 : 0;

    fC = xx < (yy + carry);
    fH = (xx & 0xFFF) < ((yy & 0xFFF) + carry);
    fS = isSign16(xx);

    // overflow in subtract only occurs when operand signs are different
    final overflowCheck = isSign16(xx) != isSign16(yy);

    xx = (xx - yy - carry) % 0x10000;
    f5 = isBitSet(xx, 13);
    f3 = isBitSet(xx, 11);
    fZ = isZero(xx);
    fN = true;

    // if x changed polarity then subtract caused an overflow
    if (overflowCheck) {
      fPV = fS != isSign16(xx);
    } else {
      fPV = false;
    }
    fS = isSign16(xx);

    tStates += 15;

    return xx;
  }

  /// Subtract (8-bit)
  int SUB8(int x, int y, {bool withCarry = false}) {
    final carry = withCarry ? 1 : 0;

    fC = x < (y + carry);
    fH = (x & 0x0F) < ((y & 0x0F) + carry);

    fS = isSign8(x);

    // overflow in subtract only occurs when operand signs are different
    final overflowCheck = isSign8(x) != isSign8(y);

    x = (x - y - carry) % 0x100;
    f5 = isBitSet(x, 5);
    f3 = isBitSet(x, 3);

    // if x changed polarity then subtract caused an overflow
    if (overflowCheck) {
      fPV = fS != isSign8(x);
    } else {
      fPV = false;
    }

    fS = isSign8(x);
    fZ = isZero(x);
    fN = true;

    tStates += 4;

    return x;
  }

  /// Compare
  void CP(int x) {
    SUB8(a, x);
    f5 = isBitSet(x, 5);
    f3 = isBitSet(x, 3);
  }

  /// Decimal Adjust Accumulator
  void DAA() {
    // algorithm from http://worldofspectrum.org/faq/reference/z80reference.htm
    var correctionFactor = 0;
    final oldA = a;

    if ((a > 0x99) || fC) {
      correctionFactor |= 0x60;
      fC = true;
    } else {
      fC = false;
    }

    if (((a & 0x0F) > 0x09) || fH) {
      correctionFactor |= 0x06;
    }

    if (!fN) {
      a = (a + correctionFactor) % 0x100;
    } else {
      a = (a - correctionFactor) % 0x100;
    }

    fH = ((oldA & 0x10) ^ (a & 0x10)) == 0x10;
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fS = isSign8(a);
    fZ = isZero(a);
    fPV = isParity(a);

    tStates += 4;
  }

  // Flow operations
  /// Call
  void CALL() {
    final callAddr = getNextWord();

    PUSH(pc);

    pc = callAddr;

    tStates += 17;
  }

  /// Jump Relative
  void JR(int jump) {
    // jump is treated as signed byte from -128 to 127
    jump = twocomp8(jump);
    pc = (pc + jump) % 0x10000;

    tStates += 12;
  }

  /// Decrement and Jump if Not Zero
  void DJNZ(int jump) {
    b = (b - 1) % 0x100;
    if (b != 0) {
      JR(jump);
      tStates++; // JR is 12 tStates
    } else {
      tStates += 8;
    }
  }

  void RST(int addr) {
    PUSH(pc);
    pc = addr;
    tStates += 11;
  }

  /// Return from Non-Maskable Interrupt
  void RETN() {
    // When an NMI is accepted, IFF1 is reset to prevent any other interrupts
    // occurring during the same period. This return ensures that the value is
    // restored from IFF2.
    pc = POP();
    iff1 = iff2;
  }

  // Stack operations
  void PUSH(int val) {
    sp = (sp - 1) % 0x10000;
    _memory.writeByte(sp, highByte(val));
    sp = (sp - 1) % 0x10000;
    _memory.writeByte(sp, lowByte(val));
  }

  int POP() {
    final lo = _memory.readByte(sp);
    sp = (sp + 1) % 0x10000;
    final hi = _memory.readByte(sp);
    sp = (sp + 1) % 0x10000;
    return (hi << 8) + lo;
  }

  void EX_AFAFPrime() {
    int temp;

    temp = a;
    a = a_;
    a_ = temp;

    temp = f;
    f = f_;
    f_ = temp;

    tStates += 4;
  }

  // Logic operations

  /// Compare and Decrement
  void CPD() {
    final val = _memory.readByte(hl);
    fH = (a & 0x0F) < (val & 0x0F);
    fS = isSign8(a - val);
    fZ = a == val;
    f5 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 1);
    f3 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 3);
    fN = true;
    fPV = bc - 1 != 0;
    hl = (hl - 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    tStates += 16;
  }

  /// Compare and Decrement Repeated
  void CPDR() {
    final val = _memory.readByte(hl);
    fH = (a & 0x0F) < (val & 0x0F);
    fS = isSign8(a - val);
    fZ = a == val;
    f5 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 1);
    f3 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 3);
    fN = true;
    fPV = bc - 1 != 0;
    hl = (hl - 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    if ((bc != 0) && (a != val)) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  void CPI() {
    final val = _memory.readByte(hl);
    fH = (a & 0x0F) < (val & 0x0F);
    fS = isSign8(a - val);
    fZ = a == val;
    f5 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 1);
    f3 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 3);
    fN = true;
    fPV = bc - 1 != 0;
    hl = (hl + 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    tStates += 16;
  }

  void CPIR() {
    final val = _memory.readByte(hl);
    fH = (a & 0x0F) < (val & 0x0F);
    fS = isSign8(a - val);
    fZ = a == val;
    f5 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 1);
    f3 = isBitSet((a - val - (fH == true ? 1 : 0)) & 0xFF, 3);
    fN = true;
    fPV = bc - 1 != 0;

    hl = (hl + 1) % 0x10000;
    bc = (bc - 1) % 0x10000;

    if ((bc != 0) && (a != val)) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  int OR(int a, int reg) {
    a |= reg;
    fS = isSign8(a);
    fZ = isZero(a);
    fH = false;
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fPV = isParity(a);
    fN = false;
    fC = false;

    tStates += 4;

    return a;
  }

  int XOR(int a, int reg) {
    a ^= reg;
    fS = isSign8(a);
    fZ = isZero(a);
    fH = false;
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fPV = isParity(a);
    fN = false;
    fC = false;

    tStates += 4;

    return a;
  }

  int AND(int a, int reg) {
    a &= reg;
    fS = isSign8(a);
    fZ = isZero(a);
    fH = true;
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);
    fPV = isParity(a);
    fN = false;
    fC = false;

    tStates += 4;

    return a;
  }

  int NEG(int a) {
    // returns two's complement of a
    fPV = a == 0x80;
    fC = a != 0x00;

    a = ~a;
    a = (a + 1) % 0x100;
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fS = isSign8(a);
    fZ = isZero(a);
    fH = a & 0x0F != 0;
    fN = true;

    tStates += 8;

    return a;
  }

  // TODO: Organize these into the same groups as the Z80 manual

  /// Complement
  void CPL() {
    a = onecomp8(a);
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);
    fH = true;
    fN = true;

    tStates += 4;
  }

  /// Set Carry Flag
  void SCF() {
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);
    fH = false;
    fN = false;
    fC = true;
  }

  /// Clear Carry Flag
  void CCF() {
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);
    fH = fC;
    fN = false;
    fC = !fC;

    tStates += 4;
  }

  /// Rotate Left Circular
  int RLC(int reg) {
    // rotates register r to the left
    // bit 7 is copied to carry and to bit 0
    fC = isSign8(reg);
    reg = (reg << 1) % 0x100;
    if (fC) reg = setBit(reg, 0);

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Rotate Left Circular Accumulator
  void RLCA() {
    // rotates register A to the left
    // bit 7 is copied to carry and to bit 0
    fC = isSign8(a);
    a = (a << 1) % 0x100;
    if (fC) a = setBit(a, 0);
    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fH = false;
    fN = false;

    tStates += 4;
  }

  /// Rotate Right Circular
  int RRC(int reg) {
    fC = isBitSet(reg, 0);
    reg >>= 1;
    if (fC) reg = setBit(reg, 7);

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Rotate Right Circular Accumulator
  void RRCA() {
    fC = isBitSet(a, 0);
    a >>= 1;
    if (fC) a = setBit(a, 7);

    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fH = false;
    fN = false;

    tStates += 4;
  }

  /// Rotate Left
  int RL(int reg) {
    // rotates register r to the left, through carry.
    // carry becomes the LSB of the new r
    final bit0 = fC;

    fC = isSign8(reg);
    reg = (reg << 1) % 0x100;

    if (bit0) reg = setBit(reg, 0);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Rotate Left Accumulator
  void RLA() {
    // rotates register r to the left, through carry.
    // carry becomes the LSB of the new r
    final bit0 = fC;

    fC = isSign8(a);
    a = (a << 1) % 0x100;

    if (bit0) a = setBit(a, 0);

    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fH = false;
    fN = false;

    tStates += 4;
  }

  /// Rotate Right
  int RR(int reg) {
    final bit7 = fC;

    fC = isBitSet(reg, 0);
    reg >>= 1;

    if (bit7) reg = setBit(reg, 7);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Rotate Right Accumulator
  void RRA() {
    final bit7 = fC;

    fC = isBitSet(a, 0);
    a >>= 1;

    if (bit7) {
      a = setBit(a, 7);
    }

    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fH = false;
    fN = false;

    tStates += 4;
  }

  /// Shift Left Arithmetic
  int SLA(int reg) {
    fC = isSign8(reg);
    reg = (reg << 1) % 0x100;

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Shift Right Arithmetic
  int SRA(int reg) {
    final bit7 = isSign8(reg);

    fC = isBitSet(reg, 0);
    reg >>= 1;

    if (bit7) reg = setBit(reg, 7);

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Shift Left Logical
  int SLL(int reg) {
    fC = isBitSet(reg, 7);
    reg = (reg << 1) % 0x100;
    reg = setBit(reg, 0);

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Shift Right Logical
  int SRL(int reg) {
    fC = isBitSet(reg, 0);
    reg >>= 1;
    reg = resetBit(reg, 7);

    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);

    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;

    return reg;
  }

  /// Rotate Left BCD Digit
  void RLD() {
    // TODO: Overflow condition for this and RRD
    final old_pHL = _memory.readByte(hl);

    var new_pHL = (old_pHL & 0x0F) << 4;
    new_pHL += a & 0x0F;

    a = a & 0xF0;
    a += (old_pHL & 0xF0) >> 4;

    _memory.writeByte(hl, new_pHL);

    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fS = isSign8(a);
    fZ = isZero(a);
    fH = false;
    fPV = isParity(a);
    fN = false;

    tStates += 18;
  }

  /// Rotate Right BCD Digit
  void RRD() {
    final old_pHL = _memory.readByte(hl);

    var new_pHL = (a & 0x0F) << 4;
    new_pHL += (old_pHL & 0xF0) >> 4;

    a = a & 0xF0;
    a += old_pHL & 0x0F;

    _memory.writeByte(hl, new_pHL);

    f5 = isBitSet(a, 5);
    f3 = isBitSet(a, 3);

    fS = isSign8(a);
    fZ = isZero(a);
    fH = false;
    fPV = isParity(a);
    fN = false;

    tStates += 18;
  }

  // Bitwise operations
  void BIT(int bitToTest, int reg) {
    switch (reg) {
      case 0x0:
        fZ = !isBitSet(b, bitToTest);
        f3 = isBitSet(b, 3);
        f5 = isBitSet(b, 5);
        fPV = fZ;
      case 0x1:
        fZ = !isBitSet(c, bitToTest);
        f3 = isBitSet(c, 3);
        f5 = isBitSet(c, 5);
        fPV = fZ;
      case 0x2:
        fZ = !isBitSet(d, bitToTest);
        f3 = isBitSet(d, 3);
        f5 = isBitSet(d, 5);
        fPV = fZ;
      case 0x3:
        fZ = !isBitSet(e, bitToTest);
        f3 = isBitSet(e, 3);
        f5 = isBitSet(e, 5);
        fPV = fZ;
      case 0x4:
        fZ = !isBitSet(h, bitToTest);
        f3 = isBitSet(h, 3);
        f5 = isBitSet(h, 5);
        fPV = fZ;
      case 0x5:
        fZ = !isBitSet(l, bitToTest);
        f3 = isBitSet(l, 3);
        f5 = isBitSet(l, 5);
        fPV = fZ;
      case 0x6:
        final val = _memory.readByte(hl);
        fZ = !isBitSet(val, bitToTest);
        // NOTE: undocumented bits 3 and 5 for this instruction come from an
        // internal register 'W' that is highly undocumented. This really
        // doesn't matter too much, I don't think. See the following for more:
        //   http://www.omnimaga.org/asm-language/bit-n-(hl)-flags/
        f3 = isBitSet(val, 3);
        f5 = isBitSet(val, 5);
        fPV = fZ;
      case 0x7:
        fZ = !isBitSet(a, bitToTest);
        f3 = isBitSet(a, 3);
        f5 = isBitSet(a, 5);
        fPV = fZ;
      default:
        throw Exception(
            "Field register $reg must map to a valid Z80 register.");
    }

    // undocumented behavior from
    //   http://worldofspectrum.org/faq/reference/z80reference.htm
    fS = (bitToTest == 7) && (!fZ);
    fH = true;
    fN = false;
  }

  void RES(int bitToReset, int reg) {
    switch (reg) {
      case 0x0:
        b = resetBit(b, bitToReset);
      case 0x1:
        c = resetBit(c, bitToReset);
      case 0x2:
        d = resetBit(d, bitToReset);
      case 0x3:
        e = resetBit(e, bitToReset);
      case 0x4:
        h = resetBit(h, bitToReset);
      case 0x5:
        l = resetBit(l, bitToReset);
      case 0x6:
        _memory.writeByte(hl, resetBit(_memory.readByte(hl), bitToReset));
      case 0x7:
        a = resetBit(a, bitToReset);
      default:
        throw Exception(
            "Field register $reg must map to a valid Z80 register.");
    }
  }

  void SET(int bitToSet, int reg) {
    switch (reg) {
      case 0x0:
        b = setBit(b, bitToSet);
      case 0x1:
        c = setBit(c, bitToSet);
      case 0x2:
        d = setBit(d, bitToSet);
      case 0x3:
        e = setBit(e, bitToSet);
      case 0x4:
        h = setBit(h, bitToSet);
      case 0x5:
        l = setBit(l, bitToSet);
      case 0x6:
        _memory.writeByte(hl, setBit(_memory.readByte(hl), bitToSet));
      case 0x7:
        a = setBit(a, bitToSet);
      default:
        throw Exception(
            "Field register $reg must map to a valid Z80 register.");
    }
  }

  // Port operations and interrupts

  void _inSetFlags(int reg) {
    fS = isSign8(reg);
    fZ = isZero(reg);
    fH = false;
    fPV = isParity(reg);
    fN = false;
    f5 = isBitSet(reg, 5);
    f3 = isBitSet(reg, 3);
  }

  void OUT(int portNumber, int value) {
    onPortWrite(portNumber, value);
  }

  void OUTA(int portNumber, int value) {
    onPortWrite(portNumber, value);
  }

  void INA(int operandByte) {
    // The operand is placed on the bottom half (A0 through A7) of the address
    // bus to select the I/O device at one of 256 possible ports. The contents
    // of the Accumulator also appear on the top half (A8 through A15) of the
    // address bus at this time.
    final addressBus = createWord(operandByte, a);
    a = onPortRead(addressBus);
  }

  /// Input and Increment
  void INI() {
    final memval = onPortRead(bc);
    _memory.writeByte(hl, memval);
    hl = (hl + 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + ((c + 1) & 0xFF) > 0xFF;
    fPV = isParity(((memval + ((c + 1) & 0xFF)) & 0x07) ^ b);

    tStates += 16;
  }

  /// Output and Increment
  void OUTI() {
    final memval = _memory.readByte(hl);
    onPortWrite(c, memval);
    hl = (hl + 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + l > 0xFF;
    fPV = isParity(((memval + l) & 0x07) ^ b);

    tStates += 16;
  }

  /// Input and Decrement
  void IND() {
    final memval = onPortRead(bc);
    _memory.writeByte(hl, memval);
    hl = (hl - 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + ((c - 1) & 0xFF) > 0xFF;
    fPV = isParity(((memval + ((c - 1) & 0xFF)) & 0x07) ^ b);
    tStates += 16;
  }

  /// Output and Decrement
  void OUTD() {
    final memval = _memory.readByte(hl);
    onPortWrite(c, memval);
    hl = (hl - 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = true;
    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + l > 0xFF;
    fPV = isParity(((memval + l) & 0x07) ^ b);

    tStates += 16;
  }

  /// Input, Increment and Repeat
  void INIR() {
    final memval = onPortRead(bc);
    _memory.writeByte(hl, memval);
    hl = (hl + 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + ((c + 1) & 0xFF) > 0xFF;
    fPV = isParity(((memval + ((c + 1) & 0xFF)) & 0x07) ^ b);

    if (b != 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  /// Output, Increment and Repeat
  void OTIR() {
    final memval = _memory.readByte(hl);
    onPortWrite(c, memval);

    hl = (hl + 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = true;
    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + l > 0xFF;
    fPV = isParity(((memval + l) & 0x07) ^ b);

    if (b != 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  /// Input, Decrement and Repeat
  void INDR() {
    final memval = onPortRead(bc);
    _memory.writeByte(hl, memval);
    hl = (hl - 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + ((c - 1) & 0xFF) > 0xFF;
    fPV = isParity(((memval + ((c - 1) & 0xFF)) & 0x07) ^ b);

    if (b != 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  /// Output, Decrement and Repeat
  void OTDR() {
    final memval = _memory.readByte(hl);
    onPortWrite(c, memval);

    hl = (hl - 1) % 0x10000;
    b = (b - 1) % 0x100;

    fN = true;
    fN = isBitSet(memval, 7);
    fZ = b == 0;
    fS = isSign8(b);
    f3 = isBitSet(b, 3);
    f5 = isBitSet(b, 5);

    fC = fH = memval + l > 0xFF;
    fPV = isParity(((memval + l) & 0x07) ^ b);

    if (b != 0) {
      pc = (pc - 2) % 0x10000;
      tStates += 21;
    } else {
      tStates += 16;
    }
  }

  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
  // OPCODE DECODING
  // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***

  // Use for debugging, where we want to be able to see what's coming without
  // affecting PC
  int previewByte(int displ) => _memory.readByte(pc + displ);
  int previewWord(int displ) => _memory.readWord(pc + displ);

  // Use for execution, where we want to move through the program
  int getNextByte() {
    final byteRead = _memory.readByte(pc);
    pc = (pc + 1) % 0x10000;
    return byteRead;
  }

  int getNextWord() {
    final wordRead = _memory.readWord(pc);
    pc = (pc + 2) % 0x10000;
    return wordRead;
  }

  int displacedIX() {
    final displ = getNextByte();
    if (displ > 0x7F) {
      return (ix + twocomp8(displ)) % 0x10000;
    } else {
      return (ix + displ) % 0x10000;
    }
  }

  int displacedIY() {
    final displ = getNextByte();
    if (displ > 0x7F) {
      return (iy + twocomp8(displ)) % 0x10000;
    } else {
      return (iy + displ) % 0x10000;
    }
  }

  void rot(int operation, int register) {
    int Function(int) rotFunction;

    switch (operation) {
      case 0x00:
        rotFunction = RLC;
      case 0x01:
        rotFunction = RRC;
      case 0x02:
        rotFunction = RL;
      case 0x03:
        rotFunction = RR;
      case 0x04:
        rotFunction = SLA;
      case 0x05:
        rotFunction = SRA;
      case 0x06:
        rotFunction = SLL;
      case 0x07:
        rotFunction = SRL;
      default:
        throw Exception(
            "Operation $operation must map to a valid rotation operation.");
    }

    switch (register) {
      case 0x00:
        b = rotFunction(b);
      case 0x01:
        c = rotFunction(c);
      case 0x02:
        d = rotFunction(d);
      case 0x03:
        e = rotFunction(e);
      case 0x04:
        h = rotFunction(h);
      case 0x05:
        l = rotFunction(l);
      case 0x06:
        _memory.writeByte(hl, rotFunction(_memory.readByte(hl)));
      case 0x07:
        a = rotFunction(a);
      default:
        throw Exception(
            "Field register $register must map to a valid Z80 register.");
    }
  }

  void DecodeCBOpcode() {
    final opCode = getNextByte();
    r++;

    // first two bits of opCode determine function:
    switch (opCode >> 6) {
      // 00 = rot [y], r[z]
      case 0:
        rot((opCode & 0x38) >> 3, opCode & 0x07);

      // 01 = BIT y, r[z]
      case 1:
        BIT((opCode & 0x38) >> 3, opCode & 0x07);

      // 02 = RES y, r[z]
      case 2:
        RES((opCode & 0x38) >> 3, opCode & 0x07);

      // 03 = SET y, r[z]
      case 3:
        SET((opCode & 0x38) >> 3, opCode & 0x07);
    }

    // Set T-States
    if ((opCode & 0x7) == 0x6) {
      if ((opCode > 0x40) && (opCode < 0x7F)) {
        // BIT n, (HL)
        tStates += 12;
      } else {
        // all the other instructions involving (HL)
        tStates += 15;
      }
    } else {
      // straight register bitwise operation
      tStates += 8;
    }
  }

  void DecodeDDCBOpCode() {
    // format is DDCB[addr][opcode]
    final addr = displacedIX();
    final opCode = getNextByte();

    // BIT
    if ((opCode >= 0x40) && (opCode <= 0x7F)) {
      final val = _memory.readByte(addr);
      final bit = (opCode & 0x38) >> 3;
      fZ = !isBitSet(val, bit);
      fPV = !isBitSet(val, bit); // undocumented, but same as fZ
      fH = true;
      fN = false;
      f5 = isBitSet(addr >> 8, 5);
      f3 = isBitSet(addr >> 8, 3);
      if (bit == 7) {
        fS = isSign8(val);
      } else {
        fS = false;
      }
      tStates += 20;
      return;
    } else {
      // Here follows a double-pass switch statement to determine the opcode
      // results. Firstly, we determine which kind of operation is being
      // requested, and then we identify where the result should be placed.
      var opResult = 0;

      final opCodeType = (opCode & 0xF8) >> 3;
      switch (opCodeType) {
        // RLC (IX+*)
        case 0x00:
          opResult = RLC(_memory.readByte(addr));

        // RRC (IX+*)
        case 0x01:
          opResult = RRC(_memory.readByte(addr));

        // RL (IX+*)
        case 0x02:
          opResult = RL(_memory.readByte(addr));

        // RR (IX+*)
        case 0x03:
          opResult = RR(_memory.readByte(addr));

        // SLA (IX+*)
        case 0x04:
          opResult = SLA(_memory.readByte(addr));

        // SRA (IX+*)
        case 0x05:
          opResult = SRA(_memory.readByte(addr));

        // SLL (IX+*)
        case 0x06:
          opResult = SLL(_memory.readByte(addr));

        // SRL (IX+*)
        case 0x07:
          opResult = SRL(_memory.readByte(addr));

        // RES n, (IX+*)
        case 0x10:
        case 0x11:
        case 0x12:
        case 0x13:
        case 0x14:
        case 0x15:
        case 0x16:
        case 0x17:
          opResult = resetBit(_memory.readByte(addr), (opCode & 0x38) >> 3);

        // SET n, (IX+*)
        case 0x18:
        case 0x19:
        case 0x1A:
        case 0x1B:
        case 0x1C:
        case 0x1D:
        case 0x1E:
        case 0x1F:
          opResult = setBit(_memory.readByte(addr), (opCode & 0x38) >> 3);
      }
      _memory.writeByte(addr, opResult);

      final opCodeTarget = opCode & 0x07;
      switch (opCodeTarget) {
        case 0x00: // b
          b = opResult;
        case 0x01: // c
          c = opResult;
        case 0x02: // d
          d = opResult;
        case 0x03: // e
          e = opResult;
        case 0x04: // h
          h = opResult;
        case 0x05: // l
          l = opResult;
        case 0x06: // no register
          break;
        case 0x07: // a
          a = opResult;
      }

      tStates += 23;
    }
  }

  void DecodeDDOpcode() {
    final opCode = getNextByte();
    r++;

    int addr;

    switch (opCode) {
      // NOP
      case 0x00:
        tStates += 8;

      // ADD IX, BC
      case 0x09:
        ix = ADD16(ix, bc);
        tStates += 4;

      // ADD IX, DE
      case 0x19:
        ix = ADD16(ix, de);
        tStates += 4;

      // LD IX, **
      case 0x21:
        ix = getNextWord();
        tStates += 14;

      // LD (**), IX
      case 0x22:
        _memory.writeWord(getNextWord(), ix);
        tStates += 20;

      // INC IX
      case 0x23:
        ix = (ix + 1) % 0x10000;
        tStates += 10;

      // INC IXH
      case 0x24:
        ixh = INC(ixh);
        tStates += 4;

      // DEC IXH
      case 0x25:
        ixh = DEC(ixh);
        tStates += 4;

      // LD IXH, *
      case 0x26:
        ixh = getNextByte();
        tStates += 11;

      // ADD IX, IX
      case 0x29:
        ix = ADD16(ix, ix);
        tStates += 4;

      // LD IX, (**)
      case 0x2A:
        ix = _memory.readWord(getNextWord());
        tStates += 20;

      // DEC IX
      case 0x2B:
        ix = (ix - 1) % 0x10000;
        tStates += 10;

      // INC IXL
      case 0x2C:
        ixl = INC(ixl);
        tStates += 4;

      // DEC IXL
      case 0x2D:
        ixl = DEC(ixl);
        tStates += 4;

      // LD IXH, *
      case 0x2E:
        ixl = getNextByte();
        tStates += 11;

      // INC (IX+*)
      case 0x34:
        addr = displacedIX();
        _memory.writeByte(addr, INC(_memory.readByte(addr)));
        tStates += 19;

      // DEC (IX+*)
      case 0x35:
        addr = displacedIX();
        _memory.writeByte(addr, DEC(_memory.readByte(addr)));
        tStates += 19;

      // LD (IX+*), *
      case 0x36:
        _memory.writeByte(displacedIX(), getNextByte());
        tStates += 19;

      // ADD IX, SP
      case 0x39:
        ix = ADD16(ix, sp);
        tStates += 4;

      // LD B, IXH
      case 0x44:
        b = ixh;
        tStates += 8;

      // LD B, IXL
      case 0x45:
        b = ixl;
        tStates += 8;

      // LD B, (IX+*)
      case 0x46:
        b = _memory.readByte(displacedIX());
        tStates += 19;

      // LD C, IXH
      case 0x4C:
        c = ixh;
        tStates += 8;

      // LD C, IXL
      case 0x4D:
        c = ixl;
        tStates += 8;

      // LD C, (IX+*)
      case 0x4E:
        c = _memory.readByte(displacedIX());
        tStates += 19;

      // LD D, IXH
      case 0x54:
        d = ixh;
        tStates += 8;

      // LD D, IXL
      case 0x55:
        d = ixl;
        tStates += 8;

      // LD D, (IX+*)
      case 0x56:
        d = _memory.readByte(displacedIX());
        tStates += 19;

      // LD E, IXH
      case 0x5C:
        e = ixh;
        tStates += 8;

      // LD E, IXL
      case 0x5D:
        e = ixl;
        tStates += 8;

      // LD E, (IX+*)
      case 0x5E:
        e = _memory.readByte(displacedIX());
        tStates += 19;

      // LD IXH, B
      case 0x60:
        ixh = b;
        tStates += 8;

      // LD IXH, C
      case 0x61:
        ixh = c;
        tStates += 8;

      // LD IXH, D
      case 0x62:
        ixh = d;
        tStates += 8;

      // LD IXH, E
      case 0x63:
        ixh = e;
        tStates += 8;

      // LD IXH, IXH
      case 0x64:
        tStates += 8;

      // LD IXH, IXL
      case 0x65:
        ixh = ixl;
        tStates += 8;

      // LD H, (IX+*)
      case 0x66:
        h = _memory.readByte(displacedIX());
        tStates += 19;

      // LD IXH, A
      case 0x67:
        ixh = a;
        tStates += 8;

      // LD IXL, B
      case 0x68:
        ixl = b;
        tStates += 8;

      // LD IXL, C
      case 0x69:
        ixl = c;
        tStates += 8;

      // LD IXL, D
      case 0x6A:
        ixl = d;
        tStates += 8;

      // LD IXL, E
      case 0x6B:
        ixl = e;
        tStates += 8;

      // LD IXL, IXH
      case 0x6C:
        ixl = ixh;
        tStates += 8;

      // LD IXL, IXL
      case 0x6D:
        tStates += 8;

      // LD L, (IX+*)
      case 0x6E:
        l = _memory.readByte(displacedIX());
        tStates += 19;

      // LD IXL, A
      case 0x6F:
        ixl = a;
        tStates += 8;

      // LD (IX+*), B
      case 0x70:
        _memory.writeByte(displacedIX(), b);
        tStates += 19;

      // LD (IX+*), C
      case 0x71:
        _memory.writeByte(displacedIX(), c);
        tStates += 19;

      // LD (IX+*), D
      case 0x72:
        _memory.writeByte(displacedIX(), d);
        tStates += 19;

      // LD (IX+*), E
      case 0x73:
        _memory.writeByte(displacedIX(), e);
        tStates += 19;

      // LD (IX+*), H
      case 0x74:
        _memory.writeByte(displacedIX(), h);
        tStates += 19;

      // LD (IX+*), L
      case 0x75:
        _memory.writeByte(displacedIX(), l);
        tStates += 19;

      // LD (IX+*), A
      case 0x77:
        _memory.writeByte(displacedIX(), a);
        tStates += 19;

      // LD A, IXH
      case 0x7C:
        a = ixh;
        tStates += 8;

      // LD A, IXL
      case 0x7D:
        a = ixl;
        tStates += 8;

      // LD A, (IX+*)
      case 0x7E:
        a = _memory.readByte(displacedIX());
        tStates += 19;

      // ADD A, IXH
      case 0x84:
        a = ADD8(a, ixh);
        tStates += 4;

      // ADD A, IXL
      case 0x85:
        a = ADD8(a, ixl);
        tStates += 4;

      // ADD A, (IX+*)
      case 0x86:
        a = ADD8(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // ADC A, IXH
      case 0x8C:
        a = ADC8(a, ixh);
        tStates += 4;

      // ADC A, IXL
      case 0x8D:
        a = ADC8(a, ixl);
        tStates += 4;

      // ADC A, (IX+*)
      case 0x8E:
        a = ADC8(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // SUB IXH
      case 0x94:
        a = SUB8(a, ixh);
        tStates += 4;

      // SUB IXL
      case 0x95:
        a = SUB8(a, ixl);
        tStates += 4;

      // SUB (IX+*)
      case 0x96:
        a = SUB8(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // SBC A, IXH
      case 0x9C:
        a = SBC8(a, ixh);
        tStates += 4;

      // SBC A, IXL
      case 0x9D:
        a = SBC8(a, ixl);
        tStates += 4;

      // SBC A, (IX+*)
      case 0x9E:
        a = SBC8(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // AND IXH
      case 0xA4:
        a = AND(a, ixh);
        tStates += 4;

      // AND IXL
      case 0xA5:
        a = AND(a, ixl);
        tStates += 4;

      // AND (IX+*)
      case 0xA6:
        a = AND(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // XOR (IX+*)
      case 0xAE:
        a = XOR(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // XOR IXH
      case 0xAC:
        a = XOR(a, ixh);
        tStates += 4;

      // XOR IXL
      case 0xAD:
        a = XOR(a, ixl);
        tStates += 4;

      // OR IXH
      case 0xB4:
        a = OR(a, ixh);
        tStates += 4;

      // OR IXL
      case 0xB5:
        a = OR(a, ixl);
        tStates += 4;

      // OR (IX+*)
      case 0xB6:
        a = OR(a, _memory.readByte(displacedIX()));
        tStates += 15;

      // CP IXH
      case 0xBC:
        CP(ixh);
        tStates += 4;

      // CP IXL
      case 0xBD:
        CP(ixl);
        tStates += 4;

      // CP (IX+*)
      case 0xBE:
        CP(_memory.readByte(displacedIX()));
        tStates += 15;

      // bitwise instructions
      case 0xCB:
        DecodeDDCBOpCode();

      // POP IX
      case 0xE1:
        ix = POP();
        tStates += 14;

      // EX (SP), IX
      case 0xE3:
        final temp = _memory.readWord(sp);
        _memory.writeWord(sp, ix);
        ix = temp;
        tStates += 23;

      // PUSH IX
      case 0xE5:
        PUSH(ix);
        tStates += 15;

      // JP (IX)
      // note that the brackets in the instruction are an eccentricity, the result
      // should be ix rather than the contents of addr(ix)
      case 0xE9:
        pc = ix;
        tStates += 8;

      // Undocumented, but per §3.7 of:
      //    http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
      case 0xFD:
        tStates += 8;

      // LD SP, IX
      case 0xF9:
        sp = ix;
        tStates += 10;

      default:
        if (_extendedCodes.contains(opCode)) {
          tStates += 4;
          pc--; // go back one
          executeNextInstruction();
        } else {
          throw Exception("Opcode DD${toHex8(opCode)} not understood. ");
        }
    }
  }

  void DecodeEDOpcode() {
    final opCode = getNextByte();
    r++;

    switch (opCode) {
      // IN B, (C)
      case 0x40:
        b = onPortRead(bc);
        _inSetFlags(b);
        tStates += 12;

      // OUT (C), B
      case 0x41:
        OUT(c, b);
        tStates += 12;

      // SBC HL, BC
      case 0x42:
        hl = SBC16(hl, bc);

      // LD (**), BC
      case 0x43:
        _memory.writeWord(getNextWord(), bc);
        tStates += 20;

      // NEG
      case 0x44:
      case 0x4C:
      case 0x54:
      case 0x5C:
      case 0x64:
      case 0x6C:
      case 0x74:
      case 0x7C:
        a = NEG(a);

      // RETN
      case 0x45:
      case 0x55:
      case 0x5D:
      case 0x65:
      case 0x6D:
      case 0x75:
      case 0x7D:
        RETN();
        tStates += 14;

      // IM 0
      case 0x46:
      case 0x66:
        im = 0;
        tStates += 8;

      // LD I, A
      case 0x47:
        i = a;
        tStates += 9;

      // IN C, (C)
      case 0x48:
        c = onPortRead(bc);
        _inSetFlags(c);
        tStates += 12;

      // OUT C, (C)
      case 0x49:
        OUT(c, c);
        tStates += 12;

      // ADC HL, BC
      case 0x4A:
        hl = ADC16(hl, bc);
        tStates += 4;

      // LD BC, (**)
      case 0x4B:
        bc = _memory.readWord(getNextWord());
        tStates += 20;

      // RETI
      case 0x4D:
        pc = POP();
        tStates += 14;

      // LD R, A
      case 0x4F:
        r = a;
        tStates += 9;

      // IN D, (C)
      case 0x50:
        d = onPortRead(bc);
        _inSetFlags(d);
        tStates += 12;

      // OUT (C), D
      case 0x51:
        OUT(c, d);
        tStates += 12;

      // SBC HL, DE
      case 0x52:
        hl = SBC16(hl, de);

      // LD (**), DE
      case 0x53:
        _memory.writeWord(getNextWord(), de);
        tStates += 20;

      // IM 1
      case 0x4E:
      case 0x56:
      case 0x6E:
      case 0x76:
        im = 1;
        tStates += 8;

      // LD A, I
      case 0x57:
        a = i;
        fS = isSign8(i);
        fZ = isZero(i);
        f5 = isBitSet(i, 5);
        fH = false;
        f3 = isBitSet(i, 3);
        fPV = iff2;
        fN = false;
        tStates += 9;

      // IN E, (C)
      case 0x58:
        e = onPortRead(bc);
        _inSetFlags(e);
        tStates += 12;

      // OUT (C), E
      case 0x59:
        OUT(c, e);
        tStates += 12;

      // ADC HL, DE
      case 0x5A:
        hl = ADC16(hl, de);
        tStates += 4;

      // LD DE, (**)
      case 0x5B:
        de = _memory.readWord(getNextWord());
        tStates += 20;

      // IM 2
      case 0x5E:
      case 0x7E:
        im = 2;
        tStates += 8;

      // LD A, R
      case 0x5F:
        a = r;
        fS = isSign8(r);
        fZ = isZero(r);
        fH = false;
        fPV = iff2;
        fN = false;
        tStates += 9;

      // IN H, (C)
      case 0x60:
        h = onPortRead(bc);
        _inSetFlags(h);
        tStates += 12;

      // OUT (C), H
      case 0x61:
        OUT(c, h);
        tStates += 12;

      // SBC HL, HL
      case 0x62:
        hl = SBC16(hl, hl);

      // LD (**), HL
      case 0x63:
        _memory.writeWord(getNextWord(), hl);
        tStates += 20;

      // RRD
      case 0x67:
        RRD();

      // IN L, (C)
      case 0x68:
        l = onPortRead(bc);
        _inSetFlags(l);
        tStates += 12;

      // OUT (C), L
      case 0x69:
        OUT(c, l);
        tStates += 12;

      // ADC HL, HL
      case 0x6A:
        hl = ADC16(hl, hl);
        tStates += 4;

      // LD HL, (**)
      case 0x6B:
        hl = _memory.readWord(getNextWord());
        tStates += 20;

      // RLD
      case 0x6F:
        RLD();

      // IN (C)
      case 0x70:
        onPortRead(bc);
        tStates += 12;

      // OUT (C), 0
      case 0x71:
        OUT(c, 0);
        tStates += 12;

      // SBC HL, SP
      case 0x72:
        hl = SBC16(hl, sp);

      // LD (**), SP
      case 0x73:
        _memory.writeWord(getNextWord(), sp);
        tStates += 20;

      // IN A, (C)
      case 0x78:
        a = onPortRead(bc);
        _inSetFlags(a);
        tStates += 12;

      // OUT (C), A
      case 0x79:
        OUT(c, a);
        tStates += 12;

      // ADC HL, SP
      case 0x7A:
        hl = ADC16(hl, sp);
        tStates += 4;

      // LD SP, (**)
      case 0x7B:
        sp = _memory.readWord(getNextWord());
        tStates += 20;

      // LDI
      case 0xA0:
        LDI();

      // CPI
      case 0xA1:
        CPI();

      // INI
      case 0xA2:
        INI();

      // OUTI
      case 0xA3:
        OUTI();

      // LDD
      case 0xA8:
        LDD();

      // CPD
      case 0xA9:
        CPD();

      // IND
      case 0xAA:
        IND();

      // OUTD
      case 0xAB:
        OUTD();

      // LDIR
      case 0xB0:
        LDIR();

      // CPIR
      case 0xB1:
        CPIR();

      // INIR
      case 0xB2:
        INIR();

      // OTIR
      case 0xB3:
        OTIR();

      // LDDR
      case 0xB8:
        LDDR();

      // CPDR
      case 0xB9:
        CPDR();

      // INDR
      case 0xBA:
        INDR();

      // OTDR
      case 0xBB:
        OTDR();

      default:
        throw Exception("Opcode ED${toHex16(opCode)} not understood. ");
    }
  }

  void DecodeFDCBOpCode() {
    // format is FDCB[addr][opcode]
    final addr = displacedIY();
    final opCode = getNextByte();

    // BIT
    if ((opCode >= 0x40) && (opCode <= 0x7F)) {
      final val = _memory.readByte(addr);
      final bit = (opCode & 0x38) >> 3;
      fZ = !isBitSet(val, bit);
      fPV = !isBitSet(val, bit); // undocumented, but same as fZ
      fH = true;
      fN = false;
      f5 = isBitSet(addr >> 8, 5);
      f3 = isBitSet(addr >> 8, 3);
      if (bit == 7) {
        fS = isSign8(val);
      } else {
        fS = false;
      }
      tStates += 20;
      return;
    } else {
      // Here follows a double-pass switch statement to determine the opcode
      // results. Firstly, we determine which kind of operation is being
      // requested, and then we identify where the result should be placed.
      var opResult = 0;

      final opCodeType = (opCode & 0xF8) >> 3;
      switch (opCodeType) {
        // RLC (IY+*)
        case 0x00:
          opResult = RLC(_memory.readByte(addr));

        // RRC (IY+*)
        case 0x01:
          opResult = RRC(_memory.readByte(addr));

        // RL (IY+*)
        case 0x02:
          opResult = RL(_memory.readByte(addr));

        // RR (IY+*)
        case 0x03:
          opResult = RR(_memory.readByte(addr));

        // SLA (IY+*)
        case 0x04:
          opResult = SLA(_memory.readByte(addr));

        // SRA (IY+*)
        case 0x05:
          opResult = SRA(_memory.readByte(addr));

        // SLL (IY+*)
        case 0x06:
          opResult = SLL(_memory.readByte(addr));

        // SRL (IY+*)
        case 0x07:
          opResult = SRL(_memory.readByte(addr));

        // RES n, (IY+*)
        case 0x10:
        case 0x11:
        case 0x12:
        case 0x13:
        case 0x14:
        case 0x15:
        case 0x16:
        case 0x17:
          opResult = resetBit(_memory.readByte(addr), (opCode & 0x38) >> 3);

        // SET n, (IY+*)
        case 0x18:
        case 0x19:
        case 0x1A:
        case 0x1B:
        case 0x1C:
        case 0x1D:
        case 0x1E:
        case 0x1F:
          opResult = setBit(_memory.readByte(addr), (opCode & 0x38) >> 3);
      }
      _memory.writeByte(addr, opResult);

      final opCodeTarget = opCode & 0x07;
      switch (opCodeTarget) {
        case 0x00: // b
          b = opResult;
        case 0x01: // c
          c = opResult;
        case 0x02: // d
          d = opResult;
        case 0x03: // e
          e = opResult;
        case 0x04: // h
          h = opResult;
        case 0x05: // l
          l = opResult;
        case 0x06: // no register
          break;
        case 0x07: // a
          a = opResult;
      }

      tStates += 23;
    }
  }

  void DecodeFDOpcode() {
    final opCode = getNextByte();
    r++;

    int addr;

    switch (opCode) {
      // NOP
      case 0x00:
        tStates += 8;
// T-State is a guess - I can't find this documented

      // ADD IY, BC
      case 0x09:
        iy = ADD16(iy, bc);
        tStates += 4;

      // ADD IY, DE
      case 0x19:
        iy = ADD16(iy, de);
        tStates += 4;

      // LD IY, **
      case 0x21:
        iy = getNextWord();
        tStates += 14;

      // LD (**), IY
      case 0x22:
        _memory.writeWord(getNextWord(), iy);
        tStates += 20;

      // INC IY
      case 0x23:
        iy = (iy + 1) % 0x10000;
        tStates += 10;

      // INC IYH
      case 0x24:
        iyh = INC(iyh);
        tStates += 4;

      // DEC IYH
      case 0x25:
        iyh = DEC(iyh);
        tStates += 4;

      // LD IYH, *
      case 0x26:
        iyh = getNextByte();
        tStates += 11;

      // ADD IY, IY
      case 0x29:
        iy = ADD16(iy, iy);
        tStates += 4;

      // LD IY, (**)
      case 0x2A:
        iy = _memory.readWord(getNextWord());
        tStates += 20;

      // DEC IY
      case 0x2B:
        iy = (iy - 1) % 0x10000;
        tStates += 10;

      // INC IYL
      case 0x2C:
        iyl = INC(iyl);
        tStates += 4;

      // DEC IYL
      case 0x2D:
        iyl = DEC(iyl);
        tStates += 4;

      // LD IYH, *
      case 0x2E:
        iyl = getNextByte();
        tStates += 11;

      // INC (IY+*)
      case 0x34:
        addr = displacedIY();
        _memory.writeByte(addr, INC(_memory.readByte(addr)));
        tStates += 19;

      // DEC (IY+*)
      case 0x35:
        addr = displacedIY();
        _memory.writeByte(addr, DEC(_memory.readByte(addr)));
        tStates += 19;

      // LD (IY+*), *
      case 0x36:
        _memory.writeByte(displacedIY(), getNextByte());
        tStates += 19;

      // ADD IY, SP
      case 0x39:
        iy = ADD16(iy, sp);
        tStates += 4;

      // LD B, IYH
      case 0x44:
        b = iyh;
        tStates += 8;

      // LD B, IYL
      case 0x45:
        b = iyl;
        tStates += 8;

      // LD B, (IY+*)
      case 0x46:
        b = _memory.readByte(displacedIY());
        tStates += 19;

      // LD C, IYH
      case 0x4C:
        c = iyh;
        tStates += 8;

      // LD C, IYL
      case 0x4D:
        c = iyl;
        tStates += 8;

      // LD C, (IY+*)
      case 0x4E:
        c = _memory.readByte(displacedIY());
        tStates += 19;

      // LD D, IYH
      case 0x54:
        d = iyh;
        tStates += 8;

      // LD D, IYL
      case 0x55:
        d = iyl;
        tStates += 8;

      // LD D, (IY+*)
      case 0x56:
        d = _memory.readByte(displacedIY());
        tStates += 19;

      // LD E, IYH
      case 0x5C:
        e = iyh;
        tStates += 8;

      // LD E, IYL
      case 0x5D:
        e = iyl;
        tStates += 8;

      // LD E, (IY+*)
      case 0x5E:
        e = _memory.readByte(displacedIY());
        tStates += 19;

      // LD IYH, B
      case 0x60:
        iyh = b;
        tStates += 8;

      // LD IYH, C
      case 0x61:
        iyh = c;
        tStates += 8;

      // LD IYH, D
      case 0x62:
        iyh = d;
        tStates += 8;

      // LD IYH, E
      case 0x63:
        iyh = e;
        tStates += 8;

      // LD IYH, IYH
      case 0x64:
        tStates += 8;

      // LD IYH, IYL
      case 0x65:
        iyh = iyl;
        tStates += 8;

      // LD H, (IY+*)
      case 0x66:
        h = _memory.readByte(displacedIY());
        tStates += 19;

      // LD IYH, A
      case 0x67:
        iyh = a;
        tStates += 8;

      // LD IYL, B
      case 0x68:
        iyl = b;
        tStates += 8;

      // LD IYL, C
      case 0x69:
        iyl = c;
        tStates += 8;

      // LD IYL, D
      case 0x6A:
        iyl = d;
        tStates += 8;

      // LD IYL, E
      case 0x6B:
        iyl = e;
        tStates += 8;

      // LD IYL, IYH
      case 0x6C:
        iyl = iyh;
        tStates += 8;

      // LD IYL, IYL
      case 0x6D:
        tStates += 8;

      // LD L, (IY+*)
      case 0x6E:
        l = _memory.readByte(displacedIY());
        tStates += 19;

      // LD IYL, A
      case 0x6F:
        iyl = a;
        tStates += 8;

      // LD (IY+*), B
      case 0x70:
        _memory.writeByte(displacedIY(), b);
        tStates += 19;

      // LD (IY+*), C
      case 0x71:
        _memory.writeByte(displacedIY(), c);
        tStates += 19;

      // LD (IY+*), D
      case 0x72:
        _memory.writeByte(displacedIY(), d);
        tStates += 19;

      // LD (IY+*), E
      case 0x73:
        _memory.writeByte(displacedIY(), e);
        tStates += 19;

      // LD (IY+*), H
      case 0x74:
        _memory.writeByte(displacedIY(), h);
        tStates += 19;

      // LD (IY+*), L
      case 0x75:
        _memory.writeByte(displacedIY(), l);
        tStates += 19;

      // LD (IY+*), A
      case 0x77:
        _memory.writeByte(displacedIY(), a);
        tStates += 19;

      // LD A, IYH
      case 0x7C:
        a = iyh;
        tStates += 8;

      // LD A, IYL
      case 0x7D:
        a = iyl;
        tStates += 8;

      // LD A, (IY+*)
      case 0x7E:
        a = _memory.readByte(displacedIY());
        tStates += 19;

      // ADD A, IYH
      case 0x84:
        a = ADD8(a, iyh);
        tStates += 4;

      // ADD A, IYL
      case 0x85:
        a = ADD8(a, iyl);
        tStates += 4;

      // ADD A, (IY+*)
      case 0x86:
        a = ADD8(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // ADC A, IYH
      case 0x8C:
        a = ADC8(a, iyh);
        tStates += 4;

      // ADC A, IYL
      case 0x8D:
        a = ADC8(a, iyl);
        tStates += 4;

      // ADC A, (IY+*)
      case 0x8E:
        a = ADC8(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // SUB IYH
      case 0x94:
        a = SUB8(a, iyh);
        tStates += 4;

      // SUB IYL
      case 0x95:
        a = SUB8(a, iyl);
        tStates += 4;

      // SUB (IY+*)
      case 0x96:
        a = SUB8(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // SBC A, IYH
      case 0x9C:
        a = SBC8(a, iyh);
        tStates += 4;

      // SBC A, IYL
      case 0x9D:
        a = SBC8(a, iyl);
        tStates += 4;

      // SBC A, (IY+*)
      case 0x9E:
        a = SBC8(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // AND IYH
      case 0xA4:
        a = AND(a, iyh);
        tStates += 4;

      // AND IYL
      case 0xA5:
        a = AND(a, iyl);
        tStates += 4;

      // AND (IY+*)
      case 0xA6:
        a = AND(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // XOR (IY+*)
      case 0xAE:
        a = XOR(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // XOR IYH
      case 0xAC:
        a = XOR(a, iyh);
        tStates += 4;

      // XOR IYL
      case 0xAD:
        a = XOR(a, iyl);
        tStates += 4;

      // OR IYH
      case 0xB4:
        a = OR(a, iyh);
        tStates += 4;

      // OR IYL
      case 0xB5:
        a = OR(a, iyl);
        tStates += 4;

      // OR (IY+*)
      case 0xB6:
        a = OR(a, _memory.readByte(displacedIY()));
        tStates += 15;

      // CP IYH
      case 0xBC:
        CP(iyh);
        tStates += 4;

      // CP IYL
      case 0xBD:
        CP(iyl);
        tStates += 4;

      // CP (IY+*)
      case 0xBE:
        CP(_memory.readByte(displacedIY()));
        tStates += 15;

      // bitwise instructions
      case 0xCB:
        DecodeFDCBOpCode();

      // POP IY
      case 0xE1:
        iy = POP();
        tStates += 14;

      // EX (SP), IY
      case 0xE3:
        final temp = _memory.readWord(sp);
        _memory.writeWord(sp, iy);
        iy = temp;
        tStates += 23;

      // PUSH IY
      case 0xE5:
        PUSH(iy);
        tStates += 15;

      // JP (IY)
      // note that the brackets in the instruction are an eccentricity, the result
      // should be iy rather than the contents of addr(iy)
      case 0xE9:
        pc = iy;
        tStates += 8;

      // LD SP, IY
      case 0xF9:
        sp = iy;
        tStates += 10;

      default:
        if (_extendedCodes.contains(opCode)) {
          tStates += 4; // instructions take an extra 4 bytes over unprefixed
          pc--; // go back one
          executeNextInstruction();
        } else {
          throw Exception("Opcode FD${toHex8(opCode)} not understood. ");
        }
    }
  }

  bool executeNextInstruction() {
    halt = false;
    final opCode = getNextByte();

    r = (r + 1) % 0x100;

    switch (opCode) {
      // NOP
      case 0x00:
        tStates += 4;

      // LD BC, **
      case 0x01:
        bc = getNextWord();
        tStates += 10;

      // LD (BC), A
      case 0x02:
        _memory.writeByte(bc, a);
        tStates += 7;

      // INC BC
      case 0x03:
        bc = (bc + 1) % 0x10000;
        tStates += 6;

      // INC B
      case 0x04:
        b = INC(b);

      // DEC B
      case 0x05:
        b = DEC(b);

      // LD B, *
      case 0x06:
        b = getNextByte();
        tStates += 7;

      // RLCA
      case 0x07:
        RLCA();

      // EX AF, AF'
      case 0x08:
        EX_AFAFPrime();

      // ADD HL, BC
      case 0x09:
        hl = ADD16(hl, bc);

      // LD A, (BC)
      case 0x0A:
        a = _memory.readByte(bc);
        tStates += 7;

      // DEC BC
      case 0x0B:
        bc = (bc - 1) % 0x10000;
        tStates += 6;

      // INC C
      case 0x0C:
        c = INC(c);

      // DEC C
      case 0x0D:
        c = DEC(c);

      // LD C, *
      case 0x0E:
        c = getNextByte();
        tStates += 7;

      // RRCA
      case 0x0F:
        RRCA();

      // DJNZ *
      case 0x10:
        DJNZ(getNextByte());

      // LD DE, **
      case 0x11:
        de = getNextWord();
        tStates += 10;

      // LD (DE), A
      case 0x12:
        _memory.writeByte(de, a);
        tStates += 7;

      // INC DE
      case 0x13:
        de = (de + 1) % 0x10000;
        tStates += 6;

      // INC D
      case 0x14:
        d = INC(d);

      // DEC D
      case 0x15:
        d = DEC(d);

      // LD D, *
      case 0x16:
        d = getNextByte();
        tStates += 7;

      // RLA
      case 0x17:
        RLA();

      // JR *
      case 0x18:
        JR(getNextByte());

      // ADD HL, DE
      case 0x19:
        hl = ADD16(hl, de);

      // LD A, (DE)
      case 0x1A:
        a = _memory.readByte(de);
        tStates += 7;

      // DEC DE
      case 0x1B:
        de = (de - 1) % 0x10000;
        tStates += 6;

      // INC E
      case 0x1C:
        e = INC(e);

      // DEC E
      case 0x1D:
        e = DEC(e);

      // LD E, *
      case 0x1E:
        e = getNextByte();
        tStates += 7;

      // RRA
      case 0x1F:
        RRA();

      // JR NZ, *
      case 0x20:
        if (!fZ) {
          JR(getNextByte());
        } else {
          pc = (pc + 1) % 0x10000;
          tStates += 7;
        }

      // LD HL, **
      case 0x21:
        hl = getNextWord();
        tStates += 10;

      // LD (**), HL
      case 0x22:
        _memory.writeWord(getNextWord(), hl);
        tStates += 16;

      // INC HL
      case 0x23:
        hl = (hl + 1) % 0x10000;
        tStates += 6;

      // INC H
      case 0x24:
        h = INC(h);

      // DEC H
      case 0x25:
        h = DEC(h);

      // LD H, *
      case 0x26:
        h = getNextByte();
        tStates += 7;

      // DAA
      case 0x27:
        DAA();

      // JR Z, *
      case 0x28:
        if (fZ) {
          JR(getNextByte());
        } else {
          pc = (pc + 1) % 0x10000;
          tStates += 7;
        }

      // ADD HL, HL
      case 0x29:
        hl = ADD16(hl, hl);

      // LD HL, (**)
      case 0x2A:
        hl = _memory.readWord(getNextWord());
        tStates += 16;

      // DEC HL
      case 0x2B:
        hl = (hl - 1) % 0x10000;
        tStates += 6;

      // INC L
      case 0x2C:
        l = INC(l);

      // DEC L
      case 0x2D:
        l = DEC(l);

      // LD L, *
      case 0x2E:
        l = getNextByte();
        tStates += 7;

      // CPL
      case 0x2F:
        CPL();

      // JR NC, *
      case 0x30:
        if (!fC) {
          JR(getNextByte());
        } else {
          pc = (pc + 1) % 0x10000;
          tStates += 7;
        }

      // LD SP, **
      case 0x31:
        sp = getNextWord();
        tStates += 10;

      // LD (**), A
      case 0x32:
        _memory.writeByte(getNextWord(), a);
        tStates += 13;

      // INC SP
      case 0x33:
        sp = (sp + 1) % 0x10000;
        tStates += 6;

      // INC (HL)
      case 0x34:
        _memory.writeByte(hl, INC(_memory.readByte(hl)));
        tStates += 7;

      // DEC (HL)
      case 0x35:
        _memory.writeByte(hl, DEC(_memory.readByte(hl)));
        tStates += 7;

      // LD (HL), *
      case 0x36:
        _memory.writeByte(hl, getNextByte());
        tStates += 10;

      // SCF
      case 0x37:
        SCF();
        tStates += 4;

      // JR C, *
      case 0x38:
        if (fC) {
          JR(getNextByte());
        } else {
          pc = (pc + 1) % 0x10000;
          tStates += 7;
        }

      // ADD HL, SP
      case 0x39:
        hl = ADD16(hl, sp);

      // LD A, (**)
      case 0x3A:
        a = _memory.readByte(getNextWord());
        tStates += 13;

      // DEC SP
      case 0x3B:
        sp = (sp - 1) % 0x10000;
        tStates += 6;

      // INC A
      case 0x3C:
        a = INC(a);

      // DEC A
      case 0x3D:
        a = DEC(a);

      // LD A, *
      case 0x3E:
        a = getNextByte();
        tStates += 7;

      // CCF
      case 0x3F:
        CCF();

      // LD B, B
      case 0x40:
        tStates += 4;

      // LD B, C
      case 0x41:
        b = c;
        tStates += 4;

      // LD B, D
      case 0x42:
        b = d;
        tStates += 4;

      // LD B, E
      case 0x43:
        b = e;
        tStates += 4;

      // LD B, H
      case 0x44:
        b = h;
        tStates += 4;

      // LD B, L
      case 0x45:
        b = l;
        tStates += 4;

      // LD B, (HL)
      case 0x46:
        b = _memory.readByte(hl);
        tStates += 7;

      // LD B, A
      case 0x47:
        b = a;
        tStates += 4;

      // LD C, B
      case 0x48:
        c = b;
        tStates += 4;

      // LD C, C
      case 0x49:
        tStates += 4;

      // LD C, D
      case 0x4A:
        c = d;
        tStates += 4;

      // LD C, E
      case 0x4B:
        c = e;
        tStates += 4;

      // LD C, H
      case 0x4C:
        c = h;
        tStates += 4;

      // LD C, L
      case 0x4D:
        c = l;
        tStates += 4;

      // LD C, (HL)
      case 0x4E:
        c = _memory.readByte(hl);
        tStates += 7;

      // LD C, A
      case 0x4F:
        c = a;
        tStates += 4;

      // LD D, B
      case 0x50:
        d = b;
        tStates += 4;

      // LD D, C
      case 0x51:
        d = c;
        tStates += 4;

      // LD D, D
      case 0x52:
        tStates += 4;

      // LD D, E
      case 0x53:
        d = e;
        tStates += 4;

      // LD D, H
      case 0x54:
        d = h;
        tStates += 4;

      // LD D, L
      case 0x55:
        d = l;
        tStates += 4;

      // LD D, (HL)
      case 0x56:
        d = _memory.readByte(hl);
        tStates += 7;

      // LD D, A
      case 0x57:
        d = a;
        tStates += 4;

      // LD E, B
      case 0x58:
        e = b;
        tStates += 4;

      // LD E, C
      case 0x59:
        e = c;
        tStates += 4;

      // LD E, D
      case 0x5A:
        e = d;
        tStates += 4;

      // LD E, E
      case 0x5B:
        tStates += 4;

      // LD E, H
      case 0x5C:
        e = h;
        tStates += 4;

      // LD E, L
      case 0x5D:
        e = l;
        tStates += 4;

      // LD E, (HL)
      case 0x5E:
        e = _memory.readByte(hl);
        tStates += 7;

      // LD E, A
      case 0x5F:
        e = a;
        tStates += 4;

      // LD H, B
      case 0x60:
        h = b;
        tStates += 4;

      // LD H, C
      case 0x61:
        h = c;
        tStates += 4;

      // LD H, D
      case 0x62:
        h = d;
        tStates += 4;

      // LD H, E
      case 0x63:
        h = e;
        tStates += 4;

      // LD H, H
      case 0x64:
        tStates += 4;

      // LD H, L
      case 0x65:
        h = l;
        tStates += 4;

      // LD H, (HL)
      case 0x66:
        h = _memory.readByte(hl);
        tStates += 7;

      // LD H, A
      case 0x67:
        h = a;
        tStates += 4;

      // LD L, B
      case 0x68:
        l = b;
        tStates += 4;

      // LD L, C
      case 0x69:
        l = c;
        tStates += 4;

      // LD L, D
      case 0x6A:
        l = d;
        tStates += 4;

      // LD L, E
      case 0x6B:
        l = e;
        tStates += 4;

      // LD L, H
      case 0x6C:
        l = h;
        tStates += 4;

      // LD L, L
      case 0x6D:
        tStates += 4;

      // LD L, (HL)
      case 0x6E:
        l = _memory.readByte(hl);
        tStates += 7;

      // LD L, A
      case 0x6F:
        l = a;
        tStates += 4;

      // LD (HL), B
      case 0x70:
        _memory.writeByte(hl, b);
        tStates += 7;

      // LD (HL), C
      case 0x71:
        _memory.writeByte(hl, c);
        tStates += 7;

      // LD (HL), D
      case 0x72:
        _memory.writeByte(hl, d);
        tStates += 7;

      // LD (HL), E
      case 0x73:
        _memory.writeByte(hl, e);
        tStates += 7;

      // LD (HL), H
      case 0x74:
        _memory.writeByte(hl, h);
        tStates += 7;

      // LD (HL), L
      case 0x75:
        _memory.writeByte(hl, l);
        tStates += 7;

      // HALT
      case 0x76:
        tStates += 4;
        halt = true;
        pc--; // return to HALT, just keep executing it.

      // LD (HL), A
      case 0x77:
        _memory.writeByte(hl, a);
        tStates += 7;

      // LD A, B
      case 0x78:
        a = b;
        tStates += 4;

      // LD A, C
      case 0x79:
        a = c;
        tStates += 4;

      // LD A, D
      case 0x7A:
        a = d;
        tStates += 4;

      // LD A, E
      case 0x7B:
        a = e;
        tStates += 4;

      // LD A, H
      case 0x7C:
        a = h;
        tStates += 4;

      // LD A, L
      case 0x7D:
        a = l;
        tStates += 4;

      // LD A, (HL)
      case 0x7E:
        a = _memory.readByte(hl);
        tStates += 7;

      // LD A, A
      case 0x7F:
        tStates += 4;

      // ADD A, B
      case 0x80:
        a = ADD8(a, b);

      // ADD A, C
      case 0x81:
        a = ADD8(a, c);

      // ADD A, D
      case 0x82:
        a = ADD8(a, d);

      // ADD A, E
      case 0x83:
        a = ADD8(a, e);

      // ADD A, H
      case 0x84:
        a = ADD8(a, h);

      // ADD A, L
      case 0x85:
        a = ADD8(a, l);

      // ADD A, (HL)
      case 0x86:
        a = ADD8(a, _memory.readByte(hl));
        tStates += 3;

      // ADD A, A
      case 0x87:
        a = ADD8(a, a);

      // ADC A, B
      case 0x88:
        a = ADC8(a, b);

      // ADC A, C
      case 0x89:
        a = ADC8(a, c);

      // ADC A, D
      case 0x8A:
        a = ADC8(a, d);

      // ADC A, E
      case 0x8B:
        a = ADC8(a, e);

      // ADC A, H
      case 0x8C:
        a = ADC8(a, h);

      // ADC A, L
      case 0x8D:
        a = ADC8(a, l);

      // ADC A, (HL)
      case 0x8E:
        a = ADC8(a, _memory.readByte(hl));
        tStates += 3;

      // ADC A, A
      case 0x8F:
        a = ADC8(a, a);

      // SUB B
      case 0x90:
        a = SUB8(a, b);

      // SUB C
      case 0x91:
        a = SUB8(a, c);

      // SUB D
      case 0x92:
        a = SUB8(a, d);

      // SUB E
      case 0x93:
        a = SUB8(a, e);

      // SUB H
      case 0x94:
        a = SUB8(a, h);

      // SUB L
      case 0x95:
        a = SUB8(a, l);

      // SUB (HL)
      case 0x96:
        a = SUB8(a, _memory.readByte(hl));
        tStates += 3;

      // SUB A
      case 0x97:
        a = SUB8(a, a);

      // SBC A, B
      case 0x98:
        a = SBC8(a, b);

      // SBC A, C
      case 0x99:
        a = SBC8(a, c);

      // SBC A, D
      case 0x9A:
        a = SBC8(a, d);

      // SBC A, E
      case 0x9B:
        a = SBC8(a, e);

      // SBC A, H
      case 0x9C:
        a = SBC8(a, h);

      // SBC A, L
      case 0x9D:
        a = SBC8(a, l);

      // SBC A, (HL)
      case 0x9E:
        a = SBC8(a, _memory.readByte(hl));
        tStates += 3;

      // SBC A, A
      case 0x9F:
        a = SBC8(a, a);

      // AND B
      case 0xA0:
        a = AND(a, b);

      // AND C
      case 0xA1:
        a = AND(a, c);

      // AND D
      case 0xA2:
        a = AND(a, d);

      // AND E
      case 0xA3:
        a = AND(a, e);

      // AND H
      case 0xA4:
        a = AND(a, h);

      // AND L
      case 0xA5:
        a = AND(a, l);

      // AND (HL)
      case 0xA6:
        a = AND(a, _memory.readByte(hl));
        tStates += 3;

      // AND A
      case 0xA7:
        a = AND(a, a);

      // XOR B
      case 0xA8:
        a = XOR(a, b);

      // XOR C
      case 0xA9:
        a = XOR(a, c);

      // XOR D
      case 0xAA:
        a = XOR(a, d);

      // XOR E
      case 0xAB:
        a = XOR(a, e);

      // XOR H
      case 0xAC:
        a = XOR(a, h);

      // XOR L
      case 0xAD:
        a = XOR(a, l);

      // XOR (HL)
      case 0xAE:
        a = XOR(a, _memory.readByte(hl));
        tStates += 3;

      // XOR A
      case 0xAF:
        a = XOR(a, a);

      // OR B
      case 0xB0:
        a = OR(a, b);

      // OR C
      case 0xB1:
        a = OR(a, c);

      // OR D
      case 0xB2:
        a = OR(a, d);

      // OR E
      case 0xB3:
        a = OR(a, e);

      // OR H
      case 0xB4:
        a = OR(a, h);

      // OR L
      case 0xB5:
        a = OR(a, l);

      // OR (HL)
      case 0xB6:
        a = OR(a, _memory.readByte(hl));
        tStates += 3;

      // OR A
      case 0xB7:
        a = OR(a, a);

      // CP B
      case 0xB8:
        CP(b);

      // CP C
      case 0xB9:
        CP(c);

      // CP D
      case 0xBA:
        CP(d);

      // CP E
      case 0xBB:
        CP(e);

      // CP H
      case 0xBC:
        CP(h);

      // CP L
      case 0xBD:
        CP(l);

      // CP (HL)
      case 0xBE:
        CP(_memory.readByte(hl));
        tStates += 3;

      // CP A
      case 0xBF:
        CP(a);

      // RET NZ
      case 0xC0:
        if (!fZ) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // POP BC
      case 0xC1:
        bc = POP();
        tStates += 10;

      // JP NZ, **
      case 0xC2:
        if (!fZ) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // JP **
      case 0xC3:
        pc = getNextWord();
        tStates += 10;

      // CALL NZ, **
      case 0xC4:
        if (!fZ) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // PUSH BC
      case 0xC5:
        PUSH(bc);
        tStates += 11;

      // ADD A, *
      case 0xC6:
        a = ADD8(a, getNextByte());
        tStates += 3;

      // RST 00h
      case 0xC7:
        RST(0x00);

      // RET Z
      case 0xC8:
        if (fZ) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // RET
      case 0xC9:
        pc = POP();
        tStates += 10;

      // JP Z, **
      case 0xCA:
        if (fZ) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // BITWISE INSTRUCTIONS
      case 0xCB:
        DecodeCBOpcode();

      // CALL Z, **
      case 0xCC:
        if (fZ) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // CALL **
      case 0xCD:
        CALL();

      // ADC A, *
      case 0xCE:
        a = ADC8(a, getNextByte());
        tStates += 3;

      // RST 08h
      case 0xCF:
        RST(0x08);

      // RET NC
      case 0xD0:
        if (!fC) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // POP DE
      case 0xD1:
        de = POP();
        tStates += 10;

      // JP NC, **
      case 0xD2:
        if (!fC) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // OUT (*), A
      case 0xD3:
        OUTA(getNextByte(), a);
        tStates += 11;

      // CALL NC, **
      case 0xD4:
        if (!fC) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // PUSH DE
      case 0xD5:
        PUSH(de);
        tStates += 11;

      // SUB *
      case 0xD6:
        a = SUB8(a, getNextByte());
        tStates += 3;

      // RST 10h
      case 0xD7:
        RST(0x10);

      // RET C
      case 0xD8:
        if (fC) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // EXX
      case 0xD9:
        final oldB = b, oldC = c, oldD = d, oldE = e, oldH = h, oldL = l;
        b = b_;
        c = c_;
        d = d_;
        e = e_;
        h = h_;
        l = l_;
        b_ = oldB;
        c_ = oldC;
        d_ = oldD;
        e_ = oldE;
        h_ = oldH;
        l_ = oldL;
        tStates += 4;

      // JP C, **
      case 0xDA:
        if (fC) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // IN A, (*)
      case 0xDB:
        INA(getNextByte());
        tStates += 11;

      // CALL C, **
      case 0xDC:
        if (fC) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // IX OPERATIONS
      case 0xDD:
        DecodeDDOpcode();

      // SBC A, *
      case 0xDE:
        a = SBC8(a, getNextByte());
        tStates += 3;

      // RST 18h
      case 0xDF:
        RST(0x18);

      // RET PO
      case 0xE0:
        if (!fPV) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // POP HL
      case 0xE1:
        hl = POP();
        tStates += 10;

      // JP PO, **
      case 0xE2:
        if (!fPV) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // EX (SP), HL
      case 0xE3:
        final temp = hl;
        hl = _memory.readWord(sp);
        _memory.writeWord(sp, temp);
        tStates += 19;

      // CALL PO, **
      case 0xE4:
        if (!fPV) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // PUSH HL
      case 0xE5:
        PUSH(hl);
        tStates += 11;

      // AND *
      case 0xE6:
        a = AND(a, getNextByte());
        tStates += 3;

      // RST 20h
      case 0xE7:
        RST(0x20);

      // RET PE
      case 0xE8:
        if (fPV) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // JP (HL)
      // note that the brackets in the instruction are an eccentricity, the result
      // should be hl rather than the contents of addr(hl)
      case 0xE9:
        pc = hl;
        tStates += 4;

      // JP PE, **
      case 0xEA:
        if (fPV) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // EX DE, HL
      case 0xEB:
        final oldD = d, oldE = e;
        d = h;
        e = l;
        h = oldD;
        l = oldE;
        tStates += 4;

      // CALL PE, **
      case 0xEC:
        if (fPV) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // EXTD INSTRUCTIONS
      case 0xED:
        DecodeEDOpcode();

      // XOR *
      case 0xEE:
        a = XOR(a, getNextByte());
        tStates += 3;

      // RST 28h
      case 0xEF:
        RST(0x28);

      // RET P
      case 0xF0:
        if (!fS) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // POP AF
      case 0xF1:
        af = POP();
        tStates += 10;

      // JP P, **
      case 0xF2:
        if (!fS) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // DI
      case 0xF3:
        iff1 = false;
        iff2 = false;
        tStates += 4;

      // CALL P, **
      case 0xF4:
        if (!fS) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // PUSH AF
      case 0xF5:
        PUSH(af);
        tStates += 11;

      // OR *
      case 0xF6:
        a = OR(a, getNextByte());
        tStates += 3;

      // RST 30h
      case 0xF7:
        RST(0x30);

      // RET M
      case 0xF8:
        if (fS) {
          pc = POP();
          tStates += 11;
        } else {
          tStates += 5;
        }

      // LD SP, HL
      case 0xF9:
        sp = hl;
        tStates += 6;

      // JP M, **
      case 0xFA:
        if (fS) {
          pc = getNextWord();
        } else {
          pc = (pc + 2) % 0x10000;
        }
        tStates += 10;

      // EI
      case 0xFB:
        iff1 = true;
        iff2 = true;
        tStates += 4;

      // CALL M, **
      case 0xFC:
        if (fS) {
          CALL();
        } else {
          pc = (pc + 2) % 0x10000;
          tStates += 10;
        }

      // IY INSTRUCTIONS
      case 0xFD:
        DecodeFDOpcode();

      // CP *
      case 0xFE:
        CP(getNextByte());
        tStates += 3;

      // RST 38h
      case 0xFF:
        RST(0x38);
    }

    return true;
  }
}
