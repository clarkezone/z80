//
//  Z80InstructionTests.swift
//
//  z80instruction_test.dart -- test a common set of Z80 instructions against
//  Zilog spec
//
//  Created by Tim Sneath on 6/10/23.
//

import XCTest
@testable import z80

class Z80InstructionTests: XCTestCase
{
    // we pick this as a 'safe' location that doesn't clash with other
    // instructions
    let origin: UInt16 = 0xA000
    let haltOpcode: UInt8 = 0x76

    var z80: Z80 = Z80()

    override func setUp()
    {
        // reinitialize memory and processor start state
        z80 = Z80()
    }

    func poke(_ address: UInt16, _ value: UInt8) { z80.memory.writeByte(address, value) }
    func peek(_ address: UInt16) -> UInt8 { z80.memory.readByte(address) }

    func loadInstructions(_ instructions: [UInt8])
    {
        z80.memory.load(origin: origin, data: instructions)
        z80.memory.writeByte(
            origin + UInt16(instructions.count), haltOpcode) // HALT instruction
    }

    func executeInstructions(_ instructions: [UInt8])
    {
        loadInstructions(instructions)
        z80.pc = origin
        while !(peek(z80.pc) == haltOpcode)
        {
            let success = z80.executeNextInstruction()
            if (!success) { return }
        }
        z80.r &+= 1 // Account for HALT instruction
    }

    func testNOP()
    {
        let beforeAF = z80.af
        let beforeBC = z80.bc
        let beforeDE = z80.de
        let beforeHL = z80.hl
        let beforeIX = z80.ix
        let beforeIY = z80.iy

        executeInstructions([0x00, 0x00, 0x00, 0x00])

        XCTAssertEqual(z80.af, beforeAF)
        XCTAssertEqual(z80.bc, beforeBC)
        XCTAssertEqual(z80.de, beforeDE)
        XCTAssertEqual(z80.hl, beforeHL)
        XCTAssertEqual(z80.ix, beforeIX)
        XCTAssertEqual(z80.iy, beforeIY)

        XCTAssertEqual(z80.pc, 0xa004)
    }

    func testLD_H_E()
    {
        z80.h = 0x8a
        z80.e = 0x10
        executeInstructions([0x63])
        XCTAssertEqual(z80.h, 0x10)
        XCTAssertEqual(z80.e, 0x10)
    }

    func testLD_R_N()
    { // LD r, r'
        executeInstructions([0x1e, 0xa5])
        XCTAssertEqual(z80.e, 0xa5)
    }

    func testLD_R_HL()
    { // LD r, (HL)
        poke(0x75a1, 0x58)
        z80.hl = 0x75a1
        executeInstructions([0x4e])
        XCTAssertEqual(z80.c, 0x58)
    }

    func testLD_R_IXd()
    { // LD r, (IX+d)
        z80.ix = 0x25af
        poke(0x25c8, 0x39)
        executeInstructions([0xdd, 0x46, 0x19])
        XCTAssertEqual(z80.b, 0x39)
    }

    func testLD_R_IYd()
    { // LD r, (IY+d)
        z80.iy = 0x25af
        poke(0x25c8, 0x39)
        executeInstructions([0xfd, 0x46, 0x19])
        XCTAssertEqual(z80.b, 0x39)
    }

    func testLD_HL_R() // LD (HL), r
    {
        z80.hl = 0x2146
        z80.b = 0x29
        executeInstructions([0x70])
        XCTAssertEqual(peek(0x2146), 0x29)
    }

    func testLD_IXd_r() // LD (IX+d), r
    {
        z80.c = 0x1c
        z80.ix = 0x3100
        executeInstructions([0xdd, 0x71, 0x06])
        XCTAssertEqual(peek(0x3106), 0x1c)
    }

    func testLD_IYd_r() // LD (IY+d), r
    {
        z80.c = 0x48
        z80.iy = 0x2a11
        executeInstructions([0xfd, 0x71, 0x04])
        XCTAssertEqual(peek(0x2a15), 0x48)
    }

    func testLD_HL_N() // LD (HL), n
    {
        z80.hl = 0x4444
        executeInstructions([0x36, 0x28])
        XCTAssertEqual(peek(0x4444), 0x28)
    }

    func testLD_IXd_N() // LD (IX+d), n
    {
        z80.ix = 0x219a
        executeInstructions([0xdd, 0x36, 0x05, 0x5a])
        XCTAssertEqual(peek(0x219f), 0x5a)
    }

    func testLD_IYd_N() // LD (IY+d), n
    {
        z80.iy = 0xa940
        executeInstructions([0xfd, 0x36, 0x10, 0x97])
        XCTAssertEqual(peek(0xa950), 0x97)
    }

    func testLD_A_BC() // LD A, (BC)
    {
        z80.bc = 0x4747
        poke(0x4747, 0x12)
        executeInstructions([0x0a])
        XCTAssertEqual(z80.a, 0x12)
    }

    func testLD_A_DE() // LD A, (DE)
    {
        z80.de = 0x30a2
        poke(0x30a2, 0x22)
        executeInstructions([0x1a])
        XCTAssertEqual(z80.a, 0x22)
    }

    func testLD_A_NN() // LD A, (nn)
    {
        poke(0x8832, 0x04)
        executeInstructions([0x3a, 0x32, 0x88])
        XCTAssertEqual(z80.a, 0x04)
    }

    func testLD_BC_A() // LD (BC), A
    {
        z80.a = 0x7a
        z80.bc = 0x1212
        executeInstructions([0x02])
        XCTAssertEqual(peek(0x1212), 0x7a)
    }

    func testLD_DE_A() // LD (DE), A
    {
        z80.de = 0x1128
        z80.a = 0xa0
        executeInstructions([0x12])
        XCTAssertEqual(peek(0x1128), 0xa0)
    }

    func testLD_NN_A() // LD (NN), A
    {
        z80.a = 0xd7
        executeInstructions([0x32, 0x41, 0x31])
        XCTAssertEqual(peek(0x3141), 0xd7)
    }

    func testLD_A_I() // LD A, I
    {
        let oldCarry = z80.flags.contains(.c)
        z80.i = 0xfe
        executeInstructions([0xed, 0x57])
        XCTAssertEqual(z80.a, 0xfe)
        XCTAssertEqual(z80.i, 0xfe)
        XCTAssertEqual(z80.flags.contains(.s), true)
        XCTAssertEqual(z80.flags.contains(.z), false)
        XCTAssertEqual(z80.flags.contains(.h), false)
        XCTAssertEqual(z80.flags.contains(.pv), z80.iff2)
        XCTAssertEqual(z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldCarry)
    }

    func testLD_A_R() // LD A, R
    {
        let oldCarry = z80.flags.contains(.c)
        z80.r = 0x07
        executeInstructions([0xed, 0x5f])
        XCTAssertEqual(z80.a, 0x09)
        XCTAssertEqual(z80.r, 0x0a)
        XCTAssertEqual(z80.flags.contains(.s), false)
        XCTAssertEqual(z80.flags.contains(.z), false)
        XCTAssertEqual(z80.flags.contains(.h), false)
        XCTAssertEqual(z80.flags.contains(.pv), z80.iff2)
        XCTAssertEqual(z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldCarry)
    }

    func testLD_I_A() // LD I, A
    {
        z80.a = 0x5c
        executeInstructions([0xed, 0x47])
        XCTAssertEqual(z80.i, 0x5c)
        XCTAssertEqual(z80.a, 0x5c)
    }

    func testLD_R_A() // LD R, A
    {
        z80.a = 0xde
        executeInstructions([0xed, 0x4f])
        XCTAssertEqual(z80.r, 0xdf)
        XCTAssertEqual(z80.a, 0xde)
    }

    func testLD_DD_NN() // LD dd, nn
    {
        executeInstructions([0x21, 0x00, 0x50])
        XCTAssertEqual(z80.hl, 0x5000)
        XCTAssertEqual(z80.h, 0x50)
        XCTAssertEqual(z80.l, 0x00)
    }

    func testLD_IX_NN() // LD IX, nn
    {
        executeInstructions([0xdd, 0x21, 0xa2, 0x45])
        XCTAssertEqual(z80.ix, 0x45a2)
    }

    func testLD_IY_NN() // LD IY, nn
    {
        executeInstructions([0xfd, 0x21, 0x33, 0x77])
        XCTAssertEqual(z80.iy, 0x7733)
    }

    func testLD_HL_NN1() // LD HL, (nn)
    {
        poke(0x4545, 0x37)
        poke(0x4546, 0xa1)
        executeInstructions([0x2a, 0x45, 0x45])
        XCTAssertEqual(z80.hl, 0xa137)
    }

    func testLD_HL_NN2()
    {
        poke(0x8abc, 0x84)
        poke(0x8abd, 0x89)
        executeInstructions([0x2a, 0xbc, 0x8a])
        XCTAssertEqual(z80.hl, 0x8984)
    }

    func testLD_DD_pNN() // LD dd, (nn)
    {
        poke(0x2130, 0x65)
        poke(0x2131, 0x78)
        executeInstructions([0xed, 0x4b, 0x30, 0x21])
        XCTAssertEqual(z80.bc, 0x7865)
    }

    func testLD_IX_pNN() // LD IX, (nn)
    {
        poke(0x6666, 0x92)
        poke(0x6667, 0xda)
        executeInstructions([0xdd, 0x2a, 0x66, 0x66])
        XCTAssertEqual(z80.ix, 0xda92)
    }

    func testLD_IY_pNN() // LD IY, (nn)
    {
        poke(0xf532, 0x11)
        poke(0xf533, 0x22)
        executeInstructions([0xfd, 0x2a, 0x32, 0xf5])
        XCTAssertEqual(z80.iy, 0x2211)
    }

    func testLD_pNN_HL() // LD (nn), HL
    {
        z80.hl = 0x483a
        executeInstructions([0x22, 0x29, 0xb2])
        XCTAssertEqual(peek(0xb229), 0x3a)
        XCTAssertEqual(peek(0xb22a), 0x48)
    }

    func testLD_pNN_DD() // LD (nn), DD
    {
        z80.bc = 0x4644
        executeInstructions([0xed, 0x43, 0x00, 0x10])
        XCTAssertEqual(peek(0x1000), 0x44)
        XCTAssertEqual(peek(0x1001), 0x46)
    }

    func testLD_pNN_IX() // LD (nn), IX
    {
        z80.ix = 0x5a30
        executeInstructions([0xdd, 0x22, 0x92, 0x43])
        XCTAssertEqual(peek(0x4392), 0x30)
        XCTAssertEqual(peek(0x4393), 0x5a)
    }

    func testLD_pNN_IY() // LD (nn), IY
    {
        z80.iy = 0x4174
        executeInstructions([0xfd, 0x22, 0x38, 0x88])
        XCTAssertEqual(peek(0x8838), 0x74)
        XCTAssertEqual(peek(0x8839), 0x41)
    }

    func testLD_SP_HL() // LD SP, HL
    {
        z80.hl = 0x442e
        executeInstructions([0xf9])
        XCTAssertEqual(z80.sp, 0x442e)
    }

    func testLD_SP_IX() // LD SP, IX
    {
        z80.ix = 0x98da
        executeInstructions([0xdd, 0xf9])
        XCTAssertEqual(z80.sp, 0x98da)
    }

    func testLD_SP_IY() // LD SP, IY
    {
        z80.iy = 0xa227
        executeInstructions([0xfd, 0xf9])
        XCTAssertEqual(z80.sp, 0xa227)
    }

    func testPUSH_qq() // PUSH qq
    {
        z80.af = 0x2233
        z80.sp = 0x1007
        executeInstructions([0xf5])
        XCTAssertEqual(peek(0x1006), 0x22)
        XCTAssertEqual(peek(0x1005), 0x33)
        XCTAssertEqual(z80.sp, 0x1005)
    }

    func testPUSH_IX() // PUSH IX
    {
        z80.ix = 0x2233
        z80.sp = 0x1007
        executeInstructions([0xdd, 0xe5])
        XCTAssertEqual(peek(0x1006), 0x22)
        XCTAssertEqual(peek(0x1005), 0x33)
        XCTAssertEqual(z80.sp, 0x1005)
    }

    func testPUSH_IY() // PUSH IY
    {
        z80.iy = 0x2233
        z80.sp = 0x1007
        executeInstructions([0xfd, 0xe5])
        XCTAssertEqual(peek(0x1006), 0x22)
        XCTAssertEqual(peek(0x1005), 0x33)
        XCTAssertEqual(z80.sp, 0x1005)
    }

    func testPOP_qq() // POP qq
    {
        z80.sp = 0x1000
        poke(0x1000, 0x55)
        poke(0x1001, 0x33)
        executeInstructions([0xe1])
        XCTAssertEqual(z80.hl, 0x3355)
        XCTAssertEqual(z80.sp, 0x1002)
    }

    func testPOP_IX() // POP IX
    {
        z80.sp = 0x1000
        poke(0x1000, 0x55)
        poke(0x1001, 0x33)
        executeInstructions([0xdd, 0xe1])
        XCTAssertEqual(z80.ix, 0x3355)
        XCTAssertEqual(z80.sp, 0x1002)
    }

    func testPOP_IY() // POP IY
    {
        z80.sp = 0x8fff
        poke(0x8fff, 0xff)
        poke(0x9000, 0x11)
        executeInstructions([0xfd, 0xe1])
        XCTAssertEqual(z80.iy, 0x11ff)
        XCTAssertEqual(z80.sp, 0x9001)
    }

    func testEX_DE_HL() // EX DE, HL
    {
        z80.de = 0x2822
        z80.hl = 0x499a
        executeInstructions([0xeb])
        XCTAssertEqual(z80.hl, 0x2822)
        XCTAssertEqual(z80.de, 0x499a)
    }

    func testEX_AF_AF() // EX AF, AF'
    {
        z80.af = 0x9900
        z80.af_ = 0x5944
        executeInstructions([0x08])
        XCTAssertEqual(z80.af_, 0x9900)
        XCTAssertEqual(z80.af, 0x5944)
    }

    func testEXX() // EXX
    {
        z80.af = 0x1234
        z80.af_ = 0x4321
        z80.bc = 0x445a
        z80.de = 0x3da2
        z80.hl = 0x8859
        z80.bc_ = 0x0988
        z80.de_ = 0x9300
        z80.hl_ = 0x00e7
        executeInstructions([0xd9])
        XCTAssertEqual(z80.bc, 0x0988)
        XCTAssertEqual(z80.de, 0x9300)
        XCTAssertEqual(z80.hl, 0x00e7)
        XCTAssertEqual(z80.bc_, 0x445a)
        XCTAssertEqual(z80.de_, 0x3da2)
        XCTAssertEqual(z80.hl_, 0x8859)
        XCTAssertEqual(z80.af, 0x1234) // unchanged
        XCTAssertEqual(z80.af_, 0x4321) // unchanged
    }

    func testEX_SP_HL() // EX (SP), HL
    {
        z80.hl = 0x7012
        z80.sp = 0x8856
        poke(0x8856, 0x11)
        poke(0x8857, 0x22)
        executeInstructions([0xe3])
        XCTAssertEqual(z80.hl, 0x2211)
        XCTAssertEqual(peek(0x8856), 0x12)
        XCTAssertEqual(peek(0x8857), 0x70)
        XCTAssertEqual(z80.sp, 0x8856)
    }

    func testEX_SP_IX() // EX (SP), IX
    {
        z80.ix = 0x3988
        z80.sp = 0x0100
        poke(0x0100, 0x90)
        poke(0x0101, 0x48)
        executeInstructions([0xdd, 0xe3])
        XCTAssertEqual(z80.ix, 0x4890)
        XCTAssertEqual(peek(0x0100), 0x88)
        XCTAssertEqual(peek(0x0101), 0x39)
        XCTAssertEqual(z80.sp, 0x0100)
    }

    func testEX_SP_IY() // EX (SP), IY
    {
        z80.iy = 0x3988
        z80.sp = 0x0100
        poke(0x0100, 0x90)
        poke(0x0101, 0x48)
        executeInstructions([0xfd, 0xe3])
        XCTAssertEqual(z80.iy, 0x4890)
        XCTAssertEqual(peek(0x0100), 0x88)
        XCTAssertEqual(peek(0x0101), 0x39)
        XCTAssertEqual(z80.sp, 0x0100)
    }

    func testLDI() // LDI
    {
        z80.hl = 0x1111
        poke(0x1111, 0x88)
        z80.de = 0x2222
        poke(0x2222, 0x66)
        z80.bc = 0x07
        executeInstructions([0xed, 0xa0])
        XCTAssertEqual(z80.hl, 0x1112)
        XCTAssertEqual(peek(0x1111), 0x88)
        XCTAssertEqual(z80.de, 0x2223)
        XCTAssertEqual(peek(0x2222), 0x88)
        XCTAssertEqual(z80.bc, 0x06)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
        XCTAssertTrue(z80.flags.contains(.pv))
    }

    func testLDIR() // LDIR
    {
        z80.hl = 0x1111
        z80.de = 0x2222
        z80.bc = 0x0003
        poke(0x1111, 0x88)
        poke(0x1112, 0x36)
        poke(0x1113, 0xa5)
        poke(0x2222, 0x66)
        poke(0x2223, 0x59)
        poke(0x2224, 0xc5)
        executeInstructions([0xed, 0xb0])
        XCTAssertEqual(z80.hl, 0x1114)
        XCTAssertEqual(z80.de, 0x2225)
        XCTAssertEqual(z80.bc, 0x0000)
        XCTAssertEqual(peek(0x1111), 0x88)
        XCTAssertEqual(peek(0x1112), 0x36)
        XCTAssertEqual(peek(0x1113), 0xa5)
        XCTAssertEqual(peek(0x2222), 0x88)
        XCTAssertEqual(peek(0x2223), 0x36)
        XCTAssertEqual(peek(0x2224), 0xa5)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n), false)
    }

    func testLDD() // LDD
    {
        z80.hl = 0x1111
        poke(0x1111, 0x88)
        z80.de = 0x2222
        poke(0x2222, 0x66)
        z80.bc = 0x07
        executeInstructions([0xed, 0xa8])
        XCTAssertEqual(z80.hl, 0x1110)
        XCTAssertEqual(peek(0x1111), 0x88)
        XCTAssertEqual(z80.de, 0x2221)
        XCTAssertEqual(peek(0x2222), 0x88)
        XCTAssertEqual(z80.bc, 0x06)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.pv), true)
    }

    func testLDDR() // LDDR
    {
        z80.hl = 0x1114
        z80.de = 0x2225
        z80.bc = 0x0003
        poke(0x1114, 0xa5)
        poke(0x1113, 0x36)
        poke(0x1112, 0x88)
        poke(0x2225, 0xc5)
        poke(0x2224, 0x59)
        poke(0x2223, 0x66)
        executeInstructions([0xed, 0xb8])
        XCTAssertEqual(z80.hl, 0x1111)
        XCTAssertEqual(z80.de, 0x2222)
        XCTAssertEqual(z80.bc, 0x0000)
        XCTAssertEqual(peek(0x1114), 0xa5)
        XCTAssertEqual(peek(0x1113), 0x36)
        XCTAssertEqual(peek(0x1112), 0x88)
        XCTAssertEqual(peek(0x2225), 0xa5)
        XCTAssertEqual(peek(0x2224), 0x36)
        XCTAssertEqual(peek(0x2223), 0x88)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n), false)
    }

    func testCPI() // CPI
    {
        z80.hl = 0x1111
        poke(0x1111, 0x3b)
        z80.a = 0x3b
        z80.bc = 0x0001
        executeInstructions([0xed, 0xa1])
        XCTAssertEqual(z80.bc, 0x0000)
        XCTAssertEqual(z80.hl, 0x1112)
        XCTAssertEqual(z80.flags.contains(.z), true)
        XCTAssertEqual(z80.flags.contains(.pv), false)
        XCTAssertEqual(z80.a, 0x3b)
        XCTAssertEqual(peek(0x1111), 0x3b)
    }

    func testCPIR() // CPIR
    {
        z80.hl = 0x1111
        z80.a = 0xf3
        z80.bc = 0x0007
        poke(0x1111, 0x52)
        poke(0x1112, 0x00)
        poke(0x1113, 0xf3)
        executeInstructions([0xed, 0xb1])
        XCTAssertEqual(z80.hl, 0x1114)
        XCTAssertEqual(z80.bc, 0x0004)
        XCTAssertEqual(z80.flags.contains(.pv) && z80.flags.contains(.z), true)
    }

    func testCPD() // CPD
    {
        z80.hl = 0x1111
        poke(0x1111, 0x3b)
        z80.a = 0x3b
        z80.bc = 0x0001
        executeInstructions([0xed, 0xa9])
        XCTAssertEqual(z80.hl, 0x1110)
        XCTAssertEqual(z80.flags.contains(.z), true)
        XCTAssertEqual(z80.flags.contains(.pv), false)
        XCTAssertEqual(z80.a, 0x3b)
        XCTAssertEqual(peek(0x1111), 0x3b)
    }

    func testCPDR() // CPDR
    {
        z80.hl = 0x1118
        z80.a = 0xf3
        z80.bc = 0x0007
        poke(0x1118, 0x52)
        poke(0x1117, 0x00)
        poke(0x1116, 0xf3)
        executeInstructions([0xed, 0xb9])
        XCTAssertEqual(z80.hl, 0x1115)
        XCTAssertEqual(z80.bc, 0x0004)
        XCTAssertEqual(z80.flags.contains(.pv) && z80.flags.contains(.z), true)
    }

    func testADD_A_r() // ADD A, r
    {
        z80.a = 0x44
        z80.c = 0x11
        executeInstructions([0x81])
        XCTAssertEqual(z80.flags.contains(.h), false)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c), false)
    }

    func testADD_A_n() // ADD A, n
    {
        z80.a = 0x23
        executeInstructions([0xc6, 0x33])
        XCTAssertEqual(z80.a, 0x56)
        XCTAssertEqual(z80.flags.contains(.h), false)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.n) || z80.flags.contains(.pv) || z80.flags.contains(.c), false)
    }

    func testADD_A_pHL() // ADD A, (HL)
    {
        z80.a = 0xa0
        z80.hl = 0x2323
        poke(0x2323, 0x08)
        executeInstructions([0x86])
        XCTAssertEqual(z80.a, 0xa8)
        XCTAssertEqual(z80.flags.contains(.s), true)
        XCTAssertEqual(z80.flags.contains(.z) || z80.flags.contains(.c) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.h), false)
    }

    func testADD_A_IXd() // ADD A, (IX + d)
    {
        z80.a = 0x11
        z80.ix = 0x1000
        poke(0x1005, 0x22)
        executeInstructions([0xdd, 0x86, 0x05])
        XCTAssertEqual(z80.a, 0x33)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c),
                       false)
    }

    func testADD_A_IYd() // ADD A, (IY + d)
    {
        z80.a = 0x11
        z80.iy = 0x1000
        poke(0x1005, 0x22)
        executeInstructions([0xfd, 0x86, 0x05])
        XCTAssertEqual(z80.a, 0x33)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c),
                       false)
    }

    func testADC_A_pHL() // ADC A, (HL)
    {
        z80.a = 0x16
        z80.flags.insert(.c)
        z80.hl = 0x6666
        poke(0x6666, 0x10)
        executeInstructions([0x8e])
        XCTAssertEqual(z80.a, 0x27)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c),
                       false)
    }

    func testSUB_D() // SUB D
    {
        z80.a = 0x29
        z80.d = 0x11
        executeInstructions([0x92])
        XCTAssertEqual(z80.a, 0x18)
        XCTAssertEqual(z80.flags.contains(.n), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.c), false)
    }

    func testSBC_pHL() // SBC A, (HL)
    {
        z80.a = 0x16
        z80.flags.insert(.c)
        z80.hl = 0x3433
        poke(0x3433, 0x05)
        executeInstructions([0x9e])
        XCTAssertEqual(z80.a, 0x10)
        XCTAssertEqual(z80.flags.contains(.n), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.c), false)
    }

    func testAND_s() // AND s
    {
        z80.b = 0x7b
        z80.a = 0xc3
        executeInstructions([0xa0])
        XCTAssertEqual(z80.a, 0x43)
        XCTAssertEqual(z80.flags.contains(.h), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c), false)
    }

    func testOR_s() // OR s
    {
        z80.h = 0x48
        z80.a = 0x12
        executeInstructions([0xb4])
        XCTAssertEqual(z80.a, 0x5a)
        XCTAssertEqual(z80.flags.contains(.pv), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.n) || z80.flags.contains(.c), false)
    }

    func testXOR_s() // XOR s
    {
        z80.a = 0x96
        executeInstructions([0xee, 0x5d])
        XCTAssertEqual(z80.a, 0xcb)
        XCTAssertEqual(z80.flags.contains(.s), true)
        XCTAssertEqual(z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n) || z80.flags.contains(.c), false)
    }

    func testCP_s() // CP s
    {
        z80.a = 0x63
        z80.hl = 0x6000
        poke(0x6000, 0x60)
        executeInstructions([0xbe])
        XCTAssertEqual(z80.flags.contains(.n), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.c), false)
    }

    func testINC_s() // INC s
    {
        let oldC = z80.flags.contains(.c)
        z80.d = 0x28
        executeInstructions([0x14])
        XCTAssertEqual(z80.d, 0x29)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldC)
    }

    func testINC_pHL() // INC (HL)
    {
        let oldC = z80.flags.contains(.c)
        z80.hl = 0x3434
        poke(0x3434, 0x7f)
        executeInstructions([0x34])
        XCTAssertEqual(peek(0x3434), 0x80)
        XCTAssertEqual(z80.flags.contains(.pv) && z80.flags.contains(.s) && z80.flags.contains(.h), true)
        XCTAssertEqual(z80.flags.contains(.z) || z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldC)
    }

    func testINC_pIXd() // INC (IX+d)
    {
        let oldC = z80.flags.contains(.c)
        z80.ix = 0x2020
        poke(0x2030, 0x34)
        executeInstructions([0xdd, 0x34, 0x10])
        XCTAssertEqual(peek(0x2030), 0x35)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldC)
    }

    func testINC_pIYd() // INC (IY+d)
    {
        let oldC = z80.flags.contains(.c)
        z80.iy = 0x2020
        poke(0x2030, 0x34)
        executeInstructions([0xfd, 0x34, 0x10])
        XCTAssertEqual(peek(0x2030), 0x35)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv) || z80.flags.contains(.n), false)
        XCTAssertEqual(z80.flags.contains(.c), oldC)
    }

    func testDEC_m() // DEC m
    {
        let oldC = z80.flags.contains(.c)
        z80.d = 0x2a
        executeInstructions([0x15])
        XCTAssertEqual(z80.flags.contains(.n), true)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.h) || z80.flags.contains(.pv), false)
        XCTAssertEqual(z80.flags.contains(.c), oldC)
    }

    func testDAA() // DAA
    {
        z80.a = 0x0e
        z80.b = 0x0f
        z80.c = 0x90
        z80.d = 0x40

        // AND 0x0F; ADD A, 0x90; DAA; ADC A 0x40; DAA
        executeInstructions([0xa0, 0x81, 0x27, 0x8a, 0x27])

        XCTAssertEqual(z80.a, 0x45)
    }

    func testCPL() // CPL
    {
        z80.a = 0xb4
        executeInstructions([0x2f])
        XCTAssertEqual(z80.a, 0x4b)
        XCTAssertEqual(z80.flags.contains(.h) && z80.flags.contains(.n), true)
    }

    func testNEG() // NEG
    {
        z80.a = 0x98
        executeInstructions([0xed, 0x44])
        XCTAssertEqual(z80.a, 0x68)
        XCTAssertEqual(z80.flags.contains(.s) || z80.flags.contains(.z) || z80.flags.contains(.pv), false)
        XCTAssertEqual(z80.flags.contains(.n) && z80.flags.contains(.c) && z80.flags.contains(.h), true)
    }

    func testCCF() // CCF
    {
        z80.flags.insert(.n)
        z80.flags.insert(.c)
        executeInstructions([0x3f])
        XCTAssertEqual(z80.flags.contains(.c) || z80.flags.contains(.n), false)
    }

    func testSCF() // SCF
    {
        z80.flags.remove(.c)
        z80.flags.insert(.h)
        z80.flags.insert(.n)
        executeInstructions([0x37])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
    }

    func testDI() // DI
    {
        z80.iff1 = true
        z80.iff2 = true
        executeInstructions([0xf3])
        XCTAssertEqual(z80.iff1 || z80.iff2, false)
    }

    func testEI() // DI
    {
        z80.iff1 = true
        z80.iff2 = true
        executeInstructions([0xf3])
        XCTAssertEqual(z80.iff1 || z80.iff2, false)
    }

    func testADD_HL_ss() // ADD HL, ss
    {
        z80.hl = 0x4242
        z80.de = 0x1111
        executeInstructions([0x19])
        XCTAssertEqual(z80.hl, 0x5353)
    }

    func testADC_HL_ss() // ADD HL, ss
    {
        z80.bc = 0x2222
        z80.hl = 0x5437
        z80.flags.insert(.c)
        executeInstructions([0xed, 0x4a])
        XCTAssertEqual(z80.hl, 0x765a)
    }

    func testSBC_HL_ss() // SBC HL, ss
    {
        z80.hl = 0x9999
        z80.de = 0x1111
        z80.flags.insert(.c)
        executeInstructions([0xed, 0x52])
        XCTAssertEqual(z80.hl, 0x8887)
    }

    func testADD_IX_pp() // ADD IX, pp
    {
        z80.ix = 0x3333
        z80.bc = 0x5555
        executeInstructions([0xdd, 0x09])
        XCTAssertEqual(z80.ix, 0x8888)
    }

    func testADD_IY_pp() // ADD IY, rr
    {
        z80.iy = 0x3333
        z80.bc = 0x5555
        executeInstructions([0xfd, 0x09])
        XCTAssertEqual(z80.iy, 0x8888)
    }

    func testINC_ss() // INC ss
    {
        z80.hl = 0x1000
        executeInstructions([0x23])
        XCTAssertEqual(z80.hl, 0x1001)
    }

    func testINC_IX() // INC IX
    {
        z80.ix = 0x3300
        executeInstructions([0xdd, 0x23])
        XCTAssertEqual(z80.ix, 0x3301)
    }

    func testINC_IY() // INC IY
    {
        z80.iy = 0x2977
        executeInstructions([0xfd, 0x23])
        XCTAssertEqual(z80.iy, 0x2978)
    }

    func testDEC_ss() // DEC ss
    {
        z80.hl = 0x1001
        executeInstructions([0x2b])
        XCTAssertEqual(z80.hl, 0x1000)
    }

    func testDEC_IX() // DEC IX
    {
        z80.ix = 0x2006
        executeInstructions([0xdd, 0x2b])
        XCTAssertEqual(z80.ix, 0x2005)
    }

    func testDEC_IY() // DEC IY
    {
        z80.iy = 0x7649
        executeInstructions([0xfd, 0x2b])
        XCTAssertEqual(z80.iy, 0x7648)
    }

    func testRLCA() // RLCA
    {
        z80.a = 0x88
        executeInstructions([0x07])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.a, 0x11)
    }

    func testRLA() // RLA
    {
        z80.flags.insert(.c)
        z80.a = 0x76
        executeInstructions([0x17])
        XCTAssertEqual(z80.flags.contains(.c), false)
        XCTAssertEqual(z80.a, 0xed)
    }

    func testRRCA() // RRCA
    {
        z80.a = 0x11
        executeInstructions([0x0f])
        XCTAssertEqual(z80.a, 0x88)
        XCTAssertEqual(z80.flags.contains(.c), true)
    }

    func testRRA() // RRA
    {
        z80.flags.insert(.h)
        z80.flags.insert(.n)
        z80.a = 0xe1
        z80.flags.remove(.c)
        executeInstructions([0x1f])
        XCTAssertEqual(z80.a, 0x70)
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
    }

    func testRLC_r() // RLC r
    {
        z80.flags.insert(.h)
        z80.flags.insert(.n)
        z80.l = 0x88
        executeInstructions([0xcb, 0x05])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.l, 0x11)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
    }

    func testRLC_pHL() // RLC (HL)
    {
        z80.flags.insert(.h)
        z80.flags.insert(.n)
        z80.hl = 0x2828
        poke(0x2828, 0x88)
        executeInstructions([0xcb, 0x06])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(peek(0x2828), 0x11)
        XCTAssertEqual(z80.flags.contains(.h) || z80.flags.contains(.n), false)
    }

    func testRLC_pIXd() // RLC (IX+d)
    {
        z80.ix = 0x1000
        poke(0x1002, 0x88)
        executeInstructions([0xdd, 0xcb, 0x02, 0x06])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(peek(0x1002), 0x11)
    }

    func testRLC_pIYd() // RLC (IY+d)
    {
        z80.iy = 0x1000
        poke(0x1002, 0x88)
        executeInstructions([0xfd, 0xcb, 0x02, 0x06])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(peek(0x1002), 0x11)
    }

    func testRL_m() // RL m
    {
        z80.d = 0x8f
        z80.flags.remove(.c)
        executeInstructions([0xcb, 0x12])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.d, 0x1e)
    }

    func testRRC_m() // RRC m
    {
        z80.a = 0x31
        executeInstructions([0xcb, 0x0f])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.a, 0x98)
    }

    func testRR_m() // RR m
    {
        z80.hl = 0x4343
        poke(0x4343, 0xdd)
        z80.flags.remove(.c)
        executeInstructions([0xcb, 0x1e])
        XCTAssertEqual(peek(0x4343), 0x6e)
        XCTAssertEqual(z80.flags.contains(.c), true)
    }

    func testSLA_m() // SLA m
    {
        z80.l = 0xb1
        executeInstructions([0xcb, 0x25])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.l, 0x62)
    }

    func testSRA_m() // SRA m
    {
        z80.ix = 0x1000
        poke(0x1003, 0xb8)
        executeInstructions([0xdd, 0xcb, 0x03, 0x2e])
        XCTAssertEqual(z80.flags.contains(.c), false)
        XCTAssertEqual(peek(0x1003), 0xdc)
    }

    func testSRL_m() // SRL m
    {
        z80.b = 0x8f
        poke(0x1003, 0xb8)
        executeInstructions([0xcb, 0x38])
        XCTAssertEqual(z80.flags.contains(.c), true)
        XCTAssertEqual(z80.b, 0x47)
    }

    func testRLD() // RLD
    {
        z80.hl = 0x5000
        z80.a = 0x7a
        poke(0x5000, 0x31)
        executeInstructions([0xed, 0x6f])
        XCTAssertEqual(z80.a, 0x73)
        XCTAssertEqual(peek(0x5000), 0x1a)
    }

    func testRRD() // RRD
    {
        z80.hl = 0x5000
        z80.a = 0x84
        poke(0x5000, 0x20)
        executeInstructions([0xed, 0x67])
        XCTAssertEqual(z80.a, 0x80)
        XCTAssertEqual(peek(0x5000), 0x42)
    }

    func testBIT_b_r() // BIT b, r
    {
        z80.b = 0
        executeInstructions([0xcb, 0x50])
        XCTAssertEqual(z80.b, 0)
        XCTAssertEqual(z80.flags.contains(.z), true)
    }

    func testBIT_b_pHL() // BIT b, (HL)
    {
        z80.flags.insert(.z)
        z80.hl = 0x4444
        poke(0x4444, 0x10)
        executeInstructions([0xcb, 0x66])
        XCTAssertEqual(z80.flags.contains(.z), false)
        XCTAssertEqual(peek(0x4444), 0x10)
    }

    func testBIT_b_pIXd() // BIT b, (IX+d)
    {
        z80.flags.insert(.z)
        z80.ix = 0x2000
        poke(0x2004, 0xd2)
        executeInstructions([0xdd, 0xcb, 0x04, 0x76])
        XCTAssertEqual(z80.flags.contains(.z), false)
        XCTAssertEqual(peek(0x2004), 0xd2)
    }

    func testBIT_b_pIYd() // BIT b, (IY+d)
    {
        z80.flags.insert(.z)
        z80.iy = 0x2000
        poke(0x2004, 0xd2)
        executeInstructions([0xfd, 0xcb, 0x04, 0x76])
        XCTAssertEqual(z80.flags.contains(.z), false)
        XCTAssertEqual(peek(0x2004), 0xd2)
    }

    func testSET_b_r() // SET b, r
    {
        z80.a = 0
        executeInstructions([0xcb, 0xe7])
        XCTAssertEqual(z80.a, 0x10)
    }

    func testSET_b_pHL() // SET b, (HL)
    {
        z80.hl = 0x3000
        poke(0x3000, 0x2f)
        executeInstructions([0xcb, 0xe6])
        XCTAssertEqual(peek(0x3000), 0x3f)
    }

    func testSET_b_pIXd() // SET b, (IX+d)
    {
        z80.ix = 0x2000
        poke(0x2003, 0xf0)
        executeInstructions([0xdd, 0xcb, 0x03, 0xc6])
        XCTAssertEqual(peek(0x2003), 0xf1)
    }

    func testSET_b_pIYd() // SET b, (IY+d)
    {
        z80.iy = 0x2000
        poke(0x2003, 0x38)
        executeInstructions([0xfd, 0xcb, 0x03, 0xc6])
        XCTAssertEqual(peek(0x2003), 0x39)
    }

    func testRES_b_m() // RES b, m
    {
        z80.d = 0xff
        executeInstructions([0xcb, 0xb2])
        XCTAssertEqual(z80.d, 0xbf)
    }
}
