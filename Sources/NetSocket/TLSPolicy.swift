// NetSocket: TLSPolicy
// Dustin Mierau • @mierau
// MIT License

import Network

/// Whether a connection uses TLS, and how it's set up
///
/// ```swift
/// let socket = try await NetSocket.connect(host: "example.com", port: 443, tls: .enabled())
///
/// // Adjust the TLS options, for example to pin a minimum version
/// let pinned = try await NetSocket.connect(host: "example.com", port: 443, tls: .enabled { options in
///   sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
/// })
/// ```
public struct TLSPolicy: Sendable {
  /// Use TLS, optionally adjusting its options before connecting
  public static func enabled(_ configure: (@Sendable (NWProtocolTLS.Options) -> Void)? = nil) -> TLSPolicy {
    TLSPolicy(enabled: true, configure: configure)
  }

  /// Plain TCP
  public static var disabled: TLSPolicy { TLSPolicy(enabled: false, configure: nil) }

  /// Whether TLS is on
  public let enabled: Bool
  /// Adjusts the TLS options before connecting
  public let configure: (@Sendable (NWProtocolTLS.Options) -> Void)?

  /// TCP parameters, with TLS on top when enabled
  func makeParameters() -> NWParameters {
    guard self.enabled else {
      return .tcp
    }
    let options = NWProtocolTLS.Options()
    self.configure?(options)
    return NWParameters(tls: options)
  }
}
