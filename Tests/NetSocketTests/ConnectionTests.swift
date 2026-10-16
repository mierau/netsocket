import Foundation
import Network
import NetSocket
import Testing

@Suite("Connection lifecycle", .timeLimit(.minutes(1)))
struct ConnectionTests {
  @Test func refusedConnectionThrowsFailed() async throws {
    let port = try await TestServer.unusedPort()
    do {
      _ = try await NetSocket.connect(host: "127.0.0.1", port: port)
      Issue.record("Expected the connection to be refused")
    } catch NetSocketError.failed {
      // Expected
    }
  }

  @Test func cancellingConnectThrowsCancellationError() async throws {
    let port = try await TestServer.unusedPort()
    let connecting = Task { try await NetSocket.connect(host: "127.0.0.1", port: port) }
    connecting.cancel()
    do {
      _ = try await connecting.value
      Issue.record("Expected connect to throw")
    } catch is CancellationError {
      // Expected
    } catch NetSocketError.failed {
      // Also fine: the refusal can land before the cancellation
    }
  }

  @Test func dataSentBeforePeerClosesIsStillReadable() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([1, 2, 3, 4]))
      await peer.close()
      // Give the socket time to see the close before reading.
      try await Task.sleep(for: .milliseconds(100))

      #expect(try await socket.read(4) == Data([1, 2, 3, 4]))
      await expect(.closed) { try await socket.read(1) }
    }
  }

  @Test func shortReadAtPeerCloseReportsWhatArrived() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([1, 2]))
      await peer.close()
      await expect(.insufficientData(expected: 4, got: 2)) { try await socket.read(4) }
    }
  }

  @Test func closeFailsPendingReads() async throws {
    try await withConnectedSocket { socket, _ in
      let pending = Task { try await socket.read(4) }
      try await Task.sleep(for: .milliseconds(50))
      await socket.close()
      await expect(.closed) { try await pending.value }
    }
  }

  @Test func closeDiscardsUnreadData() async throws {
    try await withConnectedSocket { socket, peer in
      try await peer.send(Data([1, 2, 3]))
      _ = try await socket.peek(awaiting: 3)
      await socket.close()
      await expect(.closed) { try await socket.read(1) }
      #expect(await socket.availableBytes == 0)
    }
  }

  @Test func writeAfterCloseThrows() async throws {
    try await withConnectedSocket { socket, _ in
      await socket.close()
      await socket.close() // Closing twice is fine
      await expect(.closed) { try await socket.write(UInt8(1)) }
    }
  }

  @Test func cancellingAReadLeavesTheSocketUsable() async throws {
    try await withConnectedSocket { socket, peer in
      let pending = Task { try await socket.read(4) }
      try await Task.sleep(for: .milliseconds(50))
      pending.cancel()
      await #expect(throws: CancellationError.self) { try await pending.value }

      try await peer.send(Data([1, 2, 3, 4]))
      #expect(try await socket.read(4) == Data([1, 2, 3, 4]))
    }
  }

  @Test func keepAliveLeavesCallersParametersAlone() async throws {
    let server = try await TestServer.start()
    defer { server.stop() }

    var config = NetSocket.Config()
    config.enableKeepAlive = true
    let parameters = NWParameters.tcp
    let socket = try await NetSocket.connect(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, config: config, parameters: parameters)
    await socket.close()

    let tcp = try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    #expect(tcp.enableKeepalive == false)
  }
}

@Suite("Buffering and backpressure", .timeLimit(.minutes(1)))
struct BufferingTests {
  /// Small limits so tests can cross them quickly
  static var smallBuffers: NetSocket.Config {
    var config = NetSocket.Config()
    config.receiveChunk = 4 * 1024
    config.receiveHighWaterMark = 16 * 1024
    config.maxBufferBytes = 64 * 1024
    return config
  }

  @Test func readLargerThanHighWaterMark() async throws {
    try await withConnectedSocket(config: Self.smallBuffers) { socket, peer in
      let payload = patternData(count: 48 * 1024)
      let sending = Task { try await peer.send(payload) }
      #expect(try await socket.read(payload.count) == payload)
      try await sending.value
    }
  }

  @Test func skipLargerThanMaxBuffer() async throws {
    try await withConnectedSocket(config: Self.smallBuffers) { socket, peer in
      let size = 1024 * 1024
      let sending = Task { try await peer.send(Data(repeating: 0xAB, count: size) + Data([0xDE, 0xAD, 0xBE, 0xEF])) }
      try await socket.skip(size)
      #expect(try await socket.read(UInt32.self) == 0xDEAD_BEEF)
      try await sending.value
    }
  }

  @Test func manySmallReadsAcrossMegabytes() async throws {
    try await withConnectedSocket(config: Self.smallBuffers) { socket, peer in
      let payload = patternData(count: 1024 * 1024)
      let sending = Task { try await peer.send(payload) }
      // Read sizes 1, 2, 3, ... so reads land at every offset within receive chunks.
      var received = Data()
      var size = 1
      while received.count < payload.count {
        received += try await socket.read(min(size, payload.count - received.count))
        size += 1
      }
      #expect(received == payload)
      try await sending.value
    }
  }

  @Test func readLargerThanMaxBufferDisconnects() async throws {
    try await withConnectedSocket(config: Self.smallBuffers) { socket, peer in
      let sending = Task { try await peer.send(Data(repeating: 0xAB, count: 128 * 1024)) }
      await expect(.framingExceeded(max: 64 * 1024)) { try await socket.read(100_000) }
      await expect(.closed) { try await socket.write(UInt8(1)) }
      _ = try? await sending.value
    }
  }
}
