import Foundation
import NetSocket
import Testing

@Suite("Byte collections")
struct ByteCollectionTests {
  // MARK: Appending

  @Test func appendIntegersInBothByteOrders() {
    var data = Data()
    data.append(UInt16(0x1234), endian: .big)
    data.append(UInt32(0x1234_5678), endian: .little)
    data.append(Int8(-1), endian: .big)
    data.append(Int64(-2), endian: .big)
    #expect(data == Data([
      0x12, 0x34,
      0x78, 0x56, 0x34, 0x12,
      0xFF,
      0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    ]))
  }

  @Test func appendToByteArray() throws {
    var bytes: [UInt8] = []
    bytes.append(UInt16(0xBEEF), endian: .big)
    bytes.append(true)
    try bytes.append("hi")
    #expect(bytes == [0xBE, 0xEF, 0x01, 0x68, 0x69])
  }

  @Test func appendBoolsFloatsAndDoubles() {
    var data = Data()
    data.append(true)
    data.append(false)
    data.append(Float(1.5), endian: .big)
    data.append(Double(-2.25), endian: .little)

    var expected = Data([0x01, 0x00])
    expected += withUnsafeBytes(of: Float(1.5).bitPattern.bigEndian) { Data($0) }
    expected += withUnsafeBytes(of: Double(-2.25).bitPattern.littleEndian) { Data($0) }
    #expect(data == expected)
  }

  @Test func appendStrings() throws {
    var data = Data()
    try data.append("héllo")
    try data.append("é", encoding: .macOSRoman)
    #expect(data == Data("héllo".utf8) + Data([0x8E]))

    #expect(throws: NetSocketError.self) { try data.append("日本", encoding: .ascii) }
    #expect(data.count == 7)
  }

  /// The numeric appends require a byte order, so integer literals still append a single byte.
  @Test func literalsStillAppendOneByte() {
    var data = Data()
    data.append(0)
    data.append(0xFF)
    var bytes: [UInt8] = []
    bytes.append(1)
    #expect(data == Data([0x00, 0xFF]))
    #expect(bytes == [0x01])
  }

  // MARK: Reading

  @Test func readIntegersAtOffsets() {
    let data = Data([0x00, 0x2A, 0x01, 0x00, 0xFF, 0xFE, 0x12, 0x34, 0x56, 0x78])
    #expect(data.read(UInt8.self, at: 1) == 0x2A)
    #expect(data.read(UInt16.self, at: 0) == 42)
    #expect(data.read(UInt16.self, at: 2, endian: .little) == 1)
    #expect(data.read(Int16.self, at: 4) == -2)
    #expect(data.read(UInt32.self, at: 6) == 0x1234_5678)
    #expect(data.read(UInt32.self, at: 6, endian: .little) == 0x7856_3412)
  }

  @Test func readPastTheEndIsNil() {
    let data = Data([0x01, 0x02, 0x03])
    #expect(data.read(UInt32.self, at: 0) == nil)
    #expect(data.read(UInt16.self, at: 2) == nil)
    #expect(data.read(UInt8.self, at: 3) == nil)
    #expect(data.read(UInt8.self, at: -1) == nil)
    #expect(data.read(4, at: 0) == nil)
    #expect(data.read(1, at: -1) == nil)
    #expect(data.read(2, at: 2, encoding: .utf8) == nil)
    #expect(Data().read(UInt8.self, at: 0) == nil)
    #expect(Data().read(0, at: 0) == Data())
  }

  @Test func offsetsCountFromTheStartOfASlice() {
    let data = Data([0xAA, 0xBB, 0x00, 0x2A, 0x68, 0x69])
    let slice = data[2...]
    #expect(slice.startIndex == 2)
    #expect(slice.read(UInt16.self, at: 0) == 42)
    #expect(slice.read(2, at: 2, encoding: .utf8) == "hi")

    let bytes: ArraySlice<UInt8> = [0xAA, 0x00, 0x07][1...]
    #expect(bytes.read(UInt16.self, at: 0) == 7)
  }

  @Test func readBoolsFloatsAndDoubles() {
    var data = Data([0x00, 0x05])
    data.append(Float(1.5), endian: .big)
    data.append(Double(-2.25), endian: .little)
    #expect(data.read(Bool.self, at: 0) == false)
    #expect(data.read(Bool.self, at: 1) == true)
    #expect(data.read(Float.self, at: 2) == 1.5)
    #expect(data.read(Double.self, at: 6, endian: .little) == -2.25)
    #expect(data.read(Double.self, at: 7, endian: .little) == nil)
  }

  @Test func readBytesAndStrings() {
    let data = Data([0x00]) + Data("café".utf8) + Data([0x8E, 0xFF])
    let bytes = data.read(3, at: 1)
    #expect(bytes == Data("caf".utf8))
    #expect(bytes?.startIndex == 0)
    #expect(data.read(5, at: 1, encoding: .utf8) == "café")
    #expect(data.read(1, at: 6, encoding: .macOSRoman) == "é")
    // 0xFF isn't valid UTF-8
    #expect(data.read(1, at: 7, encoding: .utf8) == nil)
  }

  @Test(arguments: [Endian.big, .little])
  func integersRoundTrip(endian: Endian) {
    var data = Data()
    data.append(UInt8(0xAB), endian: endian)
    data.append(Int16.min, endian: endian)
    data.append(UInt32.max - 1, endian: endian)
    data.append(Int64(-1234567890123), endian: endian)
    data.append(UInt64.max, endian: endian)

    #expect(data.read(UInt8.self, at: 0, endian: endian) == 0xAB)
    #expect(data.read(Int16.self, at: 1, endian: endian) == .min)
    #expect(data.read(UInt32.self, at: 3, endian: endian) == UInt32.max - 1)
    #expect(data.read(Int64.self, at: 7, endian: endian) == -1234567890123)
    #expect(data.read(UInt64.self, at: 15, endian: endian) == .max)
  }
}
