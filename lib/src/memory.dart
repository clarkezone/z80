import 'dart:typed_data';

import 'utility.dart';

/// A general interface for contiguous memory space, as used in a microcomputer
/// like the ZX Spectrum or TRS-80.
///
/// An actual computer implementation may extend this with a specific
/// implementation that includes a fixed memory space, and probably some notion
/// of a read-only ROM storage area.

abstract class MemoryBase {
  /// Load a list of byte data into memory, starting at origin.
  void load(int origin, Iterable<int> data);

  /// Read a block of memory, starting at origin.
  Uint8List read(int origin, int length);

  /// Read a single byte from the given memory location.
  int readByte(int address);

  /// Read a single word from the given memory location.
  int readWord(int address);

  /// Resets or clears the memory address space.
  void reset();

  /// Write a single byte to the given memory location.
  void writeByte(int address, int value);

  /// Write a single word to the given memory location.
  void writeWord(int address, int value);
}

/// A simple, contiguous, read/write memory space.
class RAM extends MemoryBase {
  final Uint8List _memory;

  /// Initializes a random access memory bank.
  ///
  /// By default, a 64KB memory bank is created.
  RAM(int? sizeInBytes) : _memory = Uint8List(sizeInBytes ?? 0x10000);

  @override
  void load(int origin, Iterable<int> data) =>
      _memory.setRange(origin, origin + data.length, data);

  @override
  Uint8List read(int origin, int length) =>
      _memory.sublist(origin, origin + length);

  @override
  int readByte(int address) => _memory[address];

  @override
  int readWord(int address) =>
      createWord(_memory[address], _memory[address + 1]);

  @override
  void reset() => _memory.fillRange(0, _memory.length, 0);

  @override
  void writeByte(int address, int value) => _memory[address] = value;

  @override
  void writeWord(int address, int value) {
    _memory[address] = lowByte(value);
    _memory[address + 1] = highByte(value);
  }
}
