// NetSocket: Delimiter
// Dustin Mierau • @mierau
// MIT License

import Foundation

/// Bytes that end a record in line- or null-terminated protocols
public enum Delimiter: Sendable, Hashable {
  /// Any single byte
  case byte(UInt8)
  /// 0x00
  case zeroByte
  /// `\n` (0x0A)
  case lineFeed
  /// `\r\n` (0x0D 0x0A)
  case carriageReturnLineFeed

  /// The delimiter's bytes
  public var data: Data {
    switch self {
    case .byte(let b): return Data([b])
    case .zeroByte: return Data([0x00])
    case .lineFeed: return Data([0x0A])
    case .carriageReturnLineFeed: return Data([0x0D, 0x0A])
    }
  }
}
