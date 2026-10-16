// NetSocket: NetSocketEncodable & NetSocketDecodable
// Dustin Mierau • @mierau
// MIT License

import Foundation

/// A message that encodes itself into bytes, sent in one write by ``NetSocket/send(_:endian:)``
///
/// ```swift
/// struct Ping: NetSocketEncodable {
///   let id: UInt32
///
///   func encode(endian: Endian) throws -> Data {
///     let value = endian == .big ? id.bigEndian : id.littleEndian
///     return withUnsafeBytes(of: value) { Data($0) }
///   }
/// }
///
/// try await socket.send(Ping(id: 1))
/// ```
public protocol NetSocketEncodable: Sendable {
  /// The whole message as bytes, with multi-byte values in `endian` order
  func encode(endian: Endian) throws -> Data
}

/// A message that decodes itself by reading its fields straight from the socket
///
/// Reads wait for data to arrive, so a message can be parsed one field at a time without
/// knowing its size up front. If decoding throws partway through, the bytes it already read
/// are gone and the stream is out of sync, so the connection should usually be closed.
///
/// ```swift
/// struct Greeting: NetSocketDecodable {
///   let id: UInt32
///   let name: String
///
///   init(from socket: NetSocket, endian: Endian) async throws {
///     self.id = try await socket.read(UInt32.self, endian: endian)
///     let nameLength = try await socket.read(UInt16.self, endian: endian)
///     self.name = try await socket.read(Int(nameLength), encoding: .utf8)
///   }
/// }
///
/// let greeting = try await socket.receive(Greeting.self)
/// ```
public protocol NetSocketDecodable: Sendable {
  /// Read this value's fields from `socket`, with multi-byte values in `endian` order
  init(from socket: NetSocket, endian: Endian) async throws
}

public extension NetSocket {
  /// Encode `value` and send it in one write
  func send<T: NetSocketEncodable>(_ value: T, endian: Endian = .big) async throws {
    let data = try value.encode(endian: endian)
    try await self.write(data)
  }

  /// Read a `T` by letting it decode its own fields from the socket
  func receive<T: NetSocketDecodable>(_ type: T.Type, endian: Endian = .big) async throws -> T {
    return try await T(from: self, endian: endian)
  }
}
