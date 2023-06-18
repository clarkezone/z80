//
//  Z80.swift
//
//  Implements the Zilog Z80 processor core to the given specification.
//
//  Reference notes:
//
//  The Z80 microprocessor user manual can be downloaded from Zilog:
//     http://tinyurl.com/z80manual
//
//  An excellent additional reference is "The Undocumented Z80 Documented", at:
//     http://www.z80.info/zip/z80-documented.pdf
//
//  Created by Tim Sneath on 6/6/23.
//

public enum Z80Error: Error {
    case missingValue
}

public enum InterruptMode {
    case im0, im1, im2
}

public class Z80 {
    public var memory: Memory<UInt16>

    public typealias PortReadCallback = (UInt16) -> UInt8
    public typealias PortWriteCallback = (UInt16, UInt8) -> ()

    /// Callback for a port read (IN instruction).
    ///
    /// This should be used by an emulator to handle peripherals or ULA access,
    /// including keyboard or storage input.
    var onPortRead: PortReadCallback

    /// Callback for a port write (OUT instruction).
    ///
    /// This should be used by an emulator to handle peripherals or ULA access,
    /// such as a printer or storage output.
    var onPortWrite: PortWriteCallback

    // Core registers
    public var a: UInt8 = 0xFF, f: UInt8 = 0xFF
    public var b: UInt8 = 0xFF, c: UInt8 = 0xFF
    public var d: UInt8 = 0xFF, e: UInt8 = 0xFF
    public var h: UInt8 = 0xFF, l: UInt8 = 0xFF
    public var ix: UInt16 = 0xFFFF, iy: UInt16 = 0xFFFF

    // The alternate register set (A', F', B', C', D', E', H', L')
    public var a_: UInt8 = 0xFF, f_: UInt8 = 0xFF
    public var b_: UInt8 = 0xFF, c_: UInt8 = 0xFF
    public var d_: UInt8 = 0xFF, e_: UInt8 = 0xFF
    public var h_: UInt8 = 0xFF, l_: UInt8 = 0xFF

    /// Interrupt Page Address register (I).
    public var i: UInt8 = 0xFF

    /// Memory Refresh register (R).
    public var r: UInt8 = 0xFF

    /// Program Counter (PC).
    public var pc: UInt16 = 0

    /// Stack Pointer (SP).
    public var sp: UInt16 = 0xFFFF

    /// Interrupt Flip-Flop (IFF1).
    public var iff1 = false

    /// Interrupt Flip-Flop (IFF2).
    ///
    /// This is used to cache the value of the Interrupt Flag when a Non-Maskable
    /// Interrupt occurs.
    public var iff2 = false

    /// Interrupt Mode (IM).
    public var im: InterruptMode = .im0

    /// Number of  cycles that have occurred since the last clock reset.
    public var tStates = 0

    /// Whether the processor is halted or not
    public var halt = false

    public init(memory: Memory<UInt16>,
                portRead: @escaping PortReadCallback,
                portWrite: @escaping PortWriteCallback)
    {
        self.memory = memory
        self.onPortRead = portRead
        self.onPortWrite = portWrite
    }

    convenience public init(memory: Memory<UInt16>) {
        self.init(memory: memory,
                  portRead: { port in port.highByte },
                  portWrite: { _, _ in })
    }

    convenience public init() {
        self.init(memory: Memory(sizeInBytes: 65536))
    }

    public var af: UInt16 {
        get { UInt16.formWord(a, f) }
        set { a = newValue.highByte; f = newValue.lowByte }
    }

    public var af_: UInt16 {
        get { UInt16.formWord(a_, f_) }
        set { a_ = newValue.highByte; f_ = newValue.lowByte }
    }

    public var bc: UInt16 {
        get { UInt16.formWord(b, c) }
        set { b = newValue.highByte; c = newValue.lowByte }
    }

    public var bc_: UInt16 {
        get { UInt16.formWord(b_, c_) }
        set { b_ = newValue.highByte; c_ = newValue.lowByte }
    }

    public var de: UInt16 {
        get { UInt16.formWord(d, e) }
        set { d = newValue.highByte; e = newValue.lowByte }
    }

    public var de_: UInt16 {
        get { UInt16.formWord(d_, e_) }
        set { d_ = newValue.highByte; e_ = newValue.lowByte }
    }

    public var hl: UInt16 {
        get { UInt16.formWord(h, l) }
        set { h = newValue.highByte; l = newValue.lowByte }
    }

    public var hl_: UInt16 {
        get { UInt16.formWord(h_, l_) }
        set { h_ = newValue.highByte; l_ = newValue.lowByte }
    }

    public var ixh: UInt8 {
        get { ix.highByte }
        set { ix = UInt16.formWord(newValue, ixl) }
    }

    public var ixl: UInt8 {
        get { ix.lowByte }
        set { ix = UInt16.formWord(ixh, newValue) }
    }

    public var iyh: UInt8 {
        get { iy.highByte }
        set { iy = UInt16.formWord(newValue, iyl) }
    }

    public var iyl: UInt8 {
        get { iy.lowByte }
        set { iy = UInt16.formWord(iyh, newValue) }
    }

    public struct Flags: OptionSet {
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public var rawValue: UInt8

        static let c = Flags(rawValue: 1 << 0) // carry
        static let n = Flags(rawValue: 1 << 1) // add/subtract
        static let pv = Flags(rawValue: 1 << 2) // parity overflow
        static let f3 = Flags(rawValue: 1 << 3)
        static let h = Flags(rawValue: 1 << 4) // half carry
        static let f5 = Flags(rawValue: 1 << 5)
        static let z = Flags(rawValue: 1 << 6) // zero
        static let s = Flags(rawValue: 1 << 7) // sign

        mutating func set(_ flags: Flags, basedOn condition: Bool) {
            if condition {
                self = Flags(rawValue: rawValue | flags.rawValue)
            } else {
                self = Flags(rawValue: rawValue & ~(flags.rawValue))
            }
        }

        mutating func setZeroFlag(basedOn value: any BinaryInteger) {
            set(.z, basedOn: Int(value) == 0)
        }
    }

    public var flags: Flags { get { Flags(rawValue: f) } set { f = newValue.rawValue }}

    /// Reset the Z80 to an initial power-on configuration.
    ///
    /// Initial register states are set per section 2.4 of http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
     func reset() {
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

    /// Generate a non-maskable interrupt.
    ///
    /// Per "The Undocumented Z80 Documented", shen a NMI is accepted, IFF1 is
    /// reset. At the end of the routine, IFF1 must be restored (so the running
    /// program is not affected). That’s why IFF2 is there; to keep a copy of
    /// IFF1.
    func nonMaskableInterrupt() {
        iff1 = false
        r &+= 1
        pc = 0x0066
    }

    /// Generate an interrupt.
    func maskableInterrupt() {
        if iff1 {
            r &+= 1
            iff1 = false
            iff2 = false
            print("maskable interrupt: \(iff1) \(iff2) \(im)")
            switch im {
                case .im0:
                    // Not used on the ZX Spectrum
                    tStates += 13
                case .im1:
                    PUSH(pc)
                    pc = 0x0038
                    tStates += 13
                case .im2:
                    PUSH(pc)
                    let address = UInt16.formWord(0, i)
                    pc = memory.readWord(address)
                    tStates += 19
            }
        }
    }

    /// Read-ahead the byte at offset `offset` from the current `pc` register.
    ///
    /// This is useful for debugging, where we want to be able to see what's coming without affecting the program counter.
    func previewByte(pcOffset offset: UInt16) -> UInt8 { memory.readByte(pc + offset) }

    /// Read-ahead the word at offset `offset` from the current `pc` register
    ///
    /// This is useful for debugging, where we want to be able to see what's coming without affecting the program counter.
    func previewWord(pcOffset offset: UInt16) -> UInt16 { memory.readWord(pc + offset) }

    func getNextByte() -> UInt8 {
        let byteRead = memory.readByte(pc)
        pc &+= 1
        return byteRead
    }

    func getNextWord() -> UInt16 {
        let wordRead = memory.readWord(pc)
        pc &+= 2
        return wordRead
    }

    // Opcodes that can be prefixed with DD or FD, but are the same as the
    // unprefixed versions (albeit slower).
    let extendedCodes: [UInt8] = [
        0x04, 0x05, 0x06, 0x0C, 0x0D, 0x0E,
        0x14, 0x15, 0x16, 0x1C, 0x1D, 0x1E,
        0x3C, 0x3D, 0x3E, // inc/dec
        0x40, 0x41, 0x42, 0x43, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4F,
        0x50, 0x51, 0x52, 0x53, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5F, // ld
        0x78, 0x79, 0x7A, 0x7B, 0x7F,
        0x80, 0x81, 0x82, 0x83, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8F,
        0x90, 0x91, 0x92, 0x93, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9F,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAF,
        0xB0, 0xB1, 0xB2, 0xB3, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBF // add/sub/and/or
    ]

    // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
    // INSTRUCTIONS
    // *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***

    /// Load and Increment
    func LDI() {
        let byteRead = memory.readByte(hl)
        memory.writeByte(de, byteRead)

        flags.set(.pv, basedOn: (bc - 1) != 0)

        de &+= 1
        hl &+= 1
        bc &-= 1

        flags.remove([.h, .n])

        flags.set(.f5, basedOn: (byteRead &+ a).isBitSet(1))
        flags.set(.f3, basedOn: (byteRead &+ a).isBitSet(3))

        tStates += 16
    }

    /// Load and Decrement
    func LDD() {
        let byteRead = memory.readByte(hl)
        memory.writeByte(de, byteRead)

        de &-= 1
        hl &-= 1
        bc &-= 1
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: bc != 0)
        flags.set(.f5, basedOn: (byteRead &+ a).isBitSet(1))
        flags.set(.f3, basedOn: (byteRead &+ a).isBitSet(3))

        tStates += 16
    }

    /// Load, Increment and Repeat
    func LDIR() {
        let byteRead = memory.readByte(hl)
        memory.writeByte(de, byteRead)

        de &+= 1
        hl &+= 1
        bc &-= 1

        if bc != 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
        flags.set(.f5, basedOn: (byteRead &+ a).isBitSet(1))
        flags.set(.f3, basedOn: (byteRead &+ a).isBitSet(3))
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: bc != 0)
    }

    /// Load, Decrement and Repeat
    func LDDR() {
        let byteRead = memory.readByte(hl)
        memory.writeByte(de, byteRead)

        de &-= 1
        hl &-= 1
        bc &-= 1

        if bc > 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
        flags.set(.f5, basedOn: (byteRead &+ a).isBitSet(1))
        flags.set(.f3, basedOn: (byteRead &+ a).isBitSet(3))
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: bc != 0)
    }

    // Arithmetic operations

    /// Increment
    func INC(_ value: UInt8) -> UInt8 {
        flags.set(.pv, basedOn: value == 0x7F)
        let result = value &+ 1
        flags.set(.h, basedOn: result.isBitSet(4) != value.isBitSet(4))
        flags.setZeroFlag(basedOn: result)
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.remove(.n)

        tStates += 4

        return result
    }

    /// Decrement
    func DEC(_ value: UInt8) -> UInt8 {
        flags.set(.pv, basedOn: value == 0x80)
        let result = value &- 1
        flags.set(.h, basedOn: result.isBitSet(4) != value.isBitSet(4))
        flags.setZeroFlag(basedOn: result)
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.insert(.n)

        tStates += 4

        return result
    }

    /// Add with Carry (8-bit)
    func ADC(_ value: UInt8) {
        ADD(value, withCarry: flags.contains(.c))
    }

    /// Add with Carry (16-bit)
    func ADC(_ value: UInt16) {
        // overflow in add only occurs when operand polarities are the same
        let overflowCheck = hl.isSignedBitSet() == value.isSignedBitSet()

        let result = ADD(hl, value, withCarry: flags.contains(.c))

        // if polarity is now different then add caused an overflow
        if overflowCheck {
            flags.set(.pv, basedOn: result.isSignedBitSet() != value.isSignedBitSet())
        } else {
            flags.remove(.pv)
        }
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        hl = result
    }

    /// Add (8-bit)
    func ADD(_ value: UInt8, withCarry: Bool = false) {
        let carry = UInt8(withCarry ? 1 : 0)
        let lowNibbleSum = a.lowNibble + value.lowNibble + carry
        let halfCarry = (lowNibbleSum & 0x10) == 0x10
        flags.set(.h, basedOn: halfCarry)

        // overflow in add only occurs when operand polarities are the same
        let overflowCheck = a.isSignedBitSet() == value.isSignedBitSet()

        flags.set(.c, basedOn: Int(a) + Int(value) + Int(carry) > 0xFF)
        let result: UInt8 = (a &+ value &+ carry)
        flags.set(.s, basedOn: result.isSignedBitSet())

        // if polarity is now different then add caused an overflow
        if overflowCheck {
            flags.set(.pv, basedOn: flags.contains(.s) != value.isSignedBitSet())
        } else {
            flags.remove(.pv)
        }

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.setZeroFlag(basedOn: result)
        flags.remove(.n)

        tStates += 4

        a = result
    }

    /// Add (16-bit)
    func ADD(_ xx: UInt16, _ yy: UInt16, withCarry: Bool = false) -> UInt16 {
        let carry = withCarry ? 1 : 0

        flags.set(.h, basedOn: Int(xx & 0x0FFF) + Int(yy & 0x0FFF) + carry > 0x0FFF)
        flags.set(.c, basedOn: Int(xx) + Int(yy) + carry > 0xFFFF)
        let result: UInt16 = xx &+ yy &+ UInt16(carry)
        flags.set(.f5, basedOn: result.isBitSet(13))
        flags.set(.f3, basedOn: result.isBitSet(11))
        flags.remove(.n)

        tStates += 11

        return result
    }

    /// Subtract with Carry (8-bit)
    func SBC8(_ x: UInt8, _ y: UInt8) -> UInt8 {
        return SUB8(x, y, withCarry: flags.contains(.c))
    }

    /// Subtract with Carry (16-bit)
    func SBC16(_ xx: UInt16, _ yy: UInt16) -> UInt16 {
        let carry = flags.contains(.c) ? 1 : 0

        flags.set(.c, basedOn: Int(xx) < (Int(yy) + carry))
        flags.set(.h, basedOn: (xx & 0xFFF) < ((yy & 0xFFF) + UInt16(carry)))
        flags.set(.s, basedOn: xx.isSignedBitSet())

        // overflow in subtract only occurs when operand signs are different
        let overflowCheck = xx.isSignedBitSet() != yy.isSignedBitSet()

        let result: UInt16 = xx &- yy &- UInt16(carry)
        flags.set(.f5, basedOn: result.isBitSet(13))
        flags.set(.f3, basedOn: result.isBitSet(11))
        flags.setZeroFlag(basedOn: result)
        flags.insert(.n)

        // if x changed polarity then subtract caused an overflow
        if overflowCheck {
            flags.set(.pv, basedOn: flags.contains(.s) != result.isSignedBitSet())
        } else {
            flags.remove(.pv)
        }
        flags.set(.s, basedOn: result.isSignedBitSet())

        tStates += 15

        return result
    }

    /// Subtract (8-bit)
    func SUB8(_ x: UInt8, _ y: UInt8, withCarry: Bool = false) -> UInt8 {
        let carry = withCarry ? 1 : 0

        flags.set(.c, basedOn: Int(x) < (Int(y) + carry))
        flags.set(.h, basedOn: (x & 0x0F) < ((y & 0x0F) + UInt8(carry)))
        flags.set(.s, basedOn: x.isSignedBitSet())

        // overflow in subtract only occurs when operand signs are different
        let overflowCheck = x.isSignedBitSet() != y.isSignedBitSet()

        let result: UInt8 = x &- y &- UInt8(carry)
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))

        // if x changed polarity then subtract caused an overflow
        if overflowCheck {
            flags.set(.pv, basedOn: flags.contains(.s) != result.isSignedBitSet())
        } else {
            flags.remove(.pv)
        }

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.insert(.n)
        tStates += 4

        return result
    }

    /// Compare
    func CP(_ x: UInt8) {
        _ = SUB8(a, x)

        flags.set(.f5, basedOn: x.isBitSet(5))
        flags.set(.f3, basedOn: x.isBitSet(3))
    }

    /// Decimal Adjust Accumulator
    func DAA() {
        // algorithm from http://worldofspectrum.org/faq/reference/z80reference.htm
        var correctionFactor: UInt8 = 0
        let originalA = a

        if (a > 0x99) || flags.contains(.c) {
            correctionFactor |= 0x60
            flags.insert(.c)
        } else {
            flags.remove(.c)
        }

        if ((a & 0x0F) > 0x09) || flags.contains(.h) {
            correctionFactor |= 0x06
        }

        if !flags.contains(.n) {
            a &+= correctionFactor
        } else {
            a &-= correctionFactor
        }

        flags.set(.h, basedOn: ((originalA & 0x10) ^ (a & 0x10)) == 0x10)
        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.set(.s, basedOn: a.isSignedBitSet())
        flags.setZeroFlag(basedOn: a)
        flags.set(.pv, basedOn: a.isParity())

        tStates += 4
    }

    // Flow operations
    /// Call
    func CALL() {
        let callAddr = getNextWord()

        PUSH(pc)

        pc = callAddr

        tStates += 17
    }

    /// Jump Relative
    func JR(_ jump: UInt8) {
        // jump is treated as signed byte from -128 to 127
        let vector = jump.twosComplement
        pc = UInt16(truncatingIfNeeded: Int(pc) + Int(vector))

        tStates += 12
    }

    /// Decrement and Jump if Not Zero
    func DJNZ(_ jump: UInt8) {
        b &-= 1
        if b != 0 {
            JR(jump)
            tStates += 1 // JR is 12 tStates
        } else {
            tStates += 8
        }
    }

    /// Restart
    func RST(_ addr: UInt8) {
        PUSH(pc)
        pc = UInt16(addr)
        tStates += 11
    }

    /// Return from Non-Maskable Interrupt
    func RETN() {
        // When an NMI is accepted, IFF1 is reset to prevent any other interrupts
        // occurring during the same period. This return ensures that the value is
        // restored from IFF2.
        pc = POP()
        iff1 = iff2
    }

    // Stack operations
    func PUSH(_ val: UInt16) {
        sp &-= 1
        memory.writeByte(sp, val.highByte)
        sp &-= 1
        memory.writeByte(sp, val.lowByte)
    }

    func POP() -> UInt16 {
        let lowByte = memory.readByte(sp)
        sp &+= 1
        let highByte = memory.readByte(sp)
        sp &+= 1
        return UInt16.formWord(highByte, lowByte)
    }

    func EX_AFAFPrime() {
        swap(&a, &a_)
        swap(&f, &f_)

        tStates += 4
    }

    // Logic operations

    /// Compare and Decrement
    func CPD() {
        let byteAtHL = memory.readByte(hl)
        flags.set(.h, basedOn: (a & 0x0F) < (byteAtHL & 0x0F))
        flags.set(.s, basedOn: (a &- byteAtHL).isSignedBitSet())
        flags.set(.z, basedOn: a == byteAtHL)
        flags.set(.f5, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(1))
        flags.set(.f3, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(3))
        flags.insert(.n)
        flags.set(.pv, basedOn: bc &- 1 != 0)
        hl &-= 1
        bc &-= 1

        tStates += 16
    }

    /// Compare and Decrement Repeated
    func CPDR() {
        let byteAtHL = memory.readByte(hl)
        flags.set(.h, basedOn: (a & 0x0F) < (byteAtHL & 0x0F))
        flags.set(.s, basedOn: (a &- byteAtHL).isSignedBitSet())
        flags.set(.z, basedOn: a == byteAtHL)
        flags.set(.f5, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(1))
        flags.set(.f3, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(3))
        flags.insert(.n)
        flags.set(.pv, basedOn: bc &- 1 != 0)

        hl &-= 1
        bc &-= 1

        if bc != 0, a != byteAtHL {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    func CPI() {
        let byteAtHL = memory.readByte(hl)
        flags.set(.h, basedOn: (a & 0x0F) < (byteAtHL & 0x0F))
        flags.set(.s, basedOn: (a &- byteAtHL).isSignedBitSet())
        flags.set(.z, basedOn: a == byteAtHL)
        flags.set(.f5, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(1))
        flags.set(.f3, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(3))
        flags.insert(.n)
        flags.set(.pv, basedOn: bc &- 1 != 0)

        hl &+= 1
        bc &-= 1

        tStates += 16
    }

    func CPIR() {
        let byteAtHL = memory.readByte(hl)
        flags.set(.h, basedOn: (a & 0x0F) < (byteAtHL & 0x0F))
        flags.set(.s, basedOn: (a &- byteAtHL).isSignedBitSet())
        flags.set(.z, basedOn: a == byteAtHL)
        flags.set(.f5, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(1))
        flags.set(.f3, basedOn: ((a &- byteAtHL &- (flags.contains(.h) ? 1 : 0)) & 0xFF).isBitSet(3))
        flags.insert(.n)
        flags.set(.pv, basedOn: bc &- 1 != 0)

        hl &+= 1
        bc &-= 1

        if bc != 0, a != byteAtHL {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    func OR(_ registerValue: UInt8) -> UInt8 {
        let result: UInt8 = a | registerValue
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.pv, basedOn: result.isParity())
        flags.remove([.h, .n, .c])

        tStates += 4

        return result
    }

    func XOR(_ registerValue: UInt8) -> UInt8 {
        let result: UInt8 = a ^ registerValue
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.pv, basedOn: result.isParity())
        flags.remove([.n, .h, .c])

        tStates += 4

        return result
    }

    // TODO: Mutate a register directly for AND/OR/XOR/NEG
    func AND(_ registerValue: UInt8) -> UInt8 {
        let result: UInt8 = a & registerValue
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.insert(.h)
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.pv, basedOn: result.isParity())
        flags.remove([.n, .c])

        tStates += 4

        return result
    }

    func NEG() {
        // returns two's complement of a
        flags.set(.pv, basedOn: a == 0x80)
        flags.set(.c, basedOn: a != 0x00)

        a = ~a
        a &+= 1

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))
        flags.set(.s, basedOn: a.isSignedBitSet())
        flags.setZeroFlag(basedOn: a)
        flags.set(.h, basedOn: a & 0x0F != 0)
        flags.insert(.n)

        tStates += 8
    }

    /// Complement
    func CPL() {
        a = ~a
        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))
        flags.insert([.h, .n])

        tStates += 4
    }

    /// Set Carry Flag
    func SCF() {
        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))
        flags.remove([.h, .n])
        flags.insert(.c)
    }

    /// Clear Carry Flag
    func CCF() {
        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.set(.h, basedOn: flags.contains(.c))
        flags.remove(.n)
        flags.set(.c, basedOn: !flags.contains(.c))

        tStates += 4
    }

    /// Rotate Left Circular
    func RLC(_ value: UInt8) -> UInt8 {
        // rotates register r to the left
        // bit 7 is copied to carry and to bit 0
        flags.set(.c, basedOn: value.isSignedBitSet())
        var result: UInt8 = value &<< 1
        if flags.contains(.c) { result.setBit(0) }

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Rotate Left Circular Accumulator
    func RLCA() {
        // rotates register A to the left
        // bit 7 is copied to carry and to bit 0
        flags.set(.c, basedOn: a.isSignedBitSet())
        a &<<= 1
        if flags.contains(.c) { a.setBit(0) }
        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))
        flags.remove([.h, .n])

        tStates += 4
    }

    /// Rotate Right Circular
    func RRC(_ value: UInt8) -> UInt8 {
        flags.set(.c, basedOn: value.isBitSet(0))
        var result: UInt8 = value &>> 1
        if flags.contains(.c) { result.setBit(7) }

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Rotate Right Circular Accumulator
    func RRCA() {
        flags.set(.c, basedOn: a.isBitSet(0))
        a &>>= 1
        if flags.contains(.c) { a.setBit(7) }

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.remove([.h, .n])

        tStates += 4
    }

    /// Rotate Left
    func RL(_ value: UInt8) -> UInt8 {
        // rotates register r to the left, through carry.
        // carry becomes the LSB of the new r

        let carryBitInitiallySet = flags.contains(.c)
        flags.set(.c, basedOn: value.isSignedBitSet())
        var result: UInt8 = value &<< 1

        if carryBitInitiallySet { result.setBit(0) }

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Rotate Left Accumulator
    func RLA() {
        // rotates register r to the left, through carry.
        // carry becomes the LSB of the new r

        let carryBitInitiallySet = flags.contains(.c)
        flags.set(.c, basedOn: a.isSignedBitSet())
        a &<<= 1

        if carryBitInitiallySet { a.setBit(0) }

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.remove([.h, .n])

        tStates += 4
    }

    /// Rotate Right
    func RR(_ value: UInt8) -> UInt8 {
        let carryBitInitiallySet = flags.contains(.c)

        flags.set(.c, basedOn: value.isBitSet(0))
        var result: UInt8 = value &>> 1

        if carryBitInitiallySet { result.setBit(7) }

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Rotate Right Accumulator
    func RRA() {
        let carryBitInitiallySet = flags.contains(.c)
        flags.set(.c, basedOn: a.isBitSet(0))
        a &>>= 1

        if carryBitInitiallySet {
            a.setBit(7)
        }

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.remove([.h, .n])

        tStates += 4
    }

    /// Shift Left Arithmetic
    func SLA(_ value: UInt8) -> UInt8 {
        flags.set(.c, basedOn: value.isBitSet(7))
        let result: UInt8 = value &<< 1

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Shift Right Arithmetic
    func SRA(_ value: UInt8) -> UInt8 {
        flags.set(.c, basedOn: value.isBitSet(0))
        var result: UInt8 = value &>> 1

        if value.isSignedBitSet() { result.setBit(7) }

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Shift Left Logical
    func SLL(_ value: UInt8) -> UInt8 {
        flags.set(.c, basedOn: value.isBitSet(7))
        var result: UInt8 = value &<< 1
        result.setBit(0)

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Shift Right Logical
    func SRL(_ value: UInt8) -> UInt8 {
        flags.set(.c, basedOn: value.isBitSet(0))
        var result: UInt8 = value &>> 1
        result.resetBit(7)

        flags.set(.f5, basedOn: result.isBitSet(5))
        flags.set(.f3, basedOn: result.isBitSet(3))

        flags.set(.s, basedOn: result.isSignedBitSet())
        flags.setZeroFlag(basedOn: result)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: result.isParity())

        return result
    }

    /// Rotate Left BCD Digit
    func RLD() {
        // TODO: Overflow condition for this and RRD
        let byteAtHL = memory.readByte(hl)

        var result: UInt8 = (byteAtHL & 0x0F) &<< 4
        result += a & 0x0F

        a &= 0xF0
        a += (byteAtHL & 0xF0) &>> 4

        memory.writeByte(hl, result)

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.set(.s, basedOn: a.isSignedBitSet())
        flags.setZeroFlag(basedOn: a)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: a.isParity())

        tStates += 18
    }

    /// Rotate Right BCD Digit
    func RRD() {
        let byteAtHL = memory.readByte(hl)

        var result: UInt8 = (a & 0x0F) &<< 4
        result += (byteAtHL & 0xF0) &>> 4

        a &= 0xF0
        a += byteAtHL & 0x0F

        memory.writeByte(hl, result)

        flags.set(.f5, basedOn: a.isBitSet(5))
        flags.set(.f3, basedOn: a.isBitSet(3))

        flags.set(.s, basedOn: a.isSignedBitSet())
        flags.setZeroFlag(basedOn: a)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: a.isParity())

        tStates += 18
    }

    func displacedIX() -> UInt16 {
        UInt16(truncatingIfNeeded: Int(ix) + Int(getNextByte().twosComplement))
    }

    func displacedIY() -> UInt16 {
        UInt16(truncatingIfNeeded: Int(iy) + Int(getNextByte().twosComplement))
    }

    // Bitwise operations
    func BIT(bitToTest: Int, register: Int) {
        switch register {
            case 0x0:
                flags.set(.z, basedOn: !(b.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: b.isBitSet(3))
                flags.set(.f5, basedOn: b.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x1:
                flags.set(.z, basedOn: !(c.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: c.isBitSet(3))
                flags.set(.f5, basedOn: c.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x2:
                flags.set(.z, basedOn: !(d.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: d.isBitSet(3))
                flags.set(.f5, basedOn: d.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x3:
                flags.set(.z, basedOn: !(e.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: e.isBitSet(3))
                flags.set(.f5, basedOn: e.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x4:
                flags.set(.z, basedOn: !(h.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: h.isBitSet(3))
                flags.set(.f5, basedOn: h.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x5:
                flags.set(.z, basedOn: !(l.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: l.isBitSet(3))
                flags.set(.f5, basedOn: l.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x6:
                let value = memory.readByte(hl)
                flags.set(.z, basedOn: !(value.isBitSet(bitToTest)))
                // NOTE: undocumented bits 3 and 5 for this instruction come from an
                // internal register 'W' that is highly undocumented. This really
                // doesn't matter too much, I don't think. See the following for more:
                //   http://www.omnimaga.org/asm-language/bit-n-(hl)-flags/
                flags.set(.f3, basedOn: value.isBitSet(3))
                flags.set(.f5, basedOn: value.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            case 0x7:
                flags.set(.z, basedOn: !(a.isBitSet(bitToTest)))
                flags.set(.f3, basedOn: a.isBitSet(3))
                flags.set(.f5, basedOn: a.isBitSet(5))
                flags.set(.pv, basedOn: flags.contains(.z))
            default:
                return
        }

        // undocumented behavior from
        //   http://worldofspectrum.org/faq/reference/z80reference.htm
        flags.set(.s, basedOn: bitToTest == 7 && !flags.contains(.z))
        flags.insert(.h)
        flags.remove(.n)
    }

    func RES(bitToReset: Int, register: Int) {
        switch register {
            case 0x0:
                b.resetBit(bitToReset)
            case 0x1:
                c.resetBit(bitToReset)
            case 0x2:
                d.resetBit(bitToReset)
            case 0x3:
                e.resetBit(bitToReset)
            case 0x4:
                h.resetBit(bitToReset)
            case 0x5:
                l.resetBit(bitToReset)
            case 0x6:
                var byteAtHL = memory.readByte(hl)
                byteAtHL.resetBit(bitToReset)
                memory.writeByte(hl, byteAtHL)
            case 0x7:
                a.resetBit(bitToReset)
            default:
                return
        }
    }

    func SET(bitToSet: Int, register: Int) {
        switch register {
            case 0x0:
                b.setBit(bitToSet)
            case 0x1:
                c.setBit(bitToSet)
            case 0x2:
                d.setBit(bitToSet)
            case 0x3:
                e.setBit(bitToSet)
            case 0x4:
                h.setBit(bitToSet)
            case 0x5:
                l.setBit(bitToSet)
            case 0x6:
                var byteAtHL = memory.readByte(hl)
                byteAtHL.setBit(bitToSet)
                memory.writeByte(hl, byteAtHL)
            case 0x7:
                a.setBit(bitToSet)
            default:
                return
        }
    }

    func callRotation(operation: Int, register: UInt8) -> UInt8 {
        switch operation {
            case 0x00:
                return RLC(register)
            case 0x01:
                return RRC(register)
            case 0x02:
                return RL(register)
            case 0x03:
                return RR(register)
            case 0x04:
                return SLA(register)
            case 0x05:
                return SRA(register)
            case 0x06:
                return SLL(register)
            default: // case 0x07:
                return SRL(register)
        }
    }

    func rotate(operation: Int, register: Int) {
        switch register {
            case 0x00:
                let register = b
                b = callRotation(operation: operation, register: register)
            case 0x01:
                let register = c
                c = callRotation(operation: operation, register: register)
            case 0x02:
                let register = d
                d = callRotation(operation: operation, register: register)
            case 0x03:
                let register = e
                e = callRotation(operation: operation, register: register)
            case 0x04:
                let register = h
                h = callRotation(operation: operation, register: register)
            case 0x05:
                let register = l
                l = callRotation(operation: operation, register: register)
            case 0x06:
                let byteAtHL = memory.readByte(hl)
                let result = callRotation(operation: operation, register: byteAtHL)
                memory.writeByte(hl, result)
            default: // case 0x07
                let register = a
                a = callRotation(operation: operation, register: register)
        }
    }

    // Port operations and interrupts

    func inSetFlags(_ register: UInt8) {
        flags.set(.s, basedOn: register.isSignedBitSet())
        flags.setZeroFlag(basedOn: register)
        flags.remove([.h, .n])
        flags.set(.pv, basedOn: register.isParity())
        flags.set(.f5, basedOn: register.isBitSet(5))
        flags.set(.f3, basedOn: register.isBitSet(3))
    }

    func OUT(portNumber: UInt16, value: UInt8) {
        onPortWrite(portNumber, value)
    }

    func OUTA(portNumber: UInt16, value: UInt8) {
        onPortWrite(portNumber, value)
    }

    func INA(_ operandByte: UInt8) -> UInt8 {
        // The operand is placed on the bottom half (A0 through A7) of the address
        // bus to select the I/O device at one of 256 possible ports. The contents
        // of the Accumulator also appear on the top half (A8 through A15) of the
        // address bus at this time.
        let addressBus = UInt16.formWord(a, operandByte)
        let result = onPortRead(addressBus)
        return result
    }

    /// Input and Increment
    func INI() {
        let memval = onPortRead(bc)
        memory.writeByte(hl, memval)
        hl &+= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.set(.z, basedOn: b == 0)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.c, basedOn: Int(memval) + Int(c &+ 1) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ (c &+ 1)) & 0x07) ^ b).isParity())

        tStates += 16
    }

    /// Output and Increment
    func OUTI() {
        let memval = memory.readByte(hl)
        onPortWrite(bc, memval)
        hl &+= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(l) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ l) & 0x07) ^ b).isParity())

        tStates += 16
    }

    /// Input and Decrement
    func IND() {
        let memval = onPortRead(bc)
        memory.writeByte(hl, memval)
        hl &-= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(c) - 1 > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ (c &- 1) & 0xFF) & 0x07) ^ b).isParity())
        tStates += 16
    }

    /// Output and Decrement
    func OUTD() {
        let memval = memory.readByte(hl)
        onPortWrite(bc, memval)
        hl &-= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(l) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ l) & 0x07) ^ b).isParity())

        tStates += 16
    }

    /// Input, Increment and Repeat
    func INIR() {
        let memval = onPortRead(bc)
        memory.writeByte(hl, memval)
        hl &+= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(c &+ 1) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ ((c &+ 1) & 0xFF)) & 0x07) ^ b).isParity())

        if b != 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    /// Output, Increment and Repeat
    func OTIR() {
        let memval = memory.readByte(hl)
        onPortWrite(bc, memval)

        hl &+= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(l) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))

        flags.set(.pv, basedOn: (((memval &+ l) & 0x07) ^ b).isParity())

        if b != 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    /// Input, Decrement and Repeat
    func INDR() {
        let memval = onPortRead(bc)
        memory.writeByte(hl, memval)
        hl &-= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(l) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ ((c &- 1) & 0xFF)) & 0x07) ^ b).isParity())

        if b != 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    /// Output, Decrement and Repeat
    func OTDR() {
        let memval = memory.readByte(hl)
        onPortWrite(bc, memval)

        hl &-= 1
        b &-= 1

        flags.set(.n, basedOn: memval.isBitSet(7))
        flags.setZeroFlag(basedOn: b)
        flags.set(.s, basedOn: b.isSignedBitSet())
        flags.set(.f3, basedOn: b.isBitSet(3))
        flags.set(.f5, basedOn: b.isBitSet(5))
        flags.set(.c, basedOn: Int(memval) + Int(l) > 0xFF)
        flags.set(.h, basedOn: flags.contains(.c))
        flags.set(.pv, basedOn: (((memval &+ l) & 0x07) ^ b).isParity())

        if b != 0 {
            pc &-= 2
            tStates += 21
        } else {
            tStates += 16
        }
    }

    // MARK: Opcode Decoding

    func DecodeCBOpcode() {
        let opCode = getNextByte()
        r &+= 1

        // first two bits of opCode determine function:
        switch opCode >> 6 {
            // 00 = rot [y], r[z]
            case 0:
                rotate(operation: Int((opCode & 0x38) >> 3), register: Int(opCode & 0x07))

            // 01 = BIT y, r[z]
            case 1:
                BIT(bitToTest: Int((opCode & 0x38) >> 3), register: Int(opCode & 0x07))

            // 02 = RES y, r[z]
            case 2:
                RES(bitToReset: Int((opCode & 0x38) >> 3), register: Int(opCode & 0x07))

            // 03 = SET y, r[z]
            case 3:
                SET(bitToSet: Int((opCode & 0x38) >> 3), register: Int(opCode & 0x07))
            default:
                return
        }

        // Set T-States
        if (opCode & 0x7) == 0x6 {
            if opCode > 0x40, opCode < 0x7F {
                // BIT n, (HL)
                tStates += 12
            } else {
                // all the other instructions involving (HL)
                tStates += 15
            }
        } else {
            // straight register bitwise operation
            tStates += 8
        }
    }

    func DecodeDDOpcode() {
        let opCode = getNextByte()
        r &+= 1

        var addr: UInt16 = 0

        switch opCode {
            // NOP
            case 0x00:
                tStates += 8

            // ADD IX, BC
            case 0x09:
                ix = ADD(ix, bc)
                tStates += 4

            // ADD IX, DE
            case 0x19:
                ix = ADD(ix, de)
                tStates += 4

            // LD IX, **
            case 0x21:
                ix = getNextWord()
                tStates += 14

            // LD (**), IX
            case 0x22:
                memory.writeWord(getNextWord(), ix)
                tStates += 20

            // INC IX
            case 0x23:
                ix &+= 1
                tStates += 10

            // INC IXH
            case 0x24:
                ixh = INC(ixh)
                tStates += 4

            // DEC IXH
            case 0x25:
                ixh = DEC(ixh)
                tStates += 4

            // LD IXH, *
            case 0x26:
                ixh = getNextByte()
                tStates += 11

            // ADD IX, IX
            case 0x29:
                ix = ADD(ix, ix)
                tStates += 4

            // LD IX, (**)
            case 0x2A:
                ix = memory.readWord(getNextWord())
                tStates += 20

            // DEC IX
            case 0x2B:
                ix &-= 1
                tStates += 10

            // INC IXL
            case 0x2C:
                ixl = INC(ixl)
                tStates += 4

            // DEC IXL
            case 0x2D:
                ixl = DEC(ixl)
                tStates += 4

            // LD IXH, *
            case 0x2E:
                ixl = getNextByte()
                tStates += 11

            // INC (IX+*)
            case 0x34:
                addr = displacedIX()
                memory.writeByte(addr, INC(memory.readByte(addr)))
                tStates += 19

            // DEC (IX+*)
            case 0x35:
                addr = displacedIX()
                memory.writeByte(addr, DEC(memory.readByte(addr)))
                tStates += 19

            // LD (IX+*), *
            case 0x36:
                memory.writeByte(displacedIX(), getNextByte())
                tStates += 19

            // ADD IX, SP
            case 0x39:
                ix = ADD(ix, sp)
                tStates += 4

            // LD B, IXH
            case 0x44:
                b = ixh
                tStates += 8

            // LD B, IXL
            case 0x45:
                b = ixl
                tStates += 8

            // LD B, (IX+*)
            case 0x46:
                b = memory.readByte(displacedIX())
                tStates += 19

            // LD C, IXH
            case 0x4C:
                c = ixh
                tStates += 8

            // LD C, IXL
            case 0x4D:
                c = ixl
                tStates += 8

            // LD C, (IX+*)
            case 0x4E:
                c = memory.readByte(displacedIX())
                tStates += 19

            // LD D, IXH
            case 0x54:
                d = ixh
                tStates += 8

            // LD D, IXL
            case 0x55:
                d = ixl
                tStates += 8

            // LD D, (IX+*)
            case 0x56:
                d = memory.readByte(displacedIX())
                tStates += 19

            // LD E, IXH
            case 0x5C:
                e = ixh
                tStates += 8

            // LD E, IXL
            case 0x5D:
                e = ixl
                tStates += 8

            // LD E, (IX+*)
            case 0x5E:
                e = memory.readByte(displacedIX())
                tStates += 19

            // LD IXH, B
            case 0x60:
                ixh = b
                tStates += 8

            // LD IXH, C
            case 0x61:
                ixh = c
                tStates += 8

            // LD IXH, D
            case 0x62:
                ixh = d
                tStates += 8

            // LD IXH, E
            case 0x63:
                ixh = e
                tStates += 8

            // LD IXH, IXH
            case 0x64:
                tStates += 8

            // LD IXH, IXL
            case 0x65:
                ixh = ixl
                tStates += 8

            // LD H, (IX+*)
            case 0x66:
                h = memory.readByte(displacedIX())
                tStates += 19

            // LD IXH, A
            case 0x67:
                ixh = a
                tStates += 8

            // LD IXL, B
            case 0x68:
                ixl = b
                tStates += 8

            // LD IXL, C
            case 0x69:
                ixl = c
                tStates += 8

            // LD IXL, D
            case 0x6A:
                ixl = d
                tStates += 8

            // LD IXL, E
            case 0x6B:
                ixl = e
                tStates += 8

            // LD IXL, IXH
            case 0x6C:
                ixl = ixh
                tStates += 8

            // LD IXL, IXL
            case 0x6D:
                tStates += 8

            // LD L, (IX+*)
            case 0x6E:
                l = memory.readByte(displacedIX())
                tStates += 19

            // LD IXL, A
            case 0x6F:
                ixl = a
                tStates += 8

            // LD (IX+*), B
            case 0x70:
                memory.writeByte(displacedIX(), b)
                tStates += 19

            // LD (IX+*), C
            case 0x71:
                memory.writeByte(displacedIX(), c)
                tStates += 19

            // LD (IX+*), D
            case 0x72:
                memory.writeByte(displacedIX(), d)
                tStates += 19

            // LD (IX+*), E
            case 0x73:
                memory.writeByte(displacedIX(), e)
                tStates += 19

            // LD (IX+*), H
            case 0x74:
                memory.writeByte(displacedIX(), h)
                tStates += 19

            // LD (IX+*), L
            case 0x75:
                memory.writeByte(displacedIX(), l)
                tStates += 19

            // LD (IX+*), A
            case 0x77:
                memory.writeByte(displacedIX(), a)
                tStates += 19

            // LD A, IXH
            case 0x7C:
                a = ixh
                tStates += 8

            // LD A, IXL
            case 0x7D:
                a = ixl
                tStates += 8

            // LD A, (IX+*)
            case 0x7E:
                a = memory.readByte(displacedIX())
                tStates += 19

            // ADD A, IXH
            case 0x84:
                ADD(ixh)
                tStates += 4

            // ADD A, IXL
            case 0x85:
                ADD(ixl)
                tStates += 4

            // ADD A, (IX+*)
            case 0x86:
                ADD(memory.readByte(displacedIX()))
                tStates += 15

            // ADC A, IXH
            case 0x8C:
                ADC(ixh)
                tStates += 4

            // ADC A, IXL
            case 0x8D:
                ADC(ixl)
                tStates += 4

            // ADC A, (IX+*)
            case 0x8E:
                ADC(memory.readByte(displacedIX()))
                tStates += 15

            // SUB IXH
            case 0x94:
                a = SUB8(a, ixh)
                tStates += 4

            // SUB IXL
            case 0x95:
                a = SUB8(a, ixl)
                tStates += 4

            // SUB (IX+*)
            case 0x96:
                a = SUB8(a, memory.readByte(displacedIX()))
                tStates += 15

            // SBC A, IXH
            case 0x9C:
                a = SBC8(a, ixh)
                tStates += 4

            // SBC A, IXL
            case 0x9D:
                a = SBC8(a, ixl)
                tStates += 4

            // SBC A, (IX+*)
            case 0x9E:
                a = SBC8(a, memory.readByte(displacedIX()))
                tStates += 15

            // AND IXH
            case 0xA4:
                a = AND(ixh)
                tStates += 4

            // AND IXL
            case 0xA5:
                a = AND(ixl)
                tStates += 4

            // AND (IX+*)
            case 0xA6:
                a = AND(memory.readByte(displacedIX()))
                tStates += 15

            // XOR (IX+*)
            case 0xAE:
                a = XOR(memory.readByte(displacedIX()))
                tStates += 15

            // XOR IXH
            case 0xAC:
                a = XOR(ixh)
                tStates += 4

            // XOR IXL
            case 0xAD:
                a = XOR(ixl)
                tStates += 4

            // OR IXH
            case 0xB4:
                a = OR(ixh)
                tStates += 4

            // OR IXL
            case 0xB5:
                a = OR(ixl)
                tStates += 4

            // OR (IX+*)
            case 0xB6:
                a = OR(memory.readByte(displacedIX()))
                tStates += 15

            // CP IXH
            case 0xBC:
                CP(ixh)
                tStates += 4

            // CP IXL
            case 0xBD:
                CP(ixl)
                tStates += 4

            // CP (IX+*)
            case 0xBE:
                CP(memory.readByte(displacedIX()))
                tStates += 15

            // bitwise instructions
            case 0xCB:
                DecodeDDCBOpCode()

            // POP IX
            case 0xE1:
                ix = POP()
                tStates += 14

            // EX (SP), IX
            case 0xE3:
                let temp = memory.readWord(sp)
                memory.writeWord(sp, ix)
                ix = temp
                tStates += 23

            // PUSH IX
            case 0xE5:
                PUSH(ix)
                tStates += 15

            // JP (IX)
            // note that the brackets in the instruction are an eccentricity, the result
            // should be ix rather than the contents of addr(ix)
            case 0xE9:
                pc = ix
                tStates += 8

            // Undocumented, but per §3.7 of:
            //    http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
            case 0xFD:
                tStates += 8

            // LD SP, IX
            case 0xF9:
                sp = ix
                tStates += 10

            default:
                if extendedCodes.contains(opCode) {
                    tStates += 4
                    pc &-= 1 // go back one
                    _ = executeNextInstruction()
                } else {
                    return
//                  throw Exception("Opcode DD${toHex8(opCode)} not understood. ");
                }
        }
    }

    func DecodeDDCBOpCode() {
        // format is DDCB[addr][opcode]
        let addr = displacedIX()
        let opCode = getNextByte()

        // BIT
        if opCode >= 0x40, opCode <= 0x7F {
            let val = memory.readByte(addr)
            let bit: UInt8 = (opCode & 0x38) >> 3
            flags.set(.z, basedOn: !val.isBitSet(Int(bit)))
            flags.set(.pv, basedOn: flags.contains(.z)) // undocumented, but same as fZ
            flags.insert(.h)
            flags.remove(.n)
            flags.set(.f5, basedOn: (addr >> 8).isBitSet(5))
            flags.set(.f3, basedOn: (addr >> 8).isBitSet(3))
            if bit == 7 {
                flags.set(.s, basedOn: val.isSignedBitSet())
            } else {
                flags.remove(.s)
            }
            tStates += 20
            return
        } else {
            // Here follows a double-pass switch statement to determine the opcode
            // results. Firstly, we determine which kind of operation is being
            // requested, and then we identify where the result should be placed.
            var opResult: UInt8 = 0

            let opCodeType = (opCode & 0xF8) >> 3
            switch opCodeType {
                // RLC (IX+*)
                case 0x00:
                    opResult = RLC(memory.readByte(addr))

                // RRC (IX+*)
                case 0x01:
                    opResult = RRC(memory.readByte(addr))

                // RL (IX+*)
                case 0x02:
                    opResult = RL(memory.readByte(addr))

                // RR (IX+*)
                case 0x03:
                    opResult = RR(memory.readByte(addr))

                // SLA (IX+*)
                case 0x04:
                    opResult = SLA(memory.readByte(addr))

                // SRA (IX+*)
                case 0x05:
                    opResult = SRA(memory.readByte(addr))

                // SLL (IX+*)
                case 0x06:
                    opResult = SLL(memory.readByte(addr))

                // SRL (IX+*)
                case 0x07:
                    opResult = SRL(memory.readByte(addr))

                // RES n, (IX+*)
                case 0x10...0x17:
                    let bitToReset = (opCode & 0x38) >> 3
                    opResult = memory.readByte(addr)
                    opResult.resetBit(Int(bitToReset))

                // SET n, (IX+*)
                case 0x18...0x1F:
                    let bitToSet = (opCode & 0x38) >> 3
                    opResult = memory.readByte(addr)
                    opResult.setBit(Int(bitToSet))
                default:
                    break
            }
            memory.writeByte(addr, opResult)

            let opCodeTarget = opCode & 0x07
            switch opCodeTarget {
                case 0x00: // b
                    b = opResult
                case 0x01: // c
                    c = opResult
                case 0x02: // d
                    d = opResult
                case 0x03: // e
                    e = opResult
                case 0x04: // h
                    h = opResult
                case 0x05: // l
                    l = opResult
                case 0x06: // no register
                    break
                case 0x07: // a
                    a = opResult
                default:
                    break
            }

            tStates += 23
        }
    }

    func DecodeEDOpcode() {
        let opCode = getNextByte()
        r &+= 1

        switch opCode {
            // IN B, (C)
            case 0x40:
                b = onPortRead(bc)
                inSetFlags(b)
                tStates += 12

            // OUT (C), B
            case 0x41:
                OUT(portNumber: UInt16(c), value: b)
                tStates += 12

            // SBC HL, BC
            case 0x42:
                hl = SBC16(hl, bc)

            // LD (**), BC
            case 0x43:
                memory.writeWord(getNextWord(), bc)
                tStates += 20

            // NEG
            case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C:
                NEG()

            // RETN
            case 0x45, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D:
                RETN()
                tStates += 14

            // IM 0
            case 0x46, 0x66:
                im = .im0
                tStates += 8

            // LD I, A
            case 0x47:
                i = a
                tStates += 9

            // IN C, (C)
            case 0x48:
                c = onPortRead(bc)
                inSetFlags(c)
                tStates += 12

            // OUT C, (C)
            case 0x49:
                OUT(portNumber: UInt16(c), value: c)
                tStates += 12

            // ADC HL, BC
            case 0x4A:
                ADC(bc)
                tStates += 4

            // LD BC, (**)
            case 0x4B:
                bc = memory.readWord(getNextWord())
                tStates += 20

            // RETI
            case 0x4D:
                pc = POP()
                tStates += 14

            // LD R, A
            case 0x4F:
                r = a
                tStates += 9

            // IN D, (C)
            case 0x50:
                d = onPortRead(bc)
                inSetFlags(d)
                tStates += 12

            // OUT (C), D
            case 0x51:
                OUT(portNumber: UInt16(c), value: d)
                tStates += 12

            // SBC HL, DE
            case 0x52:
                hl = SBC16(hl, de)

            // LD (**), DE
            case 0x53:
                memory.writeWord(getNextWord(), de)
                tStates += 20

            // IM 1
            case 0x4E, 0x56, 0x6E, 0x76:
                im = .im1
                tStates += 8

            // LD A, I
            case 0x57:
                a = i
                flags.set(.s, basedOn: i.isSignedBitSet())
                flags.setZeroFlag(basedOn: i)
                flags.set(.f5, basedOn: i.isBitSet(5))
                flags.set(.f3, basedOn: i.isBitSet(3))
                flags.remove([.h, .n])
                flags.set(.pv, basedOn: iff2)
                tStates += 9

            // IN E, (C)
            case 0x58:
                e = onPortRead(bc)
                inSetFlags(e)
                tStates += 12

            // OUT (C), E
            case 0x59:
                OUT(portNumber: UInt16(c), value: e)
                tStates += 12

            // ADC HL, DE
            case 0x5A:
                ADC(de)
                tStates += 4

            // LD DE, (**)
            case 0x5B:
                de = memory.readWord(getNextWord())
                tStates += 20

            // IM 2
            case 0x5E, 0x7E:
                im = .im2
                tStates += 8

            // LD A, R
            case 0x5F:
                a = r
                flags.set(.s, basedOn: r.isSignedBitSet())
                flags.setZeroFlag(basedOn: r)
                flags.remove([.h, .n])
                flags.set(.pv, basedOn: iff2)
                tStates += 9

            // IN H, (C)
            case 0x60:
                h = onPortRead(bc)
                inSetFlags(h)
                tStates += 12

            // OUT (C), H
            case 0x61:
                OUT(portNumber: UInt16(c), value: h)
                tStates += 12

            // SBC HL, HL
            case 0x62:
                hl = SBC16(hl, hl)

            // LD (**), HL
            case 0x63:
                memory.writeWord(getNextWord(), hl)
                tStates += 20

            // RRD
            case 0x67:
                RRD()

            // IN L, (C)
            case 0x68:
                l = onPortRead(bc)
                inSetFlags(l)
                tStates += 12

            // OUT (C), L
            case 0x69:
                OUT(portNumber: UInt16(c), value: l)
                tStates += 12

            // ADC HL, HL
            case 0x6A:
                ADC(hl)
                tStates += 4

            // LD HL, (**)
            case 0x6B:
                hl = memory.readWord(getNextWord())
                tStates += 20

            // RLD
            case 0x6F:
                RLD()

            // IN (C)
            case 0x70:
                // TODO: Check this shouldn't go to c
                _ = onPortRead(bc)
                tStates += 12

            // OUT (C), 0
            case 0x71:
                OUT(portNumber: UInt16(c), value: 0)
                tStates += 12

            // SBC HL, SP
            case 0x72:
                hl = SBC16(hl, sp)

            // LD (**), SP
            case 0x73:
                memory.writeWord(getNextWord(), sp)
                tStates += 20

            // IN A, (C)
            case 0x78:
                a = onPortRead(bc)
                inSetFlags(a)
                tStates += 12

            // OUT (C), A
            case 0x79:
                OUT(portNumber: UInt16(c), value: a)
                tStates += 12

            // ADC HL, SP
            case 0x7A:
                ADC(sp)
                tStates += 4

            // LD SP, (**)
            case 0x7B:
                sp = memory.readWord(getNextWord())
                tStates += 20

            // LDI
            case 0xA0:
                LDI()

            // CPI
            case 0xA1:
                CPI()

            // INI
            case 0xA2:
                INI()

            // OUTI
            case 0xA3:
                OUTI()

            // LDD
            case 0xA8:
                LDD()

            // CPD
            case 0xA9:
                CPD()

            // IND
            case 0xAA:
                IND()

            // OUTD
            case 0xAB:
                OUTD()

            // LDIR
            case 0xB0:
                LDIR()

            // CPIR
            case 0xB1:
                CPIR()

            // INIR
            case 0xB2:
                INIR()

            // OTIR
            case 0xB3:
                OTIR()

            // LDDR
            case 0xB8:
                LDDR()

            // CPDR
            case 0xB9:
                CPDR()

            // INDR
            case 0xBA:
                INDR()

            // OTDR
            case 0xBB:
                OTDR()

            default:
                break
        }
    }

    // TODO: Coalesce with IX equivalent function (DecodeDDOpcode) using inout param
    func DecodeFDOpcode() {
        let opCode = getNextByte()
        r &+= 1

        var addr: UInt16 = 0

        switch opCode {
            // NOP
            case 0x00:
                tStates += 8

            // ADD IY, BC
            case 0x09:
                iy = ADD(iy, bc)
                tStates += 4

            // ADD IY, DE
            case 0x19:
                iy = ADD(iy, de)
                tStates += 4

            // LD IY, **
            case 0x21:
                iy = getNextWord()
                tStates += 14

            // LD (**), IY
            case 0x22:
                memory.writeWord(getNextWord(), iy)
                tStates += 20

            // INC IY
            case 0x23:
                iy &+= 1
                tStates += 10

            // INC IYH
            case 0x24:
                iyh = INC(iyh)
                tStates += 4

            // DEC IYH
            case 0x25:
                iyh = DEC(iyh)
                tStates += 4

            // LD IYH, *
            case 0x26:
                iyh = getNextByte()
                tStates += 11

            // ADD IY, IY
            case 0x29:
                iy = ADD(iy, iy)
                tStates += 4

            // LD IY, (**)
            case 0x2A:
                iy = memory.readWord(getNextWord())
                tStates += 20

            // DEC IY
            case 0x2B:
                iy &-= 1
                tStates += 10

            // INC IYL
            case 0x2C:
                iyl = INC(iyl)
                tStates += 4

            // DEC IYL
            case 0x2D:
                iyl = DEC(iyl)
                tStates += 4

            // LD IYH, *
            case 0x2E:
                iyl = getNextByte()
                tStates += 11

            // INC (IY+*)
            case 0x34:
                addr = displacedIY()
                memory.writeByte(addr, INC(memory.readByte(addr)))
                tStates += 19

            // DEC (IY+*)
            case 0x35:
                addr = displacedIY()
                memory.writeByte(addr, DEC(memory.readByte(addr)))
                tStates += 19

            // LD (IY+*), *
            case 0x36:
                memory.writeByte(displacedIY(), getNextByte())
                tStates += 19

            // ADD IY, SP
            case 0x39:
                iy = ADD(iy, sp)
                tStates += 4

            // LD B, IYH
            case 0x44:
                b = iyh
                tStates += 8

            // LD B, IYL
            case 0x45:
                b = iyl
                tStates += 8

            // LD B, (IY+*)
            case 0x46:
                b = memory.readByte(displacedIY())
                tStates += 19

            // LD C, IYH
            case 0x4C:
                c = iyh
                tStates += 8

            // LD C, IYL
            case 0x4D:
                c = iyl
                tStates += 8

            // LD C, (IY+*)
            case 0x4E:
                c = memory.readByte(displacedIY())
                tStates += 19

            // LD D, IYH
            case 0x54:
                d = iyh
                tStates += 8

            // LD D, IYL
            case 0x55:
                d = iyl
                tStates += 8

            // LD D, (IY+*)
            case 0x56:
                d = memory.readByte(displacedIY())
                tStates += 19

            // LD E, IYH
            case 0x5C:
                e = iyh
                tStates += 8

            // LD E, IYL
            case 0x5D:
                e = iyl
                tStates += 8

            // LD E, (IY+*)
            case 0x5E:
                e = memory.readByte(displacedIY())
                tStates += 19

            // LD IYH, B
            case 0x60:
                iyh = b
                tStates += 8

            // LD IYH, C
            case 0x61:
                iyh = c
                tStates += 8

            // LD IYH, D
            case 0x62:
                iyh = d
                tStates += 8

            // LD IYH, E
            case 0x63:
                iyh = e
                tStates += 8

            // LD IYH, IYH
            case 0x64:
                tStates += 8

            // LD IYH, IYL
            case 0x65:
                iyh = iyl
                tStates += 8

            // LD H, (IY+*)
            case 0x66:
                h = memory.readByte(displacedIY())
                tStates += 19

            // LD IYH, A
            case 0x67:
                iyh = a
                tStates += 8

            // LD IYL, B
            case 0x68:
                iyl = b
                tStates += 8

            // LD IYL, C
            case 0x69:
                iyl = c
                tStates += 8

            // LD IYL, D
            case 0x6A:
                iyl = d
                tStates += 8

            // LD IYL, E
            case 0x6B:
                iyl = e
                tStates += 8

            // LD IYL, IYH
            case 0x6C:
                iyl = iyh
                tStates += 8

            // LD IYL, IYL
            case 0x6D:
                tStates += 8

            // LD L, (IY+*)
            case 0x6E:
                l = memory.readByte(displacedIY())
                tStates += 19

            // LD IYL, A
            case 0x6F:
                iyl = a
                tStates += 8

            // LD (IY+*), B
            case 0x70:
                memory.writeByte(displacedIY(), b)
                tStates += 19

            // LD (IY+*), C
            case 0x71:
                memory.writeByte(displacedIY(), c)
                tStates += 19

            // LD (IY+*), D
            case 0x72:
                memory.writeByte(displacedIY(), d)
                tStates += 19

            // LD (IY+*), E
            case 0x73:
                memory.writeByte(displacedIY(), e)
                tStates += 19

            // LD (IY+*), H
            case 0x74:
                memory.writeByte(displacedIY(), h)
                tStates += 19

            // LD (IY+*), L
            case 0x75:
                memory.writeByte(displacedIY(), l)
                tStates += 19

            // LD (IY+*), A
            case 0x77:
                memory.writeByte(displacedIY(), a)
                tStates += 19

            // LD A, IYH
            case 0x7C:
                a = iyh
                tStates += 8

            // LD A, IYL
            case 0x7D:
                a = iyl
                tStates += 8

            // LD A, (IY+*)
            case 0x7E:
                a = memory.readByte(displacedIY())
                tStates += 19

            // ADD A, IYH
            case 0x84:
                ADD(iyh)
                tStates += 4

            // ADD A, IYL
            case 0x85:
                ADD(iyl)
                tStates += 4

            // ADD A, (IY+*)
            case 0x86:
                ADD(memory.readByte(displacedIY()))
                tStates += 15

            // ADC A, IYH
            case 0x8C:
                ADC(iyh)
                tStates += 4

            // ADC A, IYL
            case 0x8D:
                ADC(iyl)
                tStates += 4

            // ADC A, (IY+*)
            case 0x8E:
                ADC(memory.readByte(displacedIY()))
                tStates += 15

            // SUB IYH
            case 0x94:
                a = SUB8(a, iyh)
                tStates += 4

            // SUB IYL
            case 0x95:
                a = SUB8(a, iyl)
                tStates += 4

            // SUB (IY+*)
            case 0x96:
                a = SUB8(a, memory.readByte(displacedIY()))
                tStates += 15

            // SBC A, IYH
            case 0x9C:
                a = SBC8(a, iyh)
                tStates += 4

            // SBC A, IYL
            case 0x9D:
                a = SBC8(a, iyl)
                tStates += 4

            // SBC A, (IY+*)
            case 0x9E:
                a = SBC8(a, memory.readByte(displacedIY()))
                tStates += 15

            // AND IYH
            case 0xA4:
                a = AND(iyh)
                tStates += 4

            // AND IYL
            case 0xA5:
                a = AND(iyl)
                tStates += 4

            // AND (IY+*)
            case 0xA6:
                a = AND(memory.readByte(displacedIY()))
                tStates += 15

            // XOR (IY+*)
            case 0xAE:
                a = XOR(memory.readByte(displacedIY()))
                tStates += 15

            // XOR IYH
            case 0xAC:
                a = XOR(iyh)
                tStates += 4

            // XOR IYL
            case 0xAD:
                a = XOR(iyl)
                tStates += 4

            // OR IYH
            case 0xB4:
                a = OR(iyh)
                tStates += 4

            // OR IYL
            case 0xB5:
                a = OR(iyl)
                tStates += 4

            // OR (IY+*)
            case 0xB6:
                a = OR(memory.readByte(displacedIY()))
                tStates += 15

            // CP IYH
            case 0xBC:
                CP(iyh)
                tStates += 4

            // CP IYL
            case 0xBD:
                CP(iyl)
                tStates += 4

            // CP (IY+*)
            case 0xBE:
                CP(memory.readByte(displacedIY()))
                tStates += 15

            // bitwise instructions
            case 0xCB:
                DecodeFDCBOpCode()

            // POP IY
            case 0xE1:
                iy = POP()
                tStates += 14

            // EX (SP), IY
            case 0xE3:
                let temp = memory.readWord(sp)
                memory.writeWord(sp, iy)
                iy = temp
                tStates += 23

            // PUSH IY
            case 0xE5:
                PUSH(iy)
                tStates += 15

            // JP (IY)
            // note that the brackets in the instruction are an eccentricity, the result
            // should be iy rather than the contents of addr(iy)
            case 0xE9:
                pc = iy
                tStates += 8

            // LD SP, IY
            case 0xF9:
                sp = iy
                tStates += 10

            default:
                if extendedCodes.contains(opCode) {
                    tStates += 4 // instructions take an extra 4 bytes over unprefixed
                    pc &-= 1 // go back one
                    _ = executeNextInstruction()
                } else {
                    return
//            throw Exception("Opcode FD${toHex8(opCode)} not understood. ");
                }
        }
    }

    func DecodeFDCBOpCode() {
        // format is FDCB[addr][opcode]
        let addr = displacedIY()
        let opCode = getNextByte()

        // BIT
        if opCode >= 0x40, opCode <= 0x7F {
            let val = memory.readByte(addr)
            let bit: UInt8 = (opCode & 0x38) >> 3
            flags.set(.z, basedOn: !val.isBitSet(Int(bit)))
            flags.set(.pv, basedOn: flags.contains(.z)) // undocumented, but same as fZ
            flags.insert(.h)
            flags.remove(.n)
            flags.set(.f5, basedOn: (addr >> 8).isBitSet(5))
            flags.set(.f3, basedOn: (addr >> 8).isBitSet(3))
            if bit == 7 {
                flags.set(.s, basedOn: val.isSignedBitSet())
            } else {
                flags.remove(.s)
            }
            tStates += 20
            return
        } else {
            // Here follows a double-pass switch statement to determine the opcode
            // results. Firstly, we determine which kind of operation is being
            // requested, and then we identify where the result should be placed.
            var opResult: UInt8 = 0

            let opCodeType = (opCode & 0xF8) >> 3
            switch opCodeType {
                // RLC (IY+*)
                case 0x00:
                    opResult = RLC(memory.readByte(addr))

                // RRC (IY+*)
                case 0x01:
                    opResult = RRC(memory.readByte(addr))

                // RL (IY+*)
                case 0x02:
                    opResult = RL(memory.readByte(addr))

                // RR (IY+*)
                case 0x03:
                    opResult = RR(memory.readByte(addr))

                // SLA (IY+*)
                case 0x04:
                    opResult = SLA(memory.readByte(addr))

                // SRA (IY+*)
                case 0x05:
                    opResult = SRA(memory.readByte(addr))

                // SLL (IY+*)
                case 0x06:
                    opResult = SLL(memory.readByte(addr))

                // SRL (IY+*)
                case 0x07:
                    opResult = SRL(memory.readByte(addr))

                // RES n, (IY+*)
                case 0x10...0x17:
                    let bitToReset = (opCode & 0x38) >> 3
                    opResult = memory.readByte(addr)
                    opResult.resetBit(Int(bitToReset))

                // SET n, (IY+*)
                case 0x18...0x1F:
                    let bitToSet = (opCode & 0x38) >> 3
                    opResult = memory.readByte(addr)
                    opResult.setBit(Int(bitToSet))
                default:
                    break
            }
            memory.writeByte(addr, opResult)

            let opCodeTarget = opCode & 0x07
            switch opCodeTarget {
                case 0x00: // b
                    b = opResult
                case 0x01: // c
                    c = opResult
                case 0x02: // d
                    d = opResult
                case 0x03: // e
                    e = opResult
                case 0x04: // h
                    h = opResult
                case 0x05: // l
                    l = opResult
                case 0x06: // no register
                    break
                case 0x07: // a
                    a = opResult
                default:
                    break
            }

            tStates += 23
        }
    }

    public func executeNextInstruction() -> Bool {
        halt = false
        let opCode = getNextByte()

        r &+= 1

        switch opCode {
            // NOP
            case 0x00:
                tStates += 4

            // LD BC, **
            case 0x01:
                bc = getNextWord()
                tStates += 10

            // LD (BC), A
            case 0x02:
                memory.writeByte(bc, a)
                tStates += 7

            // INC BC
            case 0x03:
                bc = (bc &+ 1)
                tStates += 6

            // INC B
            case 0x04:
                b = INC(b)

            // DEC B
            case 0x05:
                b = DEC(b)

            // LD B, *
            case 0x06:
                b = getNextByte()
                tStates += 7

            // RLCA
            case 0x07:
                RLCA()

            // EX AF, AF'
            case 0x08:
                EX_AFAFPrime()

            // ADD HL, BC
            case 0x09:
                hl = ADD(hl, bc)

            // LD A, (BC)
            case 0x0A:
                a = memory.readByte(bc)
                tStates += 7

            // DEC BC
            case 0x0B:
                bc &-= 1
                tStates += 6

            // INC C
            case 0x0C:
                c = INC(c)

            // DEC C
            case 0x0D:
                c = DEC(c)

            // LD C, *
            case 0x0E:
                c = getNextByte()
                tStates += 7

            // RRCA
            case 0x0F:
                RRCA()

            // DJNZ *
            case 0x10:
                DJNZ(getNextByte())

            // LD DE, **
            case 0x11:
                de = getNextWord()
                tStates += 10

            // LD (DE), A
            case 0x12:
                memory.writeByte(de, a)
                tStates += 7

            // INC DE
            case 0x13:
                de &+= 1
                tStates += 6

            // INC D
            case 0x14:
                d = INC(d)

            // DEC D
            case 0x15:
                d = DEC(d)

            // LD D, *
            case 0x16:
                d = getNextByte()
                tStates += 7

            // RLA
            case 0x17:
                RLA()

            // JR *
            case 0x18:
                JR(getNextByte())

            // ADD HL, DE
            case 0x19:
                hl = ADD(hl, de)

            // LD A, (DE)
            case 0x1A:
                a = memory.readByte(de)
                tStates += 7

            // DEC DE
            case 0x1B:
                de &-= 1
                tStates += 6

            // INC E
            case 0x1C:
                e = INC(e)

            // DEC E
            case 0x1D:
                e = DEC(e)

            // LD E, *
            case 0x1E:
                e = getNextByte()
                tStates += 7

            // RRA
            case 0x1F:
                RRA()

            // JR NZ, *
            case 0x20:
                if !flags.contains(.z) {
                    JR(getNextByte())
                } else {
                    pc &+= 1
                    tStates += 7
                }

            // LD HL, **
            case 0x21:
                hl = getNextWord()
                tStates += 10

            // LD (**), HL
            case 0x22:
                memory.writeWord(getNextWord(), hl)
                tStates += 16

            // INC HL
            case 0x23:
                hl &+= 1
                tStates += 6

            // INC H
            case 0x24:
                h = INC(h)

            // DEC H
            case 0x25:
                h = DEC(h)

            // LD H, *
            case 0x26:
                h = getNextByte()
                tStates += 7

            // DAA
            case 0x27:
                DAA()

            // JR Z, *
            case 0x28:
                if flags.contains(.z) {
                    JR(getNextByte())
                } else {
                    pc &+= 1
                    tStates += 7
                }

            // ADD HL, HL
            case 0x29:
                hl = ADD(hl, hl)

            // LD HL, (**)
            case 0x2A:
                hl = memory.readWord(getNextWord())
                tStates += 16

            // DEC HL
            case 0x2B:
                hl &-= 1
                tStates += 6

            // INC L
            case 0x2C:
                l = INC(l)

            // DEC L
            case 0x2D:
                l = DEC(l)

            // LD L, *
            case 0x2E:
                l = getNextByte()
                tStates += 7

            // CPL
            case 0x2F:
                CPL()

            // JR NC, *
            case 0x30:
                if !flags.contains(.c) {
                    JR(getNextByte())
                } else {
                    pc &+= 1
                    tStates += 7
                }

            // LD SP, **
            case 0x31:
                sp = getNextWord()
                tStates += 10

            // LD (**), A
            case 0x32:
                memory.writeByte(getNextWord(), a)
                tStates += 13

            // INC SP
            case 0x33:
                sp &+= 1
                tStates += 6

            // INC (HL)
            case 0x34:
                memory.writeByte(hl, INC(memory.readByte(hl)))
                tStates += 7

            // DEC (HL)
            case 0x35:
                memory.writeByte(hl, DEC(memory.readByte(hl)))
                tStates += 7

            // LD (HL), *
            case 0x36:
                memory.writeByte(hl, getNextByte())
                tStates += 10

            // SCF
            case 0x37:
                SCF()
                tStates += 4

            // JR C, *
            case 0x38:
                if flags.contains(.c) {
                    JR(getNextByte())
                } else {
                    pc &+= 1
                    tStates += 7
                }

            // ADD HL, SP
            case 0x39:
                hl = ADD(hl, sp)

            // LD A, (**)
            case 0x3A:
                a = memory.readByte(getNextWord())
                tStates += 13

            // DEC SP
            case 0x3B:
                sp &-= 1
                tStates += 6

            // INC A
            case 0x3C:
                a = INC(a)

            // DEC A
            case 0x3D:
                a = DEC(a)

            // LD A, *
            case 0x3E:
                a = getNextByte()
                tStates += 7

            // CCF
            case 0x3F:
                CCF()

            // LD B, B
            case 0x40:
                tStates += 4

            // LD B, C
            case 0x41:
                b = c
                tStates += 4

            // LD B, D
            case 0x42:
                b = d
                tStates += 4

            // LD B, E
            case 0x43:
                b = e
                tStates += 4

            // LD B, H
            case 0x44:
                b = h
                tStates += 4

            // LD B, L
            case 0x45:
                b = l
                tStates += 4

            // LD B, (HL)
            case 0x46:
                b = memory.readByte(hl)
                tStates += 7

            // LD B, A
            case 0x47:
                b = a
                tStates += 4

            // LD C, B
            case 0x48:
                c = b
                tStates += 4

            // LD C, C
            case 0x49:
                tStates += 4

            // LD C, D
            case 0x4A:
                c = d
                tStates += 4

            // LD C, E
            case 0x4B:
                c = e
                tStates += 4

            // LD C, H
            case 0x4C:
                c = h
                tStates += 4

            // LD C, L
            case 0x4D:
                c = l
                tStates += 4

            // LD C, (HL)
            case 0x4E:
                c = memory.readByte(hl)
                tStates += 7

            // LD C, A
            case 0x4F:
                c = a
                tStates += 4

            // LD D, B
            case 0x50:
                d = b
                tStates += 4

            // LD D, C
            case 0x51:
                d = c
                tStates += 4

            // LD D, D
            case 0x52:
                tStates += 4

            // LD D, E
            case 0x53:
                d = e
                tStates += 4

            // LD D, H
            case 0x54:
                d = h
                tStates += 4

            // LD D, L
            case 0x55:
                d = l
                tStates += 4

            // LD D, (HL)
            case 0x56:
                d = memory.readByte(hl)
                tStates += 7

            // LD D, A
            case 0x57:
                d = a
                tStates += 4

            // LD E, B
            case 0x58:
                e = b
                tStates += 4

            // LD E, C
            case 0x59:
                e = c
                tStates += 4

            // LD E, D
            case 0x5A:
                e = d
                tStates += 4

            // LD E, E
            case 0x5B:
                tStates += 4

            // LD E, H
            case 0x5C:
                e = h
                tStates += 4

            // LD E, L
            case 0x5D:
                e = l
                tStates += 4

            // LD E, (HL)
            case 0x5E:
                e = memory.readByte(hl)
                tStates += 7

            // LD E, A
            case 0x5F:
                e = a
                tStates += 4

            // LD H, B
            case 0x60:
                h = b
                tStates += 4

            // LD H, C
            case 0x61:
                h = c
                tStates += 4

            // LD H, D
            case 0x62:
                h = d
                tStates += 4

            // LD H, E
            case 0x63:
                h = e
                tStates += 4

            // LD H, H
            case 0x64:
                tStates += 4

            // LD H, L
            case 0x65:
                h = l
                tStates += 4

            // LD H, (HL)
            case 0x66:
                h = memory.readByte(hl)
                tStates += 7

            // LD H, A
            case 0x67:
                h = a
                tStates += 4

            // LD L, B
            case 0x68:
                l = b
                tStates += 4

            // LD L, C
            case 0x69:
                l = c
                tStates += 4

            // LD L, D
            case 0x6A:
                l = d
                tStates += 4

            // LD L, E
            case 0x6B:
                l = e
                tStates += 4

            // LD L, H
            case 0x6C:
                l = h
                tStates += 4

            // LD L, L
            case 0x6D:
                tStates += 4

            // LD L, (HL)
            case 0x6E:
                l = memory.readByte(hl)
                tStates += 7

            // LD L, A
            case 0x6F:
                l = a
                tStates += 4

            // LD (HL), B
            case 0x70:
                memory.writeByte(hl, b)
                tStates += 7

            // LD (HL), C
            case 0x71:
                memory.writeByte(hl, c)
                tStates += 7

            // LD (HL), D
            case 0x72:
                memory.writeByte(hl, d)
                tStates += 7

            // LD (HL), E
            case 0x73:
                memory.writeByte(hl, e)
                tStates += 7

            // LD (HL), H
            case 0x74:
                memory.writeByte(hl, h)
                tStates += 7

            // LD (HL), L
            case 0x75:
                memory.writeByte(hl, l)
                tStates += 7

            // HALT
            case 0x76:
                tStates += 4
                halt = true
                pc &-= 1 // return to HALT, just keep executing it.

            // LD (HL), A
            case 0x77:
                memory.writeByte(hl, a)
                tStates += 7

            // LD A, B
            case 0x78:
                a = b
                tStates += 4

            // LD A, C
            case 0x79:
                a = c
                tStates += 4

            // LD A, D
            case 0x7A:
                a = d
                tStates += 4

            // LD A, E
            case 0x7B:
                a = e
                tStates += 4

            // LD A, H
            case 0x7C:
                a = h
                tStates += 4

            // LD A, L
            case 0x7D:
                a = l
                tStates += 4

            // LD A, (HL)
            case 0x7E:
                a = memory.readByte(hl)
                tStates += 7

            // LD A, A
            case 0x7F:
                tStates += 4

            // ADD A, B
            case 0x80:
                ADD(b)

            // ADD A, C
            case 0x81:
                ADD(c)

            // ADD A, D
            case 0x82:
                ADD(d)

            // ADD A, E
            case 0x83:
                ADD(e)

            // ADD A, H
            case 0x84:
                ADD(h)

            // ADD A, L
            case 0x85:
                ADD(l)

            // ADD A, (HL)
            case 0x86:
                ADD(memory.readByte(hl))
                tStates += 3

            // ADD A, A
            case 0x87:
                ADD(a)

            // ADC A, B
            case 0x88:
                ADC(b)

            // ADC A, C
            case 0x89:
                ADC(c)

            // ADC A, D
            case 0x8A:
                ADC(d)

            // ADC A, E
            case 0x8B:
                ADC(e)

            // ADC A, H
            case 0x8C:
                ADC(h)

            // ADC A, L
            case 0x8D:
                ADC(l)

            // ADC A, (HL)
            case 0x8E:
                ADC(memory.readByte(hl))
                tStates += 3

            // ADC A, A
            case 0x8F:
                ADC(a)

            // SUB B
            case 0x90:
                a = SUB8(a, b)

            // SUB C
            case 0x91:
                a = SUB8(a, c)

            // SUB D
            case 0x92:
                a = SUB8(a, d)

            // SUB E
            case 0x93:
                a = SUB8(a, e)

            // SUB H
            case 0x94:
                a = SUB8(a, h)

            // SUB L
            case 0x95:
                a = SUB8(a, l)

            // SUB (HL)
            case 0x96:
                a = SUB8(a, memory.readByte(hl))
                tStates += 3

            // SUB A
            case 0x97:
                a = SUB8(a, a)

            // SBC A, B
            case 0x98:
                a = SBC8(a, b)

            // SBC A, C
            case 0x99:
                a = SBC8(a, c)

            // SBC A, D
            case 0x9A:
                a = SBC8(a, d)

            // SBC A, E
            case 0x9B:
                a = SBC8(a, e)

            // SBC A, H
            case 0x9C:
                a = SBC8(a, h)

            // SBC A, L
            case 0x9D:
                a = SBC8(a, l)

            // SBC A, (HL)
            case 0x9E:
                a = SBC8(a, memory.readByte(hl))
                tStates += 3

            // SBC A, A
            case 0x9F:
                a = SBC8(a, a)

            // AND B
            case 0xA0:
                a = AND(b)

            // AND C
            case 0xA1:
                a = AND(c)

            // AND D
            case 0xA2:
                a = AND(d)

            // AND E
            case 0xA3:
                a = AND(e)

            // AND H
            case 0xA4:
                a = AND(h)

            // AND L
            case 0xA5:
                a = AND(l)

            // AND (HL)
            case 0xA6:
                a = AND(memory.readByte(hl))
                tStates += 3

            // AND A
            case 0xA7:
                a = AND(a)

            // XOR B
            case 0xA8:
                a = XOR(b)

            // XOR C
            case 0xA9:
                a = XOR(c)

            // XOR D
            case 0xAA:
                a = XOR(d)

            // XOR E
            case 0xAB:
                a = XOR(e)

            // XOR H
            case 0xAC:
                a = XOR(h)

            // XOR L
            case 0xAD:
                a = XOR(l)

            // XOR (HL)
            case 0xAE:
                a = XOR(memory.readByte(hl))
                tStates += 3

            // XOR A
            case 0xAF:
                a = XOR(a)

            // OR B
            case 0xB0:
                a = OR(b)

            // OR C
            case 0xB1:
                a = OR(c)

            // OR D
            case 0xB2:
                a = OR(d)

            // OR E
            case 0xB3:
                a = OR(e)

            // OR H
            case 0xB4:
                a = OR(h)

            // OR L
            case 0xB5:
                a = OR(l)

            // OR (HL)
            case 0xB6:
                a = OR(memory.readByte(hl))
                tStates += 3

            // OR A
            case 0xB7:
                a = OR(a)

            // CP B
            case 0xB8:
                CP(b)

            // CP C
            case 0xB9:
                CP(c)

            // CP D
            case 0xBA:
                CP(d)

            // CP E
            case 0xBB:
                CP(e)

            // CP H
            case 0xBC:
                CP(h)

            // CP L
            case 0xBD:
                CP(l)

            // CP (HL)
            case 0xBE:
                CP(memory.readByte(hl))
                tStates += 3

            // CP A
            case 0xBF:
                CP(a)

            // RET NZ
            case 0xC0:
                if !flags.contains(.z) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // POP BC
            case 0xC1:
                bc = POP()
                tStates += 10

            // JP NZ, **
            case 0xC2:
                if !flags.contains(.z) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // JP **
            case 0xC3:
                pc = getNextWord()
                tStates += 10

            // CALL NZ, **
            case 0xC4:
                if !flags.contains(.z) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // PUSH BC
            case 0xC5:
                PUSH(bc)
                tStates += 11

            // ADD A, *
            case 0xC6:
                ADD(getNextByte())
                tStates += 3

            // RST 00h
            case 0xC7:
                RST(0x00)

            // RET Z
            case 0xC8:
                if flags.contains(.z) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // RET
            case 0xC9:
                pc = POP()
                tStates += 10

            // JP Z, **
            case 0xCA:
                if flags.contains(.z) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // BITWISE INSTRUCTIONS
            case 0xCB:
                DecodeCBOpcode()

            // CALL Z, **
            case 0xCC:
                if flags.contains(.z) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // CALL **
            case 0xCD:
                CALL()

            // ADC A, *
            case 0xCE:
                ADC(getNextByte())
                tStates += 3

            // RST 08h
            case 0xCF:
                RST(0x08)

            // RET NC
            case 0xD0:
                if !flags.contains(.c) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // POP DE
            case 0xD1:
                de = POP()
                tStates += 10

            // JP NC, **
            case 0xD2:
                if !flags.contains(.c) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // OUT (*), A
            case 0xD3:
                OUTA(portNumber: UInt16(getNextByte()), value: a)
                tStates += 11

            // CALL NC, **
            case 0xD4:
                if !flags.contains(.c) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // PUSH DE
            case 0xD5:
                PUSH(de)
                tStates += 11

            // SUB *
            case 0xD6:
                a = SUB8(a, getNextByte())
                tStates += 3

            // RST 10h
            case 0xD7:
                RST(0x10)

            // RET C
            case 0xD8:
                if flags.contains(.c) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // EXX
            case 0xD9:
                swap(&b, &b_)
                swap(&c, &c_)
                swap(&d, &d_)
                swap(&e, &e_)
                swap(&h, &h_)
                swap(&l, &l_)
                tStates += 4

            // JP C, **
            case 0xDA:
                if flags.contains(.c) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // IN A, (*)
            case 0xDB:
                a = INA(getNextByte())
                tStates += 11

            // CALL C, **
            case 0xDC:
                if flags.contains(.c) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // IX OPERATIONS
            case 0xDD:
                DecodeDDOpcode()

            // SBC A, *
            case 0xDE:
                a = SBC8(a, getNextByte())
                tStates += 3

            // RST 18h
            case 0xDF:
                RST(0x18)

            // RET PO
            case 0xE0:
                if !flags.contains(.pv) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // POP HL
            case 0xE1:
                hl = POP()
                tStates += 10

            // JP PO, **
            case 0xE2:
                if !flags.contains(.pv) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // EX (SP), HL
            case 0xE3:
                let temp = hl
                hl = memory.readWord(sp)
                memory.writeWord(sp, temp)
                tStates += 19

            // CALL PO, **
            case 0xE4:
                if !flags.contains(.pv) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // PUSH HL
            case 0xE5:
                PUSH(hl)
                tStates += 11

            // AND *
            case 0xE6:
                a = AND(getNextByte())
                tStates += 3

            // RST 20h
            case 0xE7:
                RST(0x20)

            // RET PE
            case 0xE8:
                if flags.contains(.pv) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // JP (HL)
            // Note that the brackets in the instruction are an eccentricity, the result
            // should be hl rather than the contents of addr(hl)
            case 0xE9:
                pc = hl
                tStates += 4

            // JP PE, **
            case 0xEA:
                if flags.contains(.pv) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // EX DE, HL
            case 0xEB:
                swap(&d, &h)
                swap(&e, &l)
                tStates += 4

            // CALL PE, **
            case 0xEC:
                if flags.contains(.pv) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // EXTD INSTRUCTIONS
            case 0xED:
                DecodeEDOpcode()

            // XOR *
            case 0xEE:
                a = XOR(getNextByte())
                tStates += 3

            // RST 28h
            case 0xEF:
                RST(0x28)

            // RET P
            case 0xF0:
                if !flags.contains(.s) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // POP AF
            case 0xF1:
                af = POP()
                tStates += 10

            // JP P, **
            case 0xF2:
                if !flags.contains(.s) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // DI
            case 0xF3:
                iff1 = false
                iff2 = false
                tStates += 4

            // CALL P, **
            case 0xF4:
                if !flags.contains(.s) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // PUSH AF
            case 0xF5:
                PUSH(af)
                tStates += 11

            // OR *
            case 0xF6:
                a = OR(getNextByte())
                tStates += 3

            // RST 30h
            case 0xF7:
                RST(0x30)

            // RET M
            case 0xF8:
                if flags.contains(.s) {
                    pc = POP()
                    tStates += 11
                } else {
                    tStates += 5
                }

            // LD SP, HL
            case 0xF9:
                sp = hl
                tStates += 6

            // JP M, **
            case 0xFA:
                if flags.contains(.s) {
                    pc = getNextWord()
                } else {
                    pc &+= 2
                }
                tStates += 10

            // EI
            case 0xFB:
                iff1 = true
                iff2 = true
                tStates += 4

            // CALL M, **
            case 0xFC:
                if flags.contains(.s) {
                    CALL()
                } else {
                    pc &+= 2
                    tStates += 10
                }

            // IY INSTRUCTIONS
            case 0xFD:
                DecodeFDOpcode()

            // CP *
            case 0xFE:
                CP(getNextByte())
                tStates += 3

            // RST 38h
            case 0xFF:
                RST(0x38)

            default:
                // Undocumented or unimplemented instruction
                return false
        }
        return true
    }
}
