import Foundation
import Network
import NetSocket
import os
import Testing

/// A loopback TCP listener, for driving a `NetSocket` from the other end of a real connection
///
/// The server side uses `NWConnection` directly, so tests don't rely on `NetSocket` to check itself.
final class TestServer: Sendable {
  let port: UInt16
  private let listener: NWListener
  private let connections: AsyncStream<NWConnection>

  private init(port: UInt16, listener: NWListener, connections: AsyncStream<NWConnection>) {
    self.port = port
    self.listener = listener
    self.connections = connections
  }

  /// Start listening on a free loopback port
  static func start() async throws -> TestServer {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)
    let queue = DispatchQueue(label: "TestServer")

    let (connections, continuation) = AsyncStream.makeStream(of: NWConnection.self)
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      continuation.yield(connection)
    }

    let port: UInt16 = try await withCheckedThrowingContinuation { cont in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let resumeOnce: @Sendable (Result<UInt16, Error>) -> Void = { result in
        let first = resumed.withLock { done in
          defer { done = true }
          return !done
        }
        if first { cont.resume(with: result) }
      }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          resumeOnce(.success(listener.port?.rawValue ?? 0))
        case .failed(let error):
          resumeOnce(.failure(error))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }

    return TestServer(port: port, listener: listener, connections: connections)
  }

  /// A port that nothing is listening on
  static func unusedPort() async throws -> UInt16 {
    let server = try await self.start()
    await server.stopAndWait()
    return server.port
  }

  /// The next client that connects
  func accept() async -> TestPeer {
    for await connection in self.connections {
      return TestPeer(connection: connection)
    }
    fatalError("Listener stopped before a client connected")
  }

  func stop() {
    self.listener.cancel()
  }

  /// Stop, and wait until the port no longer accepts connections
  func stopAndWait() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      self.listener.stateUpdateHandler = { state in
        if case .cancelled = state { cont.resume() }
      }
      self.listener.cancel()
    }
  }
}

/// The server's end of a connection
struct TestPeer: Sendable {
  let connection: NWConnection

  struct Closed: Error {}

  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      self.connection.send(content: data, completion: .contentProcessed { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      })
    }
  }

  /// Receive exactly `count` bytes
  func receive(_ count: Int) async throws -> Data {
    var data = Data()
    while data.count < count {
      let wanted = count - data.count
      let chunk: Data = try await withCheckedThrowingContinuation { cont in
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: wanted) { content, _, isComplete, error in
          if let error {
            cont.resume(throwing: error)
          } else if let content, !content.isEmpty {
            cont.resume(returning: content)
          } else if isComplete {
            cont.resume(throwing: Closed())
          } else {
            cont.resume(returning: Data())
          }
        }
      }
      data.append(chunk)
    }
    return data
  }

  /// Finish sending (TCP FIN) after everything already sent, then cancel
  func close() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
        cont.resume()
      })
    }
    self.connection.cancel()
  }
}

/// Connect a `NetSocket` to a fresh loopback server and run `body` with both ends
func withConnectedSocket(
  config: NetSocket.Config = .init(),
  _ body: (NetSocket, TestPeer) async throws -> Void
) async throws {
  let server = try await TestServer.start()
  defer { server.stop() }

  let socket = try await NetSocket.connect(host: "127.0.0.1", port: server.port, config: config)
  let peer = await server.accept()
  defer { peer.connection.cancel() }

  do {
    try await body(socket, peer)
  } catch {
    await socket.close()
    throw error
  }
  await socket.close()
}

/// A fresh temporary directory, removed after `body` runs
func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(component: "NetSocketTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory)
}

/// Check that `body` throws `expected`
///
/// `NetSocketError` carries non-Equatable values, so errors are compared by description, which
/// includes every associated value.
func expect<T>(
  _ expected: NetSocketError,
  sourceLocation: SourceLocation = #_sourceLocation,
  from body: () async throws -> T
) async {
  do {
    _ = try await body()
    Issue.record("Expected \(expected), but nothing was thrown", sourceLocation: sourceLocation)
  } catch let error as NetSocketError {
    #expect(error.description == expected.description, sourceLocation: sourceLocation)
  } catch {
    Issue.record("Expected \(expected), but got \(error)", sourceLocation: sourceLocation)
  }
}

/// `count` bytes in a repeating pattern, so misordered or dropped bytes show up
func patternData(count: Int) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
}
