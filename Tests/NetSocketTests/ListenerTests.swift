import Foundation
import Network
import NetSocket
import os
import Testing

@Suite("Listening", .timeLimit(.minutes(1)))
struct ListenerTests {
  @Test func eachConnectionArrivesAsItsOwnReadySocket() async throws {
    let listener = try await NetSocket.listen(interface: .loopback)
    var sockets = listener.makeAsyncIterator()

    let first = try await TestPeer.connect(to: listener.port)
    let second = try await TestPeer.connect(to: listener.port)
    defer {
      first.connection.cancel()
      second.connection.cancel()
    }

    let one = try #require(await sockets.next())
    let other = try #require(await sockets.next())

    // Each socket knows which client it came from, so pair them up that way.
    let ports = [one, other].map { Self.port(of: $0.remoteEndpoint) }
    let firstPort = try #require(first.localPort)
    let secondPort = try #require(second.localPort)
    #expect(Set(ports) == [firstPort, secondPort])
    let fromFirst = ports[0] == firstPort ? one : other
    let fromSecond = ports[0] == firstPort ? other : one

    try await first.send(Data([1, 2, 3]))
    try await second.send(Data([4, 5, 6]))
    #expect(try await fromFirst.read(3) == Data([1, 2, 3]))
    #expect(try await fromSecond.read(3) == Data([4, 5, 6]))

    await fromFirst.close()
    await fromSecond.close()
    await listener.stop()
  }

  @Test func bytesFlowBothWays() async throws {
    let listener = try await NetSocket.listen(interface: .loopback)
    var sockets = listener.makeAsyncIterator()
    let peer = try await TestPeer.connect(to: listener.port)
    defer { peer.connection.cancel() }
    let socket = try #require(await sockets.next())

    try await peer.send(Data("ping".utf8))
    #expect(try await socket.read(4, encoding: .utf8) == "ping")
    try await socket.write(UInt32(0xC0FF_EE00))
    #expect(try await peer.receive(4) == Data([0xC0, 0xFF, 0xEE, 0x00]))

    await socket.close()
    await listener.stop()
  }

  @Test func aServerCanRunItsSocketsAtALowerPriority() async throws {
    var config = NetSocket.Config()
    config.priority = .utility
    let listener = try await NetSocket.listen(config: config, interface: .loopback)
    var sockets = listener.makeAsyncIterator()
    let peer = try await TestPeer.connect(to: listener.port)
    defer { peer.connection.cancel() }
    let socket = try #require(await sockets.next())

    try await peer.send(Data("ping".utf8))
    #expect(try await socket.read(4, encoding: .utf8) == "ping")
    try await socket.write(Data("pong".utf8))
    #expect(try await peer.receive(4) == Data("pong".utf8))

    await socket.close()
    await listener.stop()
  }

  @Test func stoppingEndsIterationAndFreesThePort() async throws {
    let listener = try await NetSocket.listen(interface: .loopback)
    let port = listener.port
    let iterating = Task {
      var count = 0
      for await socket in listener {
        count += 1
        await socket.close()
      }
      return count
    }

    await listener.stop()
    #expect(await iterating.value == 0)

    // Nothing's listening, so connecting is refused.
    await #expect(throws: (any Error).self) {
      _ = try await TestPeer.connect(to: port)
    }

    // And the port can be listened on again straight away.
    let again = try await NetSocket.listen(port: port, interface: .loopback)
    #expect(again.port == port)
    await again.stop()
  }

  @Test func aPortInUseCantBeListenedOn() async throws {
    let listener = try await NetSocket.listen(interface: .loopback)
    do {
      let second = try await NetSocket.listen(port: listener.port, interface: .loopback)
      await second.stop()
      Issue.record("Expected listening on a port in use to fail")
    } catch NetSocketError.failed {
      // Expected
    }
    await listener.stop()
  }

  @Test func connectionsTurnedDownAreClosedAndNeverHandedOver() async throws {
    let asked = OSAllocatedUnfairLock<[NWEndpoint]>(initialState: [])
    let listener = try await NetSocket.listen(interface: .loopback) { endpoint in
      asked.withLock { $0.append(endpoint) }
      return false
    }
    let handedOver = OSAllocatedUnfairLock(initialState: 0)
    let iterating = Task {
      for await socket in listener {
        handedOver.withLock { $0 += 1 }
        await socket.close()
      }
    }

    let peer = try await TestPeer.connect(to: listener.port)
    defer { peer.connection.cancel() }
    await #expect(throws: (any Error).self) {
      _ = try await peer.receive(1)
    }
    #expect(asked.withLock { $0.map(Self.port(of:)) } == [peer.localPort])
    #expect(handedOver.withLock { $0 } == 0)

    await listener.stop()
    await iterating.value
  }

  @Test func connectionsThatNeverGetReadyAreClosed() async throws {
    // A TLS listener waits for a handshake a plain TCP client never starts.
    let listener = try await NetSocket.listen(tls: .enabled(), interface: .loopback, readyTimeout: .milliseconds(300))
    let handedOver = OSAllocatedUnfairLock(initialState: 0)
    let iterating = Task {
      for await socket in listener {
        handedOver.withLock { $0 += 1 }
        await socket.close()
      }
    }

    let peer = try await TestPeer.connect(to: listener.port)
    defer { peer.connection.cancel() }
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) {
      _ = try await peer.receive(1)
    }
    #expect(ContinuousClock.now - started >= .milliseconds(250))
    #expect(handedOver.withLock { $0 } == 0)

    await listener.stop()
    await iterating.value
  }

  @available(macOS 15, iOS 18, tvOS 18, visionOS 2, *)
  @Test func listensOverTLSWithItsOwnCertificate() async throws {
    let server = try TestIdentity()
    let listener = try await NetSocket.listen(tls: .server(identity: server.identity), interface: .loopback)
    var sockets = listener.makeAsyncIterator()

    // The client trusts the server's certificate, and nothing else.
    let client = try await NetSocket.connect(host: "127.0.0.1", port: listener.port, tls: .trusting(server.certificate))
    let socket = try #require(await sockets.next())

    try await client.write(Data("ping".utf8))
    #expect(try await socket.read(4, encoding: .utf8) == "ping")
    try await socket.write(Data("pong".utf8))
    #expect(try await client.read(4, encoding: .utf8) == "pong")

    await client.close()
    await socket.close()
    await listener.stop()
  }

  @available(macOS 15, iOS 18, tvOS 18, visionOS 2, *)
  @Test func connectionsWhoseHandshakeFailsAreNeverHandedOver() async throws {
    let server = try TestIdentity()
    let listener = try await NetSocket.listen(tls: .server(identity: server.identity), interface: .loopback)
    let handedOver = OSAllocatedUnfairLock(initialState: 0)
    let iterating = Task {
      for await socket in listener {
        handedOver.withLock { $0 += 1 }
        await socket.close()
      }
    }

    // The system doesn't trust a self-signed certificate, so the client ends the handshake.
    let error = await #expect(throws: NetSocketError.self) {
      _ = try await NetSocket.connect(host: "127.0.0.1", port: listener.port, tls: .enabled())
    }
    #expect(error?.isTLSFailure == true, "\(String(describing: error))")
    #expect(handedOver.withLock { $0 } == 0)

    await listener.stop()
    await iterating.value
  }

  @Test func acceptedSocketsUseTheConfig() async throws {
    let listener = try await NetSocket.listen(config: BufferingTests.smallBuffers, interface: .loopback)
    var sockets = listener.makeAsyncIterator()
    let peer = try await TestPeer.connect(to: listener.port)
    defer { peer.connection.cancel() }
    let socket = try #require(await sockets.next())

    let sending = Task { try await peer.send(Data(repeating: 0xAB, count: 128 * 1024)) }
    await expect(.framingExceeded(max: 64 * 1024)) { try await socket.read(100_000) }
    _ = try? await sending.value
    await listener.stop()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "Bonjour isn't dependable on CI machines"))
  func advertisesWithBonjourAndChangesWhatItSays() async throws {
    let type = "_netsockettest\(Int.random(in: 100...999))._tcp"
    let listener = try await NetSocket.listen(
      interface: .loopback,
      service: NWListener.Service(name: "NetSocket Test", type: type, domain: nil, txtRecord: NWTXTRecord(["version": "1"]))
    )
    let browser = TestBrowser(type: type)
    defer { browser.stop() }

    // Bonjour takes a second or two to pass on each change.
    #expect(await eventually(timeout: .seconds(10)) { browser.records == [["version": "1"]] })

    listener.advertise(NWListener.Service(name: "NetSocket Test", type: type, domain: nil, txtRecord: NWTXTRecord(["version": "2"])))
    #expect(await eventually(timeout: .seconds(10)) { browser.records == [["version": "2"]] })

    listener.advertise(nil)
    #expect(await eventually(timeout: .seconds(10)) { browser.records.isEmpty })

    await listener.stop()
  }

  private static func port(of endpoint: NWEndpoint) -> UInt16? {
    guard case .hostPort(_, let port) = endpoint else {
      return nil
    }
    return port.rawValue
  }
}

extension TestPeer {
  /// A plain TCP client connected to a loopback port, once it's ready
  static func connect(to port: UInt16) async throws -> TestPeer {
    let connection = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: cont)
      @Sendable func finish(_ result: Result<Void, Error>) {
        pending.withLock { pending in
          defer { pending = nil }
          return pending
        }?.resume(with: result)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          finish(.success(()))
        case .waiting(let error), .failed(let error):
          finish(.failure(error))
          connection.cancel()
        case .cancelled:
          finish(.failure(CancellationError()))
        default:
          break
        }
      }
      connection.start(queue: DispatchQueue(label: "TestPeer.connect"))
    }
    return TestPeer(connection: connection)
  }

  /// The port this end of the connection is on
  var localPort: UInt16? {
    guard case .hostPort(_, let port) = self.connection.currentPath?.localEndpoint else {
      return nil
    }
    return port.rawValue
  }
}

/// Browses for a Bonjour service type on the loopback interface, keeping each result's TXT record
final class TestBrowser: Sendable {
  private let browser: NWBrowser
  private let found = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])

  init(type: String) {
    let parameters = NWParameters()
    parameters.requiredInterfaceType = .loopback
    self.browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
    self.browser.browseResultsChangedHandler = { [found] results, _ in
      let records = results.map { result -> [String: String] in
        guard case .bonjour(let txt) = result.metadata else {
          return [:]
        }
        return txt.dictionary
      }
      found.withLock { $0 = records }
    }
    self.browser.start(queue: DispatchQueue(label: "TestBrowser"))
  }

  /// The TXT record of each service found so far
  var records: [[String: String]] {
    self.found.withLock { $0 }
  }

  func stop() {
    self.browser.cancel()
  }
}

/// Whether `condition` becomes true within `timeout`, checking every 50 ms
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() {
      return true
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return condition()
}
