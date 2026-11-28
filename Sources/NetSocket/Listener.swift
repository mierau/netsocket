// NetSocket: Listener
// Dustin Mierau • @mierau
// MIT License

import Foundation
import Network
import os

extension NetSocket {
  /// Listen for TCP connections on a port, and return once it's open
  ///
  /// Each connection is handed over as a ready `NetSocket`, with the same reads and writes as one
  /// you connected yourself:
  ///
  /// ```swift
  /// let listener = try await NetSocket.listen(port: 5500)
  /// for await socket in listener {
  ///   Task { try await serve(socket) }
  /// }
  /// ```
  ///
  /// The port can be listened on again as soon as a previous listener on it has stopped, but
  /// never while another one is listening.
  ///
  /// - Parameters:
  ///   - port: The port to listen on, or 0 for any free port. See ``Listener/port``.
  ///   - tls: Plain TCP by default. Use ``TLSPolicy/server(identity:_:)`` to take TLS connections.
  ///   - config: Buffering and keepalive options for each connection.
  ///   - interface: Only take connections over this kind of interface, such as `.loopback`.
  ///   - service: A Bonjour service to advertise. See ``Listener/advertise(_:)``.
  ///   - readyTimeout: How long a connection has to become ready, including its TLS handshake,
  ///     before it's closed.
  ///   - accepting: Decides from its address whether to take a connection, before any TLS work.
  ///     Connections it turns down are closed at once.
  /// - Throws: ``NetSocketError/invalidPort``, or ``NetSocketError/failed(underlying:)`` if the
  ///   port can't be listened on, as when it's in use.
  public static func listen(
    port: UInt16 = 0,
    tls: TLSPolicy = .disabled,
    config: Config = .init(),
    interface: NWInterface.InterfaceType? = nil,
    service: NWListener.Service? = nil,
    readyTimeout: Duration = .seconds(10),
    accepting: (@Sendable (NWEndpoint) -> Bool)? = nil
  ) async throws -> Listener {
    guard let nwPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port) else {
      throw NetSocketError.invalidPort
    }

    let parameters = tls.makeParameters()
    // A server that stops and starts again can have its port back at once. Two listeners still
    // can't share a port.
    parameters.allowLocalEndpointReuse = true
    if let interface {
      parameters.requiredInterfaceType = interface
    }
    self.applyTCPOptions(config, to: parameters)

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: nwPort)
    } catch {
      throw NetSocketError.failed(underlying: error)
    }

    let queue = DispatchQueue(label: "NetSocket.Listener", qos: config.dispatchQoS)
    let ended = Listener.Ending()
    let (sockets, continuation) = AsyncStream.makeStream(of: NetSocket.self)
    continuation.onTermination = { _ in
      listener.cancel()
    }

    listener.service = service
    listener.newConnectionHandler = { connection in
      if let accepting, !accepting(connection.endpoint) {
        connection.cancel()
        return
      }
      Task(priority: config.priority) {
        guard let socket = await Listener.accept(connection, config: config, timeout: readyTimeout) else {
          return
        }
        if case .terminated = continuation.yield(socket) {
          await socket.close()
        }
      }
    }

    let port: UInt16 = try await withCheckedThrowingContinuation { (started: CheckedContinuation<UInt16, Error>) in
      let starting = OSAllocatedUnfairLock<CheckedContinuation<UInt16, Error>?>(initialState: started)
      @Sendable func finishStarting(_ result: Result<UInt16, Error>) {
        let started = starting.withLock { pending in
          defer { pending = nil }
          return pending
        }
        started?.resume(with: result)
      }

      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          finishStarting(.success(listener.port?.rawValue ?? 0))
        case .waiting(let error), .failed(let error):
          // Waiting means it can't listen yet, as when the network is down, so give up rather
          // than leave the caller hanging.
          finishStarting(.failure(NetSocketError.failed(underlying: error)))
          listener.cancel()
        case .cancelled:
          finishStarting(.failure(NetSocketError.closed))
          continuation.finish()
          ended.finish()
        default:
          break
        }
      }
      listener.start(queue: queue)
    }

    return Listener(port: port, listener: listener, queue: queue, sockets: sockets, ended: ended)
  }

  /// A port being listened on, which hands over each connection as a ready ``NetSocket``
  ///
  /// Made by ``NetSocket/NetSocket/listen(port:tls:config:interface:service:readyTimeout:accepting:)``.
  /// Each connection is handed over once it's ready, after its TLS handshake when TLS is on, so a
  /// slow client never holds up the others, and one that isn't ready within `readyTimeout` is closed.
  /// Iterate it from one task only, as with any `AsyncStream`. Iteration ends when the listener
  /// stops or fails.
  public final class Listener: AsyncSequence, Sendable {
    public typealias Element = NetSocket
    public typealias AsyncIterator = AsyncStream<NetSocket>.Iterator

    /// The port it's listening on, which the system picks when listening on port 0
    public let port: UInt16

    private let listener: NWListener
    private let queue: DispatchQueue
    private let sockets: AsyncStream<NetSocket>
    private let ended: Ending

    fileprivate init(port: UInt16, listener: NWListener, queue: DispatchQueue, sockets: AsyncStream<NetSocket>, ended: Ending) {
      self.port = port
      self.listener = listener
      self.queue = queue
      self.sockets = sockets
      self.ended = ended
    }

    public func makeAsyncIterator() -> AsyncStream<NetSocket>.Iterator {
      self.sockets.makeAsyncIterator()
    }

    /// Advertise with Bonjour under a new name or TXT record, or stop advertising with nil
    public func advertise(_ service: NWListener.Service?) {
      self.queue.async {
        self.listener.service = service
      }
    }

    /// Stop listening and advertising, and return once the port is free
    ///
    /// Iteration ends. Sockets already handed over stay open, and connections still becoming ready
    /// are closed.
    public func stop() async {
      self.listener.cancel()
      await self.ended.wait()
    }

    /// Give a connection until `timeout` to become ready
    fileprivate static func accept(_ connection: NWConnection, config: NetSocket.Config, timeout: Duration) async -> NetSocket? {
      await withTaskGroup(of: NetSocket?.self) { group in
        group.addTask {
          try? await NetSocket.accept(connection, config: config)
        }
        group.addTask {
          try? await Task.sleep(for: timeout)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }

    /// Lets ``stop()`` wait until the listener has let go of its port
    fileprivate final class Ending: Sendable {
      private let state = OSAllocatedUnfairLock(initialState: (done: false, waiters: [CheckedContinuation<Void, Never>]()))

      func finish() {
        let waiters = self.state.withLock { state in
          state.done = true
          defer { state.waiters.removeAll() }
          return state.waiters
        }
        for waiter in waiters {
          waiter.resume()
        }
      }

      func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
          let done = self.state.withLock { state in
            if !state.done {
              state.waiters.append(waiter)
            }
            return state.done
          }
          if done {
            waiter.resume()
          }
        }
      }
    }
  }
}
