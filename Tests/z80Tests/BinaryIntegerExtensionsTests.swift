//
//  BinaryIntegerExtensionsTests.swift
//  
//
//  Created by Tim Sneath on 6/11/23.
//

import XCTest
@testable import z80

final class BinaryIntegerExtensionsTests: XCTestCase {
    func testTwosComplement() {
        XCTAssertEqual(UInt8(0).twosComplement, 0)
        XCTAssertEqual(UInt8(0xFF).twosComplement, -1)
        XCTAssertEqual(UInt8(0x7F).twosComplement, 127)
        XCTAssertEqual(UInt8(0x80).twosComplement, -128)
        XCTAssertEqual(UInt8(129).twosComplement, -127)
    }

}
