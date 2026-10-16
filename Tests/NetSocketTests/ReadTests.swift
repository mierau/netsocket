import Foundation
import NetSocket
import os
import Testing

@Suite("Reading", .timeLimit(.minutes(1)))
struct ReadTests {
  @Test func integersInBothByteOrders() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([
        0x2A,
        0x12, 0x34,
        0x78, 0x56, 0x34, 0x12,
        0xFF, 0xFE,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      ]))
      #expect(try await socket.read(UInt8.self) == 0x2A)
      #expect(try await socket.read(UInt16.self) == 0x1234)
      #expect(try await socket.read(UInt32.self, endian: .little) == 0x1234_5678)
      #expect(try await socket.read(Int16.self) == -2)
      #expect(try await socket.read(UInt64.self) == 1)
    }
  }

  @Test func boolsFloatsAndDoubles() async throws {
    try await withConnectedSocket { socket, peer in
      var bytes = Data([0x01, 0x00, 0x7F])
      bytes += withUnsafeBytes(of: Float(1.5).bitPattern.bigEndian) { Data($0) }
      bytes += withUnsafeBytes(of: Double(-2.25).bitPattern.littleEndian) { Data($0) }
      try await peer.send(bytes)

      #expect(try await socket.read(Bool.self) == true)
      #expect(try await socket.read(Bool.self) == false)
      #expect(try await socket.read(Bool.self) == true)
      #expect(try await socket.read(Float.self) == 1.5)
      #expect(try await socket.read(Double.self, endian: .little) == -2.25)
    }
  }

  @Test func fixedLengthStrings() async throws {
    try await withConnectedSocket { socket, peer in
      // "é" is 0x8E in Mac OS Roman
      try await peer.send(Data("héllo".utf8) + Data([0x8E]))
      #expect(try await socket.read(6, encoding: .utf8) == "héllo")
      #expect(try await socket.read(1, encoding: .macOSRoman) == "é")
    }
  }

  @Test func invalidStringBytesThrow() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([0xFF, 0xFE]))
      await expect(.stringDecodingFailed(.utf8)) { try await socket.read(2, encoding: .utf8) }
    }
  }

  @Test func delimitedRecords() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data("HELLO\r\nworld\nabc\0rest|caf".utf8) + Data([0x8E, 0x0A]))
      #expect(try await socket.read(until: .carriageReturnLineFeed) == "HELLO")
      #expect(try await socket.read(until: .lineFeed, includeDelimiter: true) == "world\n")
      #expect(try await socket.read(until: .zeroByte) == "abc")
      #expect(try await socket.read(past: Data("|".utf8)) == Data("rest".utf8))
      #expect(try await socket.read(until: .lineFeed, encoding: .macOSRoman) == "café")
    }
  }

  @Test func delimiterSplitAcrossPackets() async throws {
    try await withConnectedSocket { socket, peer in
      let line = Task { try await socket.read(until: .carriageReturnLineFeed) }
      try await peer.send(Data("partial\r".utf8))
      try await Task.sleep(for: .milliseconds(50))
      try await peer.send(Data("\nnext".utf8))

      #expect(try await line.value == "partial")
      #expect(try await socket.read(4, encoding: .utf8) == "next")
    }
  }

  @Test func delimiterMissingWithinMaxBytes() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data(repeating: 0x41, count: 100))
      await expect(.framingExceeded(max: 50)) { try await socket.read(until: .lineFeed, maxBytes: 50) }
      // Nothing was consumed
      #expect(await socket.availableBytes >= 50)
    }
  }

  @Test func peekLeavesBytesUnread() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([1, 2, 3, 4]))
      #expect(try await socket.peek(awaiting: 4) == Data([1, 2, 3, 4]))
      #expect(await socket.peek(2) == Data([1, 2]))
      #expect(await socket.peek(5) == nil)
      #expect(await socket.peek(upTo: 10) == Data([1, 2, 3, 4]))
      #expect(await socket.availableBytes == 4)

      #expect(try await socket.read(4) == Data([1, 2, 3, 4]))
      #expect(await socket.peek(upTo: 10).isEmpty)
    }
  }

  @Test func readUpToReturnsWhatIsBuffered() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([1, 2, 3]))
      _ = try await socket.peek(awaiting: 3)
      #expect(try await socket.read(upTo: 100) == Data([1, 2, 3]))

      let next = Task { try await socket.read(upTo: 100) }
      try await peer.send(Data([4]))
      #expect(try await next.value == Data([4]))
    }
  }

  @Test func skipping() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data("junk junk\r\nkeep".utf8) + Data([9, 8, 7]))
      try await socket.skip(past: Delimiter.carriageReturnLineFeed.data)
      #expect(try await socket.read(4, encoding: .utf8) == "keep")
      try await socket.skip(2)
      #expect(try await socket.read(UInt8.self) == 7)
    }
  }

  @Test func chunkedReadReportsProgress() async throws {
    try await withConnectedSocket { socket, peer in
      let payload = patternData(count: 10_000)
      try await peer.send(payload)

      let reports = OSAllocatedUnfairLock<[Int]>(initialState: [])
      let data = try await socket.read(payload.count, chunkSize: 4096) { received, total in
        #expect(total == 10_000)
        reports.withLock { $0.append(received) }
      }

      #expect(data == payload)
      #expect(reports.withLock { $0 } == [4096, 8192, 10_000])
    }
  }
}
