//
//  DisassemblerTests.swift
//  
//
//  Created by Tim Sneath on 6/15/23.
//

import XCTest
@testable import z80

final class DisassemblerTests: XCTestCase {
    func testSingleByteOpcode() {
        let instruction = Disassembler.disassembleInstruction([0x48])
        XCTAssertEqual(instruction.byteCode, "48")
        XCTAssertEqual(instruction.length, 1)
        XCTAssertEqual(instruction.disassembly, "LD C, B")
    }
    
    func testDoubleByteOpcode() {
        let instruction = Disassembler.disassembleInstruction([0xDD, 0x23])
        XCTAssertEqual(instruction.byteCode, "dd 23")
        XCTAssertEqual(instruction.length, 2)
        XCTAssertEqual(instruction.disassembly, "INC IX")
    }
    
    func testTripleByteOpcode() {
        let instruction = Disassembler.disassembleInstruction([0xFD, 0xB6, 0xFE])
        XCTAssertEqual(instruction.byteCode, "fd b6 fe")
        XCTAssertEqual(instruction.length, 3)
        XCTAssertEqual(instruction.disassembly, "OR (IY+FE)")
    }
    
    func testQuadrupleByteOpcode() {
        let instruction = Disassembler.disassembleInstruction([0xFD, 0xCB, 0x07, 0x28])
        XCTAssertEqual(instruction.byteCode, "fd cb 07 28")
        XCTAssertEqual(instruction.length, 4)
        XCTAssertEqual(instruction.disassembly, "SRA (IY+07), B")
    }
    
    func testMultipleInstructionDisassembly() {
        let binary : [UInt8] = [0xDD, 0x23, 0xFD, 0xCB, 0x07, 0x28, 0x48]
        let disassembly = Disassembler.disassembleMultipleInstructions(
            instructions: binary, count: 3, pc: 0x100)
        XCTAssertEqual(disassembly, """
[0100]  dd 23        INC IX
[0102]  fd cb 07 28  SRA (IY+07), B
[0106]  48           LD C, B

""")
    }
}
