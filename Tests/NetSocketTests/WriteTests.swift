import Foundation
import NetSocket
import Testing

@Suite("Writing", .timeLimit(.minutes(1)))
struct WriteTests {
  @Test func integersInBothByteOrders() async throws {
    try await withConnectedSocket { socket, peer throws in
      #expect(try await socket.write(UInt16(0x1234)) == 2)
      #expect(try await socket.write(UInt32(0x1234_5678), endian: .little) == 4)
      #expect(try await socket.write(Int8(-1)) == 1)
      #expect(try await peer.receive(7) == Data([0x12, 0x34, 0x78, 0x56, 0x34, 0x12, 0xFF]))
    }
  }

  @Test func boolsFloatsAndDoubles() async throws {
    try await withConnectedSocket { socket, peer in
      try await socket.write(true)
      try await socket.write(false)
      try await socket.write(Float(1.5))
      try await socket.write(Double(-2.25), endian: .little)

      var expected = Data([0x01, 0x00])
      expected += withUnsafeBytes(of: Float(1.5).bitPattern.bigEndian) { Data($0) }
      expected += withUnsafeBytes(of: Double(-2.25).bitPattern.littleEndian) { Data($0) }
      #expect(try await peer.receive(expected.count) == expected)
    }
  }

  @Test func strings() async throws {
    try await withConnectedSocket { socket, peer throws in
      #expect(try await socket.write("héllo") == 6)
      #expect(try await socket.write("é", encoding: .macOSRoman) == 1)
      #expect(try await peer.receive(7) == Data("héllo".utf8) + Data([0x8E]))
    }
  }

  @Test func unencodableStringThrows() async throws {
    try await withConnectedSocket { socket, _ in
      await expect(.stringEncodingFailed(.ascii)) { try await socket.write("日本", encoding: .ascii) }
    }
  }

  @Test func roundTrip() async throws {
    try await withConnectedSocket { socket, peer in
      let payload = patternData(count: 300_000)
      try await socket.write(payload)
      let echoed = try await peer.receive(payload.count)
      try await peer.send(echoed)
      #expect(try await socket.read(payload.count) == payload)
    }
  }
}
