//
//  StringExtensionsTests.swift
//  
//
//  Created by Tim Sneath on 6/12/23.
//

import XCTest
@testable import z80

final class StringExtensionsTests: XCTestCase {
    func testPadLeft() {
        XCTAssertEqual("foo".padLeft(toLength: 6, withPad: " "), "   foo")
        XCTAssertEqual(UInt8(0x0F).toBinary, "00001111")
        XCTAssertEqual(UInt16(0x0F0F).toBinary, "0000111100001111")
    }
    
    func testPadRight() {
        XCTAssertEqual("foo".padRight(toLength: 6), "foo   ")
        XCTAssertEqual("bar".padRight(toLength: 4, withPad: "_"), "bar_")
    }
}
