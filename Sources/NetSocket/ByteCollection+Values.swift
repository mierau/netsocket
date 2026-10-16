// NetSocket: Reading and writing values in byte collections
// Dustin Mierau • @mierau
// MIT License

import Foundation

// The in-memory counterparts of NetSocket's reads and writes, for building a packet before
// sending it, such as in `NetSocketEncodable.encode(endian:)`, or parsing one that's already
// been received. They work on `Data`, `[UInt8]`, and slices of either.

// MARK: - Appending

// Unlike NetSocket's writes, the numeric appends have no default byte order. With one,
// `data.append(0)` would append an 8-byte Int instead of the single byte it appends today.

public extension RangeReplaceableCollection where Element == UInt8 {
  /// Append a fixed-width integer in the given byte order
  ///
  /// ```swift
  /// var packet = Data()
  /// packet.append(UInt16(0x1234), endian: .big)    // 12 34
  /// packet.append(UInt32(1), endian: .little)      // 01 00 00 00
  /// ```
  mutating func append<T: FixedWidthInteger>(_ value: T, endian: Endian) {
    let ordered = endian == .big ? value.bigEndian : value.littleEndian
    Swift.withUnsafeBytes(of: ordered) { self.append(contentsOf: $0) }
  }

  /// Append a Bool as one byte, 1 or 0
  mutating func append(_ value: Bool) {
    self.append(UInt8(value ? 0x01 : 0x00))
  }

  /// Append a Float's IEEE 754 bit pattern
  mutating func append(_ value: Float, endian: Endian) {
    self.append(value.bitPattern, endian: endian)
  }

  /// Append a Double's IEEE 754 bit pattern
  mutating func append(_ value: Double, endian: Endian) {
    self.append(value.bitPattern, endian: endian)
  }

  /// Append a string's bytes in the given encoding, with no length prefix or terminator
  ///
  /// - Throws: ``NetSocketError/stringEncodingFailed(_:)`` if the string can't be represented
  ///   in `encoding` and `allowLossyConversion` is false
  mutating func append(_ string: String, encoding: String.Encoding = .utf8, allowLossyConversion: Bool = false) throws {
    guard let data = string.data(using: encoding, allowLossyConversion: allowLossyConversion) else {
      throw NetSocketError.stringEncodingFailed(encoding)
    }
    self.append(contentsOf: data)
  }
}

// MARK: - Reading

public extension RandomAccessCollection where Element == UInt8 {
  /// Read a fixed-width integer `offset` bytes from the start, or nil if there aren't enough bytes
  ///
  /// Offsets count from the start of the collection, so they work the same on slices.
  ///
  /// ```swift
  /// let packet = Data([0x00, 0x2A, 0x01, 0x00])
  /// packet.read(UInt16.self, at: 0)                    // 42
  /// packet.read(UInt16.self, at: 2, endian: .little)   // 1
  /// packet.read(UInt32.self, at: 2)                    // nil
  /// ```
  func read<T: FixedWidthInteger>(_ type: T.Type = T.self, at offset: Int, endian: Endian = .big) -> T? {
    guard let bytes = self.bytes(at: offset, count: MemoryLayout<T>.size) else {
      return nil
    }
    var value = T.zero
    Swift.withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
    switch endian {
    case .big: return T(bigEndian: value)
    case .little: return T(littleEndian: value)
    }
  }

  /// Read one byte as a Bool, where anything other than 0 is true, or nil if `offset` is past the end
  func read(_ type: Bool.Type, at offset: Int) -> Bool? {
    return self.read(UInt8.self, at: offset).map { $0 != 0 }
  }

  /// Read a Float from its IEEE 754 bit pattern, or nil if there aren't enough bytes
  func read(_ type: Float.Type, at offset: Int, endian: Endian = .big) -> Float? {
    return self.read(UInt32.self, at: offset, endian: endian).map(Float.init(bitPattern:))
  }

  /// Read a Double from its IEEE 754 bit pattern, or nil if there aren't enough bytes
  func read(_ type: Double.Type, at offset: Int, endian: Endian = .big) -> Double? {
    return self.read(UInt64.self, at: offset, endian: endian).map(Double.init(bitPattern:))
  }

  /// `count` bytes starting `offset` bytes from the start, or nil if there aren't enough bytes
  func read(_ count: Int, at offset: Int) -> Data? {
    return self.bytes(at: offset, count: count).map { Data($0) }
  }

  /// Decode `length` bytes starting `offset` bytes from the start as a string
  ///
  /// - Returns: nil if there aren't enough bytes, or they aren't valid in `encoding`
  func read(_ length: Int, at offset: Int, encoding: String.Encoding = .utf8) -> String? {
    return self.bytes(at: offset, count: length).flatMap { String(bytes: $0, encoding: encoding) }
  }

  /// The `count` bytes starting `offset` bytes from the start, if they're all there
  private func bytes(at offset: Int, count: Int) -> SubSequence? {
    guard offset >= 0, count >= 0, offset <= self.count - count else {
      return nil
    }
    let start = self.index(self.startIndex, offsetBy: offset)
    return self[start..<self.index(start, offsetBy: count)]
  }
}
