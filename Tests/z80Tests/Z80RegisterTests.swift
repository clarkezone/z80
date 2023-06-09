import XCTest
@testable import z80

final class Z80RegisterTests: XCTestCase {
    func testBCRegisters() {
        var z80 = Z80()
        z80.b = 0x01
        z80.c = 0x00
        XCTAssertEqual(z80.bc, 0x0100)
        z80.bc = 0x1234
        XCTAssertEqual(z80.b, 0x12)
        XCTAssertEqual(z80.c, 0x34)
    }

    func testDERegisters() {
        var z80 = Z80()
        z80.d = 0xc2
        z80.e = 0xd3
        XCTAssertEqual(z80.de, 0xc2d3)
        z80.de = 0x1234
        XCTAssertEqual(z80.d, 0x12)
        XCTAssertEqual(z80.e, 0x34)
    }

    func testHLRegisters() {
        var z80 = Z80()
        z80.h = 0xe4
        z80.l = 0xf5
        XCTAssertEqual(z80.hl, 0xe4f5)
        z80.hl = 0x1234
        XCTAssertEqual(z80.h, 0x12)
        XCTAssertEqual(z80.l, 0x34)
    }

    func testAFRegisters() {
        var z80 = Z80()
        z80.a = 0x12
        z80.f = 0x34
        XCTAssertEqual(z80.af, 0x1234)
        z80.af = 0x4321
        XCTAssertEqual(z80.a, 0x43)
        XCTAssertEqual(z80.f, 0x21)
    }

    func testIXRegisters() {
        var z80 = Z80()
        z80.ix = 0
        z80.ixh = 0x24
        z80.ixl = 0x68
        XCTAssertEqual(z80.ix, 0x2468)
        z80.ix = 0x9876
        XCTAssertEqual(z80.ixh, 0x98)
        XCTAssertEqual(z80.ixl, 0x76)
    }

    func testIYRegisters() {
        var z80 = Z80()
        z80.iy = 0
        z80.iyh = 0x2a
        z80.iyl = 0x6b
        XCTAssertEqual(z80.iy, 0x2a6b)
        z80.iy = 0x9c7d
        XCTAssertEqual(z80.iyh, 0x9c)
        XCTAssertEqual(z80.iyl, 0x7d)
    }

    func testFlags() {
        var z80 = Z80()
        z80.a = 0
        z80.f = 0
        z80.flags = [.z, .c]
        XCTAssertEqual(z80.af, 0x0041)
        z80.flags.remove(.z)
        z80.flags.remove(.c)
        XCTAssertEqual(z80.af, 0x0000)
        z80.flags.insert(.pv)
        z80.a = 0x20
        XCTAssertEqual(z80.f, 0x04)
        XCTAssertEqual(z80.af, 0x2004)
    }
}
