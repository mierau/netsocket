import Foundation
import NetSocket
import Testing

/// A message with a 4-byte ID and a name with a 2-byte length prefix
private struct Greeting: NetSocketEncodable, NetSocketDecodable, Equatable {
  let id: UInt32
  let name: String

  init(id: UInt32, name: String) {
    self.id = id
    self.name = name
  }

  func encode(endian: Endian) throws -> Data {
    let name = Data(self.name.utf8)
    guard let length = UInt16(exactly: name.count) else {
      throw NetSocketError.encodeFailed(CocoaError(.coderInvalidValue))
    }
    var data = Data()
    data += withUnsafeBytes(of: endian == .big ? self.id.bigEndian : self.id.littleEndian) { Data($0) }
    data += withUnsafeBytes(of: endian == .big ? length.bigEndian : length.littleEndian) { Data($0) }
    data += name
    return data
  }

  init(from socket: NetSocket, endian: Endian) async throws {
    self.id = try await socket.read(UInt32.self, endian: endian)
    let length = try await socket.read(UInt16.self, endian: endian)
    self.name = try await socket.read(Int(length), encoding: .utf8)
  }
}

@Suite("NetSocketEncodable and NetSocketDecodable", .timeLimit(.minutes(1)))
struct CodableTests {
  @Test(arguments: [Endian.big, .little])
  func roundTrip(endian: Endian) async throws {
    try await withConnectedSocket { socket, peer in
      let greeting = Greeting(id: 0x0102_0304, name: "Hotline")
      try await socket.send(greeting, endian: endian)

      let bytes = try await peer.receive(4 + 2 + 7)
      let expectedPrefix: [UInt8] = endian == .big ? [1, 2, 3, 4, 0, 7] : [4, 3, 2, 1, 7, 0]
      #expect(Array(bytes.prefix(6)) == expectedPrefix)

      try await peer.send(bytes + bytes)
      #expect(try await socket.receive(Greeting.self, endian: endian) == greeting)
      #expect(try await socket.receive(Greeting.self, endian: endian) == greeting)
    }
  }
}
