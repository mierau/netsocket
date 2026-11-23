// NetSocket: TLSPolicy
// Dustin Mierau • @mierau
// MIT License

import Network
import Security

/// Whether a connection uses TLS, and how it's set up
///
/// ```swift
/// let socket = try await NetSocket.connect(host: "example.com", port: 443, tls: .enabled())
///
/// // Adjust the TLS options, for example to pin a minimum version
/// let pinned = try await NetSocket.connect(host: "example.com", port: 443, tls: .enabled { options in
///   sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
/// })
///
/// // Take TLS connections, answering with a certificate and its private key
/// let listener = try await NetSocket.listen(port: 5600, tls: .server(identity: identity))
/// ```
public struct TLSPolicy: Sendable {
  /// Use TLS, optionally adjusting its options before connecting
  public static func enabled(_ configure: (@Sendable (NWProtocolTLS.Options) -> Void)? = nil) -> TLSPolicy {
    TLSPolicy(enabled: true, configure: configure)
  }

  /// TLS for taking connections, answering with `identity`, a certificate and its private key
  ///
  /// `configure` can adjust the options further, as with ``enabled(_:)``.
  ///
  /// - Throws: ``NetSocketError/invalidIdentity`` if `identity` is missing its certificate or
  ///   private key. Checking here means a bad identity fails before listening, rather than in
  ///   every client's handshake.
  public static func server(identity: SecIdentity, _ configure: (@Sendable (NWProtocolTLS.Options) -> Void)? = nil) throws -> TLSPolicy {
    var certificate: SecCertificate?
    var privateKey: SecKey?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, certificate != nil,
          SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, privateKey != nil,
          let localIdentity = sec_identity_create(identity) else {
      throw NetSocketError.invalidIdentity
    }

    let local = Unchecked(localIdentity)
    return TLSPolicy(enabled: true) { options in
      sec_protocol_options_set_local_identity(options.securityProtocolOptions, local.value)
      configure?(options)
    }
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

/// Carries a Core Foundation value that's safe to share, like a `SecIdentity`, into a `@Sendable`
/// closure
private struct Unchecked<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
