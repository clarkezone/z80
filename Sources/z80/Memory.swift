//
//  Memory.swift
//
//
//  Created by Tim Sneath on 6/8/23.
//

import Foundation

/// A general interface for contiguous memory space, as used in a microcomputer.
///
/// For a computer like a ZX Spectrum, with a 16-bit address space, the following will initialize the appropriate sized memory:
/// ```
/// Memory<UInt16>(sizeInBytes: 65536)
/// ```
///
/// Note that this structure does not directly address read-only memory that might be mapped into the space.
public struct Memory<AddressSize> where AddressSize : BinaryInteger {
    private var buffer : [UInt8]

    public init(sizeInBytes: Int) {
        buffer = Array(repeating: 0, count: sizeInBytes)
    }
    
    /// Resets or clears the memory address space.
    public mutating func reset() {
        for idx in 0 ..< buffer.count {
            buffer[idx] = 0
        }
    }
    
    /// Load a list of byte data into memory, starting at origin.
    public mutating func load(origin: AddressSize, data: [UInt8]) {
        for idx in 0 ..< data.count {
            buffer[Int(origin)+idx] = data[idx]
        }
    }
    
    /// Read a block of memory, starting at origin.
    public func read(origin: AddressSize, length: Int) -> ArraySlice<UInt8> {
        return buffer[Int(origin)...Int(origin)+length]
    }

    /// Read a single byte from the given memory location.
    public func readByte(_ addr: AddressSize) -> UInt8 { buffer[Int(addr)] }
    
    /// Read a single word from the given memory location.
    public func readWord(_ addr: AddressSize) -> UInt16 {
        UInt16.formWord(buffer[Int(addr)+1], buffer[Int(addr)])
    }

    /// Write a single byte to the given memory location.
    public mutating func writeByte(_ addr: AddressSize, _ value: UInt8) {
        buffer[Int(addr)] = value
    }
    
    /// Write a single word to the given memory location.
    public mutating func writeWord(_ addr: AddressSize, _ value: UInt16) {
        buffer[Int(addr)] = value.lowByte
        buffer[Int(addr)+1] = value.highByte
    }
}

// TODO: Add ROM mapping
