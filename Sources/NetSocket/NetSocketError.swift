// NetSocket: NetSocketError
// Dustin Mierau • @mierau
// MIT License

import Foundation

/// Errors thrown by ``NetSocket``
public enum NetSocketError: Error, CustomStringConvertible, LocalizedError, Sendable {
  /// The connection isn't ready yet
  case notReady
  /// The connection is closed, by us or the peer
  case closed
  /// The port number is out of range
  case invalidPort
  /// The underlying connection failed
  case failed(underlying: Error)
  /// The connection closed partway through a read of `expected` bytes
  case insufficientData(expected: Int, got: Int)
  /// `max` bytes arrived without a delimiter, or without being read
  case framingExceeded(max: Int)
  /// Received data couldn't be decoded
  case decodeFailed(Error)
  /// Data couldn't be encoded for sending
  case encodeFailed(Error)
  /// A string can't be represented in the requested encoding
  case stringEncodingFailed(String.Encoding)
  /// Received bytes aren't valid in the requested encoding
  case stringDecodingFailed(String.Encoding)
  /// The file to send isn't a regular file, or its size can't be read
  case invalidFile(URL)
  /// The file being sent ended before the expected length
  case fileEndedEarly(expected: Int, got: Int)

  public var description: String {
    switch self {
    case .notReady: return "Connection not ready."
    case .closed: return "Connection closed."
    case .invalidPort: return "Invalid port number."
    case .failed(let e): return "Network failure: \(e.localizedDescription)"
    case .insufficientData(let exp, let got): return "Insufficient data: need \(exp), have \(got)."
    case .framingExceeded(let max): return "Frame length exceeded maximum \(max)."
    case .decodeFailed(let e): return "Decoding failed: \(e)"
    case .encodeFailed(let e): return "Encoding failed: \(e)"
    case .stringEncodingFailed(let encoding): return "Can't encode string as \(encoding)."
    case .stringDecodingFailed(let encoding): return "Received bytes aren't valid \(encoding)."
    case .invalidFile(let url): return "Not a readable file: \(url.path(percentEncoded: false))."
    case .fileEndedEarly(let exp, let got): return "File ended after \(got) of \(exp) bytes."
    }
  }

  public var errorDescription: String? { self.description }
}
