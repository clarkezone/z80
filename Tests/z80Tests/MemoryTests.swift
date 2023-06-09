import XCTest
@testable import z80

final class MemoryTests: XCTestCase {
    func testMemoryInit() {
        let memory = Memory<UInt16>(sizeInBytes: 65536)
        XCTAssertEqual(memory.readByte(0),0)
        XCTAssertEqual(memory.readByte(65535), 0)
    }
    
    func testMemoryPokePeek() {
        var memory = Memory<UInt16>(sizeInBytes: 65536)
        memory.writeByte(32767, 0xFF)
        XCTAssertEqual(memory.readByte(32767),0xFF)
    }
}
