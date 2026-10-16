// NetSocket: Endian
// Dustin Mierau • @mierau
// MIT License

/// Byte order for multi-byte integers
public enum Endian: Sendable, Hashable {
  /// Most significant byte first (network byte order)
  case big
  /// Least significant byte first
  case little
}
