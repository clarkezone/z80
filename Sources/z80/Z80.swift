// z80.swift -- implements the Zilog Z80 processor core
//
// Reference notes:
//
// The Z80 microprocessor user manual can be downloaded from Zilog:
//    http://tinyurl.com/z80manual
//
// An excellent additional reference is "The Undocumented Z80 Documented", at:
//    http://www.z80.info/zip/z80-documented.pdf

enum InterruptMode {
    case im0, im1, im2
}

extension UInt16 {
    /// Extract the high byte of a 16-bit value.
    var highByte: UInt8 { UInt8((self & 0xFF00) >> 8) }

    /// Extract the low byte of a 16-bit value.
    var lowByte: UInt8 { UInt8(self & 0x00FF) }

    static func createWord(_ highByte: UInt8, _ lowByte: UInt8) -> UInt16 {
        UInt16(highByte) << 8 + UInt16(lowByte)
    }
}

public struct Z80 {
    let memory = Memory<UInt16>(sizeInBytes: 65536)
    
    // Core registers
    var a: UInt8 = 0xFF, f: UInt8 = 0xFF
    var b: UInt8 = 0xFF, c: UInt8 = 0xFF
    var d: UInt8 = 0xFF, e: UInt8 = 0xFF
    var h: UInt8 = 0xFF, l: UInt8 = 0xFF
    var ix: UInt16 = 0xFFFF, iy: UInt16 = 0xFFFF
    
    // The alternate register set (A', F', B', C', D', E', H', L')
    var a_: UInt8 = 0xFF, f_: UInt8 = 0xFF
    var b_: UInt8 = 0xFF, c_: UInt8 = 0xFF
    var d_: UInt8 = 0xFF, e_: UInt8 = 0xFF
    var h_: UInt8 = 0xFF, l_: UInt8 = 0xFF
    
    /// Interrupt Page Address register (I).
    var i: UInt8 = 0xFF
    
    /// Memory Refresh register (R).
    var r: UInt8 = 0xFF
    
    /// Program Counter (PC).
    var pc: UInt16 = 0
    
    /// Stack Pointer (SP).
    var sp: UInt16 = 0xFFFF
    
    /// Interrupt Flip-Flop (IFF1).
    var iff1 = false
    
    /// Interrupt Flip-Flop (IFF2).
    ///
    /// This is used to cache the value of the Interrupt Flag when a Non-Maskable
    /// Interrupt occurs.
    var iff2 = false
    
    /// Interrupt Mode (IM).
    var im: InterruptMode = .im0
    
    /// Number of  cycles that have occurred since the last clock reset.
    var tStates = 0
    
    /// Whether the processor is halted or not
    var halt = false
    
//    /// Convert two bytes into a 16-bit word.
//    func createWord(_ highByte: UInt8, _ lowByte: UInt8) -> UInt16 {
//        UInt16(highByte) << 8 + UInt16(lowByte)
//    }
    
    var af: UInt16 {
        get { UInt16.createWord(a, f) }
        set { a = newValue.highByte; f = newValue.lowByte }
    }
    
    var af_: UInt16 {
        get { UInt16.createWord(a_, f_) }
        set { a_ = newValue.highByte; f_ = newValue.lowByte }
    }
    
    var bc: UInt16 {
        get { UInt16.createWord(b, c) }
        set { b = newValue.highByte; c = newValue.lowByte }
    }
    
    var bc_: UInt16 {
        get { UInt16.createWord(b_, c_) }
        set { b_ = newValue.highByte; c_ = newValue.lowByte }
    }
    
    var de: UInt16 {
        get { UInt16.createWord(d, e) }
        set { d = newValue.highByte; e = newValue.lowByte }
    }
    
    var de_: UInt16 {
        get { UInt16.createWord(d_, e_) }
        set { d_ = newValue.highByte; e_ = newValue.lowByte }
    }
    
    var hl: UInt16 {
        get { UInt16.createWord(h, l) }
        set { h = newValue.highByte; l = newValue.lowByte }
    }
    
    var hl_: UInt16 {
        get { UInt16.createWord(h_, l_) }
        set { h_ = newValue.highByte; l_ = newValue.lowByte }
    }
    
    var ixh: UInt8 {
        get { ix.highByte }
        set { ix = UInt16.createWord(newValue, ixl) }
    }

    var ixl: UInt8 {
        get { ix.lowByte }
        set { ix = UInt16.createWord(ixh, newValue) }
    }

    var iyh: UInt8 {
        get { iy.highByte }
        set { iy = UInt16.createWord(newValue, iyl) }
    }

    var iyl: UInt8 {
        get { iy.lowByte }
        set { iy = UInt16.createWord(iyh, newValue) }
    }
    
    struct Flags: OptionSet {
        let rawValue: UInt8
        
        static let c = Flags(rawValue: 1 << 0) // carry
        static let n = Flags(rawValue: 1 << 1) // add/subtract
        static let pv = Flags(rawValue: 1 << 2) // parity overflow
        static let f3 = Flags(rawValue: 1 << 3)
        static let h = Flags(rawValue: 1 << 4) // half carry
        static let f5 = Flags(rawValue: 1 << 5)
        static let z = Flags(rawValue: 1 << 6) // zero
        static let s = Flags(rawValue: 1 << 7) // sign
    }

    var flags: Flags { get { Flags(rawValue: f) } set { f = newValue.rawValue }}
    
    /// Reset the Z80 to an initial power-on configuration.
    ///
    /// Initial register states are set per section 2.4 of http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
    mutating func reset() {
        af = 0xFFFF
        af_ = 0xFFFF
        bc = 0xFFFF
        bc_ = 0xFFFF
        de = 0xFFFF
        de_ = 0xFFFF
        hl = 0xFFFF
        hl_ = 0xFFFF
        ix = 0xFFFF
        iy = 0xFFFF
        sp = 0xFFFF
        pc = 0x0000
        iff1 = false
        iff2 = false
        im = .im0
        i = 0xFF
        r = 0xFF
        
        tStates = 0
    }
    
    func getNextByte() -> UInt8 { memory.readByte(pc) }
    func getNextWord() -> UInt16 { memory.readWord(pc) }
    
//
//
//    func AND(a: UInt8, reg: UInt8) -> int {
//      a &= reg;
//      fS = isSign8(a);
//      fZ = isZero(a);
//      fH = true;
//      f5 = isBitSet(a, 5);
//      f3 = isBitSet(a, 3);
//      fPV = isParity(a);
//      fN = false;
//      fC = false;
//
//      tStates += 4;
//
//      return a;
//    }
//
//    mutating func executeNextInstruction() {
//      halt = false;
//      let opCode = getNextByte();
//
//      r = (r + 1) % 0x100;
//
//      switch (opCode) {
//        // NOP
//        case 0x00:
//          tStates += 4;
//
//        // LD BC, **
//        case 0x01:
//          bc = getNextWord();
//          tStates += 10;
//
//        // LD (BC), A
//        case 0x02:
//          memory.writeByte(bc, a);
//          tStates += 7;
//
//        // INC BC
//        case 0x03:
//          bc = (bc + 1) % 0x10000;
//          tStates += 6;
//
//        // INC B
//        case 0x04:
//          b = INC(b);
//
//        // DEC B
//        case 0x05:
//          b = DEC(b);
//
//        // LD B, *
//        case 0x06:
//          b = getNextByte();
//          tStates += 7;
//
//        // RLCA
//        case 0x07:
//          RLCA();
//
//        // EX AF, AF'
//        case 0x08:
//          EX_AFAFPrime();
//
//        // ADD HL, BC
//        case 0x09:
//          hl = ADD16(hl, bc);
//
//        // LD A, (BC)
//        case 0x0A:
//          a = memory.readByte(bc);
//          tStates += 7;
//
//        // DEC BC
//        case 0x0B:
//          bc = (bc - 1) % 0x10000;
//          tStates += 6;
//
//        // INC C
//        case 0x0C:
//          c = INC(c);
//
//        // DEC C
//        case 0x0D:
//          c = DEC(c);
//
//        // LD C, *
//        case 0x0E:
//          c = getNextByte();
//          tStates += 7;
//
//        // RRCA
//        case 0x0F:
//          RRCA();
//
//        // DJNZ *
//        case 0x10:
//          DJNZ(getNextByte());
//
//        // LD DE, **
//        case 0x11:
//          de = getNextWord();
//          tStates += 10;
//
//        // LD (DE), A
//        case 0x12:
//          memory.writeByte(de, a);
//          tStates += 7;
//
//        // INC DE
//        case 0x13:
//          de = (de + 1) % 0x10000;
//          tStates += 6;
//
//        // INC D
//        case 0x14:
//          d = INC(d);
//
//        // DEC D
//        case 0x15:
//          d = DEC(d);
//
//        // LD D, *
//        case 0x16:
//          d = getNextByte();
//          tStates += 7;
//
//        // RLA
//        case 0x17:
//          RLA();
//
//        // JR *
//        case 0x18:
//          JR(getNextByte());
//
//        // ADD HL, DE
//        case 0x19:
//          hl = ADD16(hl, de);
//
//        // LD A, (DE)
//        case 0x1A:
//          a = memory.readByte(de);
//          tStates += 7;
//
//        // DEC DE
//        case 0x1B:
//          de = (de - 1) % 0x10000;
//          tStates += 6;
//
//        // INC E
//        case 0x1C:
//          e = INC(e);
//
//        // DEC E
//        case 0x1D:
//          e = DEC(e);
//
//        // LD E, *
//        case 0x1E:
//          e = getNextByte();
//          tStates += 7;
//
//        // RRA
//        case 0x1F:
//          RRA();
//
//        // JR NZ, *
//        case 0x20:
//          if (!fZ) {
//            JR(getNextByte());
//          } else {
//            pc = (pc + 1) % 0x10000;
//            tStates += 7;
//          }
//
//        // LD HL, **
//        case 0x21:
//          hl = getNextWord();
//          tStates += 10;
//
//        // LD (**), HL
//        case 0x22:
//          memory.writeWord(getNextWord(), hl);
//          tStates += 16;
//
//        // INC HL
//        case 0x23:
//          hl = (hl + 1) % 0x10000;
//          tStates += 6;
//
//        // INC H
//        case 0x24:
//          h = INC(h);
//
//        // DEC H
//        case 0x25:
//          h = DEC(h);
//
//        // LD H, *
//        case 0x26:
//          h = getNextByte();
//          tStates += 7;
//
//        // DAA
//        case 0x27:
//          DAA();
//
//        // JR Z, *
//        case 0x28:
//          if (fZ) {
//            JR(getNextByte());
//          } else {
//            pc = (pc + 1) % 0x10000;
//            tStates += 7;
//          }
//
//        // ADD HL, HL
//        case 0x29:
//          hl = ADD16(hl, hl);
//
//        // LD HL, (**)
//        case 0x2A:
//          hl = memory.readWord(getNextWord());
//          tStates += 16;
//
//        // DEC HL
//        case 0x2B:
//          hl = (hl - 1) % 0x10000;
//          tStates += 6;
//
//        // INC L
//        case 0x2C:
//          l = INC(l);
//
//        // DEC L
//        case 0x2D:
//          l = DEC(l);
//
//        // LD L, *
//        case 0x2E:
//          l = getNextByte();
//          tStates += 7;
//
//        // CPL
//        case 0x2F:
//          CPL();
//
//        // JR NC, *
//        case 0x30:
//          if (!fC) {
//            JR(getNextByte());
//          } else {
//            pc = (pc + 1) % 0x10000;
//            tStates += 7;
//          }
//
//        // LD SP, **
//        case 0x31:
//          sp = getNextWord();
//          tStates += 10;
//
//        // LD (**), A
//        case 0x32:
//          memory.writeByte(getNextWord(), a);
//          tStates += 13;
//
//        // INC SP
//        case 0x33:
//          sp = (sp + 1) % 0x10000;
//          tStates += 6;
//
//        // INC (HL)
//        case 0x34:
//          memory.writeByte(hl, INC(memory.readByte(hl)));
//          tStates += 7;
//
//        // DEC (HL)
//        case 0x35:
//          memory.writeByte(hl, DEC(memory.readByte(hl)));
//          tStates += 7;
//
//        // LD (HL), *
//        case 0x36:
//          memory.writeByte(hl, getNextByte());
//          tStates += 10;
//
//        // SCF
//        case 0x37:
//          SCF();
//          tStates += 4;
//
//        // JR C, *
//        case 0x38:
//          if (fC) {
//            JR(getNextByte());
//          } else {
//            pc = (pc + 1) % 0x10000;
//            tStates += 7;
//          }
//
//        // ADD HL, SP
//        case 0x39:
//          hl = ADD16(hl, sp);
//
//        // LD A, (**)
//        case 0x3A:
//          a = memory.readByte(getNextWord());
//          tStates += 13;
//
//        // DEC SP
//        case 0x3B:
//          sp = (sp - 1) % 0x10000;
//          tStates += 6;
//
//        // INC A
//        case 0x3C:
//          a = INC(a);
//
//        // DEC A
//        case 0x3D:
//          a = DEC(a);
//
//        // LD A, *
//        case 0x3E:
//          a = getNextByte();
//          tStates += 7;
//
//        // CCF
//        case 0x3F:
//          CCF();
//
//        // LD B, B
//        case 0x40:
//          tStates += 4;
//
//        // LD B, C
//        case 0x41:
//          b = c;
//          tStates += 4;
//
//        // LD B, D
//        case 0x42:
//          b = d;
//          tStates += 4;
//
//        // LD B, E
//        case 0x43:
//          b = e;
//          tStates += 4;
//
//        // LD B, H
//        case 0x44:
//          b = h;
//          tStates += 4;
//
//        // LD B, L
//        case 0x45:
//          b = l;
//          tStates += 4;
//
//        // LD B, (HL)
//        case 0x46:
//          b = memory.readByte(hl);
//          tStates += 7;
//
//        // LD B, A
//        case 0x47:
//          b = a;
//          tStates += 4;
//
//        // LD C, B
//        case 0x48:
//          c = b;
//          tStates += 4;
//
//        // LD C, C
//        case 0x49:
//          tStates += 4;
//
//        // LD C, D
//        case 0x4A:
//          c = d;
//          tStates += 4;
//
//        // LD C, E
//        case 0x4B:
//          c = e;
//          tStates += 4;
//
//        // LD C, H
//        case 0x4C:
//          c = h;
//          tStates += 4;
//
//        // LD C, L
//        case 0x4D:
//          c = l;
//          tStates += 4;
//
//        // LD C, (HL)
//        case 0x4E:
//          c = memory.readByte(hl);
//          tStates += 7;
//
//        // LD C, A
//        case 0x4F:
//          c = a;
//          tStates += 4;
//
//        // LD D, B
//        case 0x50:
//          d = b;
//          tStates += 4;
//
//        // LD D, C
//        case 0x51:
//          d = c;
//          tStates += 4;
//
//        // LD D, D
//        case 0x52:
//          tStates += 4;
//
//        // LD D, E
//        case 0x53:
//          d = e;
//          tStates += 4;
//
//        // LD D, H
//        case 0x54:
//          d = h;
//          tStates += 4;
//
//        // LD D, L
//        case 0x55:
//          d = l;
//          tStates += 4;
//
//        // LD D, (HL)
//        case 0x56:
//          d = memory.readByte(hl);
//          tStates += 7;
//
//        // LD D, A
//        case 0x57:
//          d = a;
//          tStates += 4;
//
//        // LD E, B
//        case 0x58:
//          e = b;
//          tStates += 4;
//
//        // LD E, C
//        case 0x59:
//          e = c;
//          tStates += 4;
//
//        // LD E, D
//        case 0x5A:
//          e = d;
//          tStates += 4;
//
//        // LD E, E
//        case 0x5B:
//          tStates += 4;
//
//        // LD E, H
//        case 0x5C:
//          e = h;
//          tStates += 4;
//
//        // LD E, L
//        case 0x5D:
//          e = l;
//          tStates += 4;
//
//        // LD E, (HL)
//        case 0x5E:
//          e = memory.readByte(hl);
//          tStates += 7;
//
//        // LD E, A
//        case 0x5F:
//          e = a;
//          tStates += 4;
//
//        // LD H, B
//        case 0x60:
//          h = b;
//          tStates += 4;
//
//        // LD H, C
//        case 0x61:
//          h = c;
//          tStates += 4;
//
//        // LD H, D
//        case 0x62:
//          h = d;
//          tStates += 4;
//
//        // LD H, E
//        case 0x63:
//          h = e;
//          tStates += 4;
//
//        // LD H, H
//        case 0x64:
//          tStates += 4;
//
//        // LD H, L
//        case 0x65:
//          h = l;
//          tStates += 4;
//
//        // LD H, (HL)
//        case 0x66:
//          h = memory.readByte(hl);
//          tStates += 7;
//
//        // LD H, A
//        case 0x67:
//          h = a;
//          tStates += 4;
//
//        // LD L, B
//        case 0x68:
//          l = b;
//          tStates += 4;
//
//        // LD L, C
//        case 0x69:
//          l = c;
//          tStates += 4;
//
//        // LD L, D
//        case 0x6A:
//          l = d;
//          tStates += 4;
//
//        // LD L, E
//        case 0x6B:
//          l = e;
//          tStates += 4;
//
//        // LD L, H
//        case 0x6C:
//          l = h;
//          tStates += 4;
//
//        // LD L, L
//        case 0x6D:
//          tStates += 4;
//
//        // LD L, (HL)
//        case 0x6E:
//          l = memory.readByte(hl);
//          tStates += 7;
//
//        // LD L, A
//        case 0x6F:
//          l = a;
//          tStates += 4;
//
//        // LD (HL), B
//        case 0x70:
//          memory.writeByte(hl, b);
//          tStates += 7;
//
//        // LD (HL), C
//        case 0x71:
//          memory.writeByte(hl, c);
//          tStates += 7;
//
//        // LD (HL), D
//        case 0x72:
//          memory.writeByte(hl, d);
//          tStates += 7;
//
//        // LD (HL), E
//        case 0x73:
//          memory.writeByte(hl, e);
//          tStates += 7;
//
//        // LD (HL), H
//        case 0x74:
//          memory.writeByte(hl, h);
//          tStates += 7;
//
//        // LD (HL), L
//        case 0x75:
//          memory.writeByte(hl, l);
//          tStates += 7;
//
//        // HALT
//        case 0x76:
//          tStates += 4;
//          halt = true;
//          pc--; // return to HALT, just keep executing it.
//
//        // LD (HL), A
//        case 0x77:
//          memory.writeByte(hl, a);
//          tStates += 7;
//
//        // LD A, B
//        case 0x78:
//          a = b;
//          tStates += 4;
//
//        // LD A, C
//        case 0x79:
//          a = c;
//          tStates += 4;
//
//        // LD A, D
//        case 0x7A:
//          a = d;
//          tStates += 4;
//
//        // LD A, E
//        case 0x7B:
//          a = e;
//          tStates += 4;
//
//        // LD A, H
//        case 0x7C:
//          a = h;
//          tStates += 4;
//
//        // LD A, L
//        case 0x7D:
//          a = l;
//          tStates += 4;
//
//        // LD A, (HL)
//        case 0x7E:
//          a = memory.readByte(hl);
//          tStates += 7;
//
//        // LD A, A
//        case 0x7F:
//          tStates += 4;
//
//        // ADD A, B
//        case 0x80:
//          a = ADD8(a, b);
//
//        // ADD A, C
//        case 0x81:
//          a = ADD8(a, c);
//
//        // ADD A, D
//        case 0x82:
//          a = ADD8(a, d);
//
//        // ADD A, E
//        case 0x83:
//          a = ADD8(a, e);
//
//        // ADD A, H
//        case 0x84:
//          a = ADD8(a, h);
//
//        // ADD A, L
//        case 0x85:
//          a = ADD8(a, l);
//
//        // ADD A, (HL)
//        case 0x86:
//          a = ADD8(a, memory.readByte(hl));
//          tStates += 3;
//
//        // ADD A, A
//        case 0x87:
//          a = ADD8(a, a);
//
//        // ADC A, B
//        case 0x88:
//          a = ADC8(a, b);
//
//        // ADC A, C
//        case 0x89:
//          a = ADC8(a, c);
//
//        // ADC A, D
//        case 0x8A:
//          a = ADC8(a, d);
//
//        // ADC A, E
//        case 0x8B:
//          a = ADC8(a, e);
//
//        // ADC A, H
//        case 0x8C:
//          a = ADC8(a, h);
//
//        // ADC A, L
//        case 0x8D:
//          a = ADC8(a, l);
//
//        // ADC A, (HL)
//        case 0x8E:
//          a = ADC8(a, memory.readByte(hl));
//          tStates += 3;
//
//        // ADC A, A
//        case 0x8F:
//          a = ADC8(a, a);
//
//        // SUB B
//        case 0x90:
//          a = SUB8(a, b);
//
//        // SUB C
//        case 0x91:
//          a = SUB8(a, c);
//
//        // SUB D
//        case 0x92:
//          a = SUB8(a, d);
//
//        // SUB E
//        case 0x93:
//          a = SUB8(a, e);
//
//        // SUB H
//        case 0x94:
//          a = SUB8(a, h);
//
//        // SUB L
//        case 0x95:
//          a = SUB8(a, l);
//
//        // SUB (HL)
//        case 0x96:
//          a = SUB8(a, memory.readByte(hl));
//          tStates += 3;
//
//        // SUB A
//        case 0x97:
//          a = SUB8(a, a);
//
//        // SBC A, B
//        case 0x98:
//          a = SBC8(a, b);
//
//        // SBC A, C
//        case 0x99:
//          a = SBC8(a, c);
//
//        // SBC A, D
//        case 0x9A:
//          a = SBC8(a, d);
//
//        // SBC A, E
//        case 0x9B:
//          a = SBC8(a, e);
//
//        // SBC A, H
//        case 0x9C:
//          a = SBC8(a, h);
//
//        // SBC A, L
//        case 0x9D:
//          a = SBC8(a, l);
//
//        // SBC A, (HL)
//        case 0x9E:
//          a = SBC8(a, memory.readByte(hl));
//          tStates += 3;
//
//        // SBC A, A
//        case 0x9F:
//          a = SBC8(a, a);
//
//        // AND B
//        case 0xA0:
//          a = AND(a, b);
//
//        // AND C
//        case 0xA1:
//          a = AND(a, c);
//
//        // AND D
//        case 0xA2:
//          a = AND(a, d);
//
//        // AND E
//        case 0xA3:
//          a = AND(a, e);
//
//        // AND H
//        case 0xA4:
//          a = AND(a, h);
//
//        // AND L
//        case 0xA5:
//          a = AND(a, l);
//
//        // AND (HL)
//        case 0xA6:
//          a = AND(a, memory.readByte(hl));
//          tStates += 3;
//
//        // AND A
//        case 0xA7:
//          a = AND(a, a);
//
//        // XOR B
//        case 0xA8:
//          a = XOR(a, b);
//
//        // XOR C
//        case 0xA9:
//          a = XOR(a, c);
//
//        // XOR D
//        case 0xAA:
//          a = XOR(a, d);
//
//        // XOR E
//        case 0xAB:
//          a = XOR(a, e);
//
//        // XOR H
//        case 0xAC:
//          a = XOR(a, h);
//
//        // XOR L
//        case 0xAD:
//          a = XOR(a, l);
//
//        // XOR (HL)
//        case 0xAE:
//          a = XOR(a, memory.readByte(hl));
//          tStates += 3;
//
//        // XOR A
//        case 0xAF:
//          a = XOR(a, a);
//
//        // OR B
//        case 0xB0:
//          a = OR(a, b);
//
//        // OR C
//        case 0xB1:
//          a = OR(a, c);
//
//        // OR D
//        case 0xB2:
//          a = OR(a, d);
//
//        // OR E
//        case 0xB3:
//          a = OR(a, e);
//
//        // OR H
//        case 0xB4:
//          a = OR(a, h);
//
//        // OR L
//        case 0xB5:
//          a = OR(a, l);
//
//        // OR (HL)
//        case 0xB6:
//          a = OR(a, memory.readByte(hl));
//          tStates += 3;
//
//        // OR A
//        case 0xB7:
//          a = OR(a, a);
//
//        // CP B
//        case 0xB8:
//          CP(b);
//
//        // CP C
//        case 0xB9:
//          CP(c);
//
//        // CP D
//        case 0xBA:
//          CP(d);
//
//        // CP E
//        case 0xBB:
//          CP(e);
//
//        // CP H
//        case 0xBC:
//          CP(h);
//
//        // CP L
//        case 0xBD:
//          CP(l);
//
//        // CP (HL)
//        case 0xBE:
//          CP(memory.readByte(hl));
//          tStates += 3;
//
//        // CP A
//        case 0xBF:
//          CP(a);
//
//        // RET NZ
//        case 0xC0:
//          if (!fZ) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // POP BC
//        case 0xC1:
//          bc = POP();
//          tStates += 10;
//
//        // JP NZ, **
//        case 0xC2:
//          if (!fZ) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // JP **
//        case 0xC3:
//          pc = getNextWord();
//          tStates += 10;
//
//        // CALL NZ, **
//        case 0xC4:
//          if (!fZ) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // PUSH BC
//        case 0xC5:
//          PUSH(bc);
//          tStates += 11;
//
//        // ADD A, *
//        case 0xC6:
//          a = ADD8(a, getNextByte());
//          tStates += 3;
//
//        // RST 00h
//        case 0xC7:
//          RST(0x00);
//
//        // RET Z
//        case 0xC8:
//          if (fZ) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // RET
//        case 0xC9:
//          pc = POP();
//          tStates += 10;
//
//        // JP Z, **
//        case 0xCA:
//          if (fZ) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // BITWISE INSTRUCTIONS
//        case 0xCB:
//          DecodeCBOpcode();
//
//        // CALL Z, **
//        case 0xCC:
//          if (fZ) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // CALL **
//        case 0xCD:
//          CALL();
//
//        // ADC A, *
//        case 0xCE:
//          a = ADC8(a, getNextByte());
//          tStates += 3;
//
//        // RST 08h
//        case 0xCF:
//          RST(0x08);
//
//        // RET NC
//        case 0xD0:
//          if (!fC) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // POP DE
//        case 0xD1:
//          de = POP();
//          tStates += 10;
//
//        // JP NC, **
//        case 0xD2:
//          if (!fC) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // OUT (*), A
//        case 0xD3:
//          OUTA(getNextByte(), a);
//          tStates += 11;
//
//        // CALL NC, **
//        case 0xD4:
//          if (!fC) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // PUSH DE
//        case 0xD5:
//          PUSH(de);
//          tStates += 11;
//
//        // SUB *
//        case 0xD6:
//          a = SUB8(a, getNextByte());
//          tStates += 3;
//
//        // RST 10h
//        case 0xD7:
//          RST(0x10);
//
//        // RET C
//        case 0xD8:
//          if (fC) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // EXX
//        case 0xD9:
//          final oldB = b, oldC = c, oldD = d, oldE = e, oldH = h, oldL = l;
//          b = b_;
//          c = c_;
//          d = d_;
//          e = e_;
//          h = h_;
//          l = l_;
//          b_ = oldB;
//          c_ = oldC;
//          d_ = oldD;
//          e_ = oldE;
//          h_ = oldH;
//          l_ = oldL;
//          tStates += 4;
//
//        // JP C, **
//        case 0xDA:
//          if (fC) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // IN A, (*)
//        case 0xDB:
//          INA(getNextByte());
//          tStates += 11;
//
//        // CALL C, **
//        case 0xDC:
//          if (fC) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // IX OPERATIONS
//        case 0xDD:
//          DecodeDDOpcode();
//
//        // SBC A, *
//        case 0xDE:
//          a = SBC8(a, getNextByte());
//          tStates += 3;
//
//        // RST 18h
//        case 0xDF:
//          RST(0x18);
//
//        // RET PO
//        case 0xE0:
//          if (!fPV) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // POP HL
//        case 0xE1:
//          hl = POP();
//          tStates += 10;
//
//        // JP PO, **
//        case 0xE2:
//          if (!fPV) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // EX (SP), HL
//        case 0xE3:
//          final temp = hl;
//          hl = memory.readWord(sp);
//          memory.writeWord(sp, temp);
//          tStates += 19;
//
//        // CALL PO, **
//        case 0xE4:
//          if (!fPV) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // PUSH HL
//        case 0xE5:
//          PUSH(hl);
//          tStates += 11;
//
//        // AND *
//        case 0xE6:
//          a = AND(a, getNextByte());
//          tStates += 3;
//
//        // RST 20h
//        case 0xE7:
//          RST(0x20);
//
//        // RET PE
//        case 0xE8:
//          if (fPV) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // JP (HL)
//        // note that the brackets in the instruction are an eccentricity, the result
//        // should be hl rather than the contents of addr(hl)
//        case 0xE9:
//          pc = hl;
//          tStates += 4;
//
//        // JP PE, **
//        case 0xEA:
//          if (fPV) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // EX DE, HL
//        case 0xEB:
//          final oldD = d, oldE = e;
//          d = h;
//          e = l;
//          h = oldD;
//          l = oldE;
//          tStates += 4;
//
//        // CALL PE, **
//        case 0xEC:
//          if (fPV) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // EXTD INSTRUCTIONS
//        case 0xED:
//          DecodeEDOpcode();
//
//        // XOR *
//        case 0xEE:
//          a = XOR(a, getNextByte());
//          tStates += 3;
//
//        // RST 28h
//        case 0xEF:
//          RST(0x28);
//
//        // RET P
//        case 0xF0:
//          if (!fS) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // POP AF
//        case 0xF1:
//          af = POP();
//          tStates += 10;
//
//        // JP P, **
//        case 0xF2:
//          if (!fS) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // DI
//        case 0xF3:
//          iff1 = false;
//          iff2 = false;
//          tStates += 4;
//
//        // CALL P, **
//        case 0xF4:
//          if (!fS) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // PUSH AF
//        case 0xF5:
//          PUSH(af);
//          tStates += 11;
//
//        // OR *
//        case 0xF6:
//          a = OR(a, getNextByte());
//          tStates += 3;
//
//        // RST 30h
//        case 0xF7:
//          RST(0x30);
//
//        // RET M
//        case 0xF8:
//          if (fS) {
//            pc = POP();
//            tStates += 11;
//          } else {
//            tStates += 5;
//          }
//
//        // LD SP, HL
//        case 0xF9:
//          sp = hl;
//          tStates += 6;
//
//        // JP M, **
//        case 0xFA:
//          if (fS) {
//            pc = getNextWord();
//          } else {
//            pc = (pc + 2) % 0x10000;
//          }
//          tStates += 10;
//
//        // EI
//        case 0xFB:
//          iff1 = true;
//          iff2 = true;
//          tStates += 4;
//
//        // CALL M, **
//        case 0xFC:
//          if (fS) {
//            CALL();
//          } else {
//            pc = (pc + 2) % 0x10000;
//            tStates += 10;
//          }
//
//        // IY INSTRUCTIONS
//        case 0xFD:
//          DecodeFDOpcode();
//
//        // CP *
//        case 0xFE:
//          CP(getNextByte());
//          tStates += 3;
//
//        // RST 38h
//        case 0xFF:
//          RST(0x38);
//      }
//
//      return true;
//    }
}
