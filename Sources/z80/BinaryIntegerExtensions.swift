//
//  BinaryIntegerExtensions.swift
//
//
//  Created by Tim Sneath on 6/10/23.
//

extension BinaryInteger {
    /// Return true if a given bit is set in a binary integer.
    func isBitSet(_ bit: Int) -> Bool { (self & (1 << bit)) == 1 << bit }

    /// Set a given bit of a binary integer.
    mutating func setBit(_ bit: Int) { self |= (1 << bit) }

    /// Reset a given bit of a binary integer.
    mutating func resetBit(_ bit: Int) { self &= ~(1 << bit) }

    /// Return true if a given value is zero.
    func isZero() -> Bool { Int(self) == 0 }

    /// Return true if a given value is odd.
    func isOdd() -> Bool { self.isBitSet(0) }

    /// Return true if a given value is even.
    func isEven() -> Bool { !self.isOdd() }
    
    func isParity() -> Bool {
        // Algorithm for counting set bits taken from LLVM optimization proposal at:
        //    https://llvm.org/bugs/show_bug.cgi?id=1488
        var count = 0

        var v = self
        while(v != 0) {
            count += 1
            v &= v - 1 // clear the least significant bit set
        }
        return count % 2 == 0
    }
    
    /// Return true if this value would be negative if treated as a signed integer.
    func isSignedBitSet() -> Bool { self.isBitSet(self.bitWidth - 1) }

}

extension UInt16 {
    /// Extract the high byte of a 16-bit value, assuming little-endian representation.
    var highByte: UInt8 { UInt8((self & 0xFF00) >> 8) }

    /// Extract the low byte of a 16-bit value, assuming little-endian representation.
    var lowByte: UInt8 { UInt8(self & 0x00FF) }

    /// Create a new value from two bytes, assuming little-endian representation.
    static func createWord(_ highByte: UInt8, _ lowByte: UInt8) -> UInt16 {
        (UInt16(highByte) << 8) + UInt16(lowByte)
    }
}
