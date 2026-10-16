// NetSocket
// Dustin Mierau • @mierau
// MIT License

import Foundation
import Network

/// A TCP connection with buffered async reads and writes
///
/// Reads wait until enough data has arrived, so binary protocols can be parsed one field at a
/// time. There are reads and writes for integers, strings, delimited records,
/// ``NetSocketDecodable``/``NetSocketEncodable`` types, and whole files.
///
/// ```swift
/// let socket = try await NetSocket.connect(host: "example.com", port: 80)
/// try await socket.write("GET / HTTP/1.0\r\n\r\n")
/// let status = try await socket.read(until: .carriageReturnLineFeed)
/// ```
public actor NetSocket {
  /// Socket options
  public struct Config: Sendable {
    /// Most bytes to take from the network per receive (default: 64 KB)
    public var receiveChunk: Int = 64 * 1024
    /// Stop receiving once this many unread bytes are buffered (default: 1 MB)
    ///
    /// Receiving resumes when reads drain the buffer below half of this, or when a read needs
    /// more than is buffered. While paused, TCP flow control slows the sender.
    public var receiveHighWaterMark: Int = 1024 * 1024
    /// Disconnect if more than this many unread bytes are buffered (default: 8 MB)
    ///
    /// Backpressure keeps the buffer near ``receiveHighWaterMark``, so this only happens for a
    /// single read larger than the limit, or a delimiter that never arrives.
    public var maxBufferBytes: Int = 8 * 1024 * 1024
    /// Turn on TCP keepalive to detect dead connections (default: false)
    public var enableKeepAlive: Bool = false
    /// Seconds of idle time before the first keepalive probe (default: 60)
    public var keepAliveIdleTime: Int = 60
    public init() {}
  }

  // Connection + state
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "NetSocket.NWConnection")
  private var ready = false
  private var isClosed = false  // Set once by shutdown(); the connection has been cancelled

  // Buffer with compaction
  private var buffer = Data()
  private var head = 0 // start of unread bytes
  private let config: Config
  private var receivePaused = false // no receive outstanding because the buffer is full
  private var inputDiscarded = false // set by our own close(); data that arrives after is dropped

  // Waiters for data/ready, keyed by ID so a cancelled task can remove its own
  private var dataWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
  private var readyWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
  private var nextWaiterID = 0

  // Serialized state update stream
  private var stateContinuation: AsyncStream<NWConnection.State>.Continuation?
  private var stateTask: Task<Void, Never>?

  // MARK: Init

  private init(connection: NWConnection, config: Config) {
    self.connection = connection
    self.config = config
  }

  deinit {
    // Safety net for owners that drop the socket without closing it.
    if !self.isClosed {
      self.stateContinuation?.finish()
      self.connection.cancel()
    }
  }

  // MARK: Connect

  /// Connect to a host and wait until the connection is ready
  ///
  /// - Parameters:
  ///   - host: For example `.name("example.com", nil)` or an IP address
  ///   - port: The port to connect to
  ///   - config: Buffering and keepalive options
  ///   - parameters: Plain TCP by default. Keepalive settings from `config` are applied to a copy.
  /// - Throws: ``NetSocketError/failed(underlying:)`` if the connection is refused or fails, or
  ///   `CancellationError` if the task is cancelled first
  public static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, config: Config = .init(), parameters: NWParameters = .tcp) async throws -> NetSocket {
    let parameters = parameters.copy()
    if config.enableKeepAlive {
      if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = config.keepAliveIdleTime
      }
    }
    let conn = NWConnection(host: host, port: port, using: parameters)
    let socket = NetSocket(connection: conn, config: config)
    do {
      try await socket.start()
    } catch {
      // Network keeps a refused (.waiting) connection alive and retries it, so cancel it here.
      await socket.close()
      throw error
    }
    return socket
  }

  /// Connect using a host name or IP address string
  ///
  /// - Parameters:
  ///   - host: A host name like `"example.com"`, or an IPv4 or IPv6 address
  ///   - port: The port to connect to
  ///   - tls: Plain TCP by default. See ``TLSPolicy``.
  ///   - config: Buffering and keepalive options
  /// - Throws: ``NetSocketError/failed(underlying:)`` if the connection is refused or fails, or
  ///   `CancellationError` if the task is cancelled first
  public static func connect(host: String, port: UInt16, tls: TLSPolicy = .disabled, config: Config = .init()) async throws -> NetSocket {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw NetSocketError.invalidPort
    }

    return try await self.connect(host: NWEndpoint.Host(host), port: nwPort, config: config, parameters: tls.makeParameters())
  }

  // MARK: Close

  /// Close the connection
  ///
  /// Pending reads and writes fail with ``NetSocketError/closed``, and unread data is discarded.
  /// Calling it again does nothing. See ``forceClose()`` to skip waiting for unsent data.
  public func close() {
    self.shutdown(.closed)
    self.discardBuffer()
  }

  /// Close the connection immediately, without waiting for unsent data
  ///
  /// Otherwise the same as ``close()``.
  public func forceClose() {
    self.shutdown(.closed, force: true)
    self.discardBuffer()
  }

  // MARK: Send Data

  /// Send bytes, returning once the network stack has taken them
  ///
  /// - Returns: The number of bytes sent
  @discardableResult
  public func write(_ data: Data) async throws -> Int {
    try await self.ensureReady()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
      self.connection.send(content: data, completion: .contentProcessed { error in
        if let error { cont.resume(throwing: NetSocketError.failed(underlying: error)) }
        else { cont.resume(returning: data.count) }
      })
    }
  }

  /// Send a fixed-width integer in the given byte order
  @discardableResult
  public func write<T: FixedWidthInteger>(_ value: T, endian: Endian = .big) async throws -> Int {
    let ordered = endian == .big ? value.bigEndian : value.littleEndian
    return try await self.write(withUnsafeBytes(of: ordered) { Data($0) })
  }

  /// Send a Bool as one byte, 1 or 0
  @discardableResult
  public func write(_ value: Bool) async throws -> Int {
    return try await self.write(UInt8(value ? 0x01 : 0x00))
  }

  /// Send a Float's IEEE 754 bit pattern
  @discardableResult
  public func write(_ value: Float, endian: Endian = .big) async throws -> Int {
    return try await self.write(value.bitPattern, endian: endian)
  }

  /// Send a Double's IEEE 754 bit pattern
  @discardableResult
  public func write(_ value: Double, endian: Endian = .big) async throws -> Int {
    return try await self.write(value.bitPattern, endian: endian)
  }

  /// Send a string's bytes in the given encoding, with no length prefix or terminator
  ///
  /// - Throws: ``NetSocketError/stringEncodingFailed(_:)`` if the string can't be represented
  ///   in `encoding` and `allowLossyConversion` is false
  @discardableResult
  public func write(_ string: String, encoding: String.Encoding = .utf8, allowLossyConversion: Bool = false) async throws -> Int {
    guard let data = string.data(using: encoding, allowLossyConversion: allowLossyConversion) else {
      throw NetSocketError.stringEncodingFailed(encoding)
    }
    return try await self.write(data)
  }

  // MARK: Receive Data

  /// Read up to the next occurrence of `delimiter`
  ///
  /// - Parameters:
  ///   - delimiter: The bytes that end the record
  ///   - maxBytes: Throw ``NetSocketError/framingExceeded(max:)`` if this many bytes arrive
  ///     without a delimiter
  ///   - includeDelimiter: Whether the result ends with the delimiter. It's consumed either way.
  public func read(past delimiter: Data, maxBytes: Int? = nil, includeDelimiter: Bool = false) async throws -> Data {
    while true {
      try Task.checkCancellation()
      if let r = self.search(delimiter: delimiter) {
        let consumeLen = r.upperBound - self.head
        let data = try await self.read(consumeLen)
        return includeDelimiter ? data : data.dropLast(delimiter.count)
      }
      if let maxBytes, self.availableBytes >= maxBytes {
        throw NetSocketError.framingExceeded(max: maxBytes)
      }
      // Throws once the connection has closed and no more data can arrive.
      try await self.waitForData()
    }
  }

  /// Read exactly `count` bytes, waiting for them to arrive if needed
  ///
  /// - Throws: ``NetSocketError/closed`` or ``NetSocketError/insufficientData(expected:got:)``
  ///   if the connection closes before `count` bytes are available
  public func read(_ count: Int) async throws -> Data {
    try await self.ensureReadable(count)
    let start = self.head
    let end = self.head + count
    let slice = self.buffer[start..<end]
    self.head = end
    self.didConsume()
    return Data(slice)
  }

  /// Read up to `count` bytes, as soon as any are available, without waiting for all of them
  ///
  /// - Throws: ``NetSocketError/closed`` once the connection has closed and everything that
  ///   came before has been read
  public func read(upTo count: Int) async throws -> Data {
    precondition(count > 0, "count must be > 0")
    try await self.ensureReadable(1)
    let amount = min(count, self.availableBytes)
    let slice = self.buffer[self.head..<(self.head + amount)]
    self.head += amount
    self.didConsume()
    return Data(slice)
  }

  /// Read a fixed-width integer in the given byte order
  public func read<T: FixedWidthInteger>(_ type: T.Type = T.self, endian: Endian = .big) async throws -> T {
    let size = MemoryLayout<T>.size
    let data = try await self.read(size)
    let value: T = data.withUnsafeBytes { raw in
      raw.loadUnaligned(as: T.self)
    }
    switch endian {
    case .big: return T(bigEndian: value)
    case .little: return T(littleEndian: value)
    }
  }

  /// Read one byte as a Bool, where anything other than 0 is true
  public func read(_ type: Bool.Type) async throws -> Bool {
    return try await self.read(UInt8.self) != 0
  }

  /// Read a Float from its IEEE 754 bit pattern
  public func read(_ type: Float.Type, endian: Endian = .big) async throws -> Float {
    return Float(bitPattern: try await self.read(UInt32.self, endian: endian))
  }

  /// Read a Double from its IEEE 754 bit pattern
  public func read(_ type: Double.Type, endian: Endian = .big) async throws -> Double {
    return Double(bitPattern: try await self.read(UInt64.self, endian: endian))
  }

  /// Read `length` bytes and decode them as a string
  ///
  /// - Throws: ``NetSocketError/stringDecodingFailed(_:)`` if the bytes aren't valid in `encoding`
  public func read(_ length: Int, encoding: String.Encoding = .utf8) async throws -> String {
    let data = try await self.read(length)
    guard let s = String(data: data, encoding: encoding) else {
      throw NetSocketError.stringDecodingFailed(encoding)
    }
    return s
  }

  /// Read a string up to the next `delimiter`
  ///
  /// The delimiter and `maxBytes` work the same as in ``read(past:maxBytes:includeDelimiter:)``.
  ///
  /// - Throws: ``NetSocketError/stringDecodingFailed(_:)`` if the bytes aren't valid in `encoding`
  public func read(until delimiter: Delimiter, maxBytes: Int? = nil, includeDelimiter: Bool = false, encoding: String.Encoding = .utf8) async throws -> String {
    let bytes = try await self.read(past: delimiter.data, maxBytes: maxBytes, includeDelimiter: includeDelimiter)
    guard let s = String(data: bytes, encoding: encoding) else {
      throw NetSocketError.stringDecodingFailed(encoding)
    }
    return s
  }

  /// Read exactly `count` bytes in chunks, calling `progress` with (bytes so far, total) after each one
  ///
  /// ```swift
  /// let data = try await socket.read(1_000_000) { received, total in
  ///   print("\(received) of \(total)")
  /// }
  /// ```
  public func read(
    _ count: Int,
    chunkSize: Int = 8192,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> Data {
    var data = Data()
    data.reserveCapacity(count)
    var received = 0

    while received < count {
      try Task.checkCancellation()
      let toRead = min(chunkSize, count - received)
      let chunk = try await self.read(toRead)
      data.append(chunk)
      received += chunk.count
      progress?(received, count)
    }

    return data
  }

  // MARK: Peek Data

  /// Bytes received but not read yet
  public var availableBytes: Int { self.buffer.count - self.head }

  /// The next `count` bytes without consuming them, or nil if fewer are buffered
  public func peek(_ count: Int) -> Data? {
    guard self.availableBytes >= count else {
      return nil
    }

    let slice = self.buffer[self.head..<(self.head + count)]
    return Data(slice) // Don't advance head
  }

  /// Up to `count` buffered bytes, without consuming them
  public func peek(upTo count: Int) -> Data {
    let amount = min(self.availableBytes, count)
    guard amount > 0 else {
      return Data()
    }

    let slice = self.buffer[self.head..<(self.head + amount)]
    return Data(slice)
  }

  /// The next `count` bytes without consuming them, waiting for them to arrive if needed
  public func peek(awaiting count: Int) async throws -> Data {
    try await self.ensureReadable(count)
    let slice = self.buffer[self.head..<(self.head + count)]
    return Data(slice) // Don't advance head
  }

  // MARK: Skip Data

  /// Discard exactly `count` bytes
  ///
  /// Bytes are dropped as they arrive, so `count` can be larger than
  /// ``Config/maxBufferBytes``.
  ///
  /// - Throws: ``NetSocketError/closed`` if the connection closes before `count` bytes arrive
  public func skip(_ count: Int) async throws {
    var skipped = 0
    while skipped < count {
      try await self.ensureReadable(1)
      // Only advance over bytes that are already buffered, same as read.
      let n = min(count - skipped, self.availableBytes)
      self.head += n
      skipped += n
      self.didConsume()
    }
  }

  /// Discard everything up to and including the next occurrence of `delimiter`
  public func skip(past delimiter: Data) async throws {
    while true {
      try Task.checkCancellation()
      if let r = self.search(delimiter: delimiter) {
        self.head = r.upperBound  // Skip to end of delimiter
        self.didConsume()
        return
      }
      // Throws once the connection has closed and no more data can arrive.
      try await self.waitForData()
    }
  }

  // MARK: Internals

  private func start() async throws {
    let (stream, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
    self.stateContinuation = continuation

    self.connection.stateUpdateHandler = { state in
      continuation.yield(state)
    }

    self.stateTask = Task { [weak self] in
      for await state in stream {
        // Bind self per update so this task never keeps the socket alive between updates.
        guard let self else { return }
        await self.handleStateUpdate(state)
      }
    }

    // Kick off receive loop after .start
    self.connection.start(queue: self.queue)
    try await self.waitUntilReady()
    self.receiveNext()
  }

  /// Ask the connection for the next chunk. Only one receive is ever outstanding.
  private func receiveNext() {
    guard !self.isClosed else { return }
    self.connection.receive(minimumIncompleteLength: 1, maximumLength: self.config.receiveChunk) { [weak self] data, _, isComplete, error in
      Task {
        await self?.handleReceive(data: data, isComplete: isComplete, error: error)
      }
    }
  }

  private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
    // Buffer data before handling an error or EOF so it can still be read.
    if let data, !data.isEmpty, !self.inputDiscarded {
      self.append(data)
    }
    if let error {
      self.shutdown(.failed(underlying: error))
      return
    }
    if isComplete {
      self.shutdown(.closed)
      return
    }

    // Backpressure: stop pulling from the network while the reader catches up.
    if self.availableBytes >= self.config.receiveHighWaterMark {
      self.receivePaused = true
    } else {
      self.receiveNext()
    }
  }

  /// Resume receiving after a pause. `force` is for a read that needs more than is buffered.
  private func resumeReceivingIfNeeded(force: Bool = false) {
    guard self.receivePaused else { return }
    guard force || self.availableBytes < self.config.receiveHighWaterMark / 2 else { return }
    self.receivePaused = false
    self.receiveNext()
  }

  private func handleStateUpdate(_ state: NWConnection.State) {
    switch state {
    case .ready:
      self.ready = true
      self.resumeReadyWaiters(with: .success(()))
    case .failed(let error):
      self.shutdown(.failed(underlying: error))
    case .waiting(let error):
      // Fails a pending connect(), which then closes the socket.
      self.resumeReadyWaiters(with: .failure(NetSocketError.failed(underlying: error)))
    case .cancelled:
      self.shutdown(.closed)
    default:
      break
    }
  }

  /// End the connection: cancel it, stop state updates, and fail anything waiting on it
  ///
  /// Every way a connection ends goes through here: close(), the peer closing, a receive error,
  /// a failed state, or a buffer overflow. Later calls do nothing.
  private func shutdown(_ error: NetSocketError, force: Bool = false) {
    guard !self.isClosed else { return }
    self.isClosed = true
    self.stateContinuation?.finish()
    self.stateContinuation = nil
    self.stateTask?.cancel()
    self.stateTask = nil
    if force {
      self.connection.forceCancel()
    } else {
      self.connection.cancel()
    }
    self.failAllWaiters(error)
  }

  func ensureReady() async throws {
    if self.isClosed {
      throw NetSocketError.closed
    }
    if !self.ready {
      try await self.waitUntilReady()
    }
  }

  private func ensureReadable(_ count: Int) async throws {
    // Check the buffer before the connection state: bytes the peer sent before closing stay readable.
    while self.availableBytes < count {
      try Task.checkCancellation()
      if self.isClosed {
        // Closed with nothing buffered is a clean end of stream; anything less than `count` was cut short.
        if self.availableBytes == 0 {
          throw NetSocketError.closed
        }
        throw NetSocketError.insufficientData(expected: count, got: self.availableBytes)
      }
      try await self.ensureReady()
      do {
        try await self.waitForData()
      } catch NetSocketError.closed {
        // Closed while waiting: go around again so what arrived before the close is reported.
        continue
      }
    }
  }

  private func waitForData() async throws {
    // A read needs more than is buffered, so make sure data is flowing even above the high-water mark.
    self.resumeReceivingIfNeeded(force: true)
    try await self.suspend(.data)
  }

  /// Call after advancing `head`.
  private func didConsume() {
    self.compactIfNeeded()
    self.resumeReceivingIfNeeded()
  }

  private func compactIfNeeded() {
    // Avoid unbounded memory as head advances
    if self.head > 64 * 1024 && self.head > self.buffer.count / 2 {
      self.buffer.removeSubrange(0..<self.head)
      self.head = 0
    }
  }

  /// Drop unread data, and anything still arriving, so nothing more can be read after our own close().
  private func discardBuffer() {
    self.buffer = Data()
    self.head = 0
    self.inputDiscarded = true
  }

  private func search(delimiter: Data) -> Range<Int>? {
    guard !delimiter.isEmpty, self.availableBytes >= delimiter.count else { return nil }
    let hay = self.buffer[self.head..<self.buffer.count]

    // Fast path for single-byte delimiters
    if delimiter.count == 1, let byte = delimiter.first {
      if let idx = hay.firstIndex(of: byte) {
        return idx..<(idx + 1)
      }
      return nil
    }

    // General case
    if let r = hay.firstRange(of: delimiter) {
      return r.lowerBound..<r.upperBound
    }

    return nil
  }

  private func waitUntilReady() async throws {
    guard !self.ready else { return }
    try await self.suspend(.ready)
  }

  private enum WaitReason {
    case data
    case ready
  }

  /// Suspend until data arrives or the connection becomes ready.
  ///
  /// Throws `CancellationError` as soon as the calling task is cancelled, and
  /// `NetSocketError.closed` if the connection has already closed.
  private func suspend(_ reason: WaitReason) async throws {
    let id = self.nextWaiterID
    self.nextWaiterID += 1

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          cont.resume(throwing: CancellationError())
        } else if self.isClosed {
          cont.resume(throwing: NetSocketError.closed)
        } else {
          switch reason {
          case .data: self.dataWaiters[id] = cont
          case .ready: self.readyWaiters[id] = cont
          }
        }
      }
    } onCancel: {
      // Runs off the actor, so hop back on. A no-op if the waiter was already resumed.
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: Int) {
    let waiter = self.dataWaiters.removeValue(forKey: id) ?? self.readyWaiters.removeValue(forKey: id)
    waiter?.resume(throwing: CancellationError())
  }

  private func resumeReadyWaiters(with result: Result<Void, Error>) {
    let waiters = self.readyWaiters.values
    self.readyWaiters.removeAll()
    for w in waiters {
      w.resume(with: result)
    }
  }

  private func failAllWaiters(_ error: Error) {
    self.resumeReadyWaiters(with: .failure(error))
    let waiters = self.dataWaiters.values
    self.dataWaiters.removeAll()
    for w in waiters {
      w.resume(throwing: error)
    }
  }

  private func append(_ data: Data) {
    self.buffer.append(data)
    if self.buffer.count - self.head > self.config.maxBufferBytes {
      // Hard stop: drop connection rather than OOM'ing.
      self.shutdown(.framingExceeded(max: self.config.maxBufferBytes))
      return
    }
    self.resumeDataWaiters()
  }

  private func resumeDataWaiters() {
    let waiters = self.dataWaiters.values
    self.dataWaiters.removeAll()
    for w in waiters { w.resume() }
  }
}
