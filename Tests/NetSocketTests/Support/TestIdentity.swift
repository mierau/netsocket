import Foundation
import Network
import NetSocket
import Security
import Testing

/// A throwaway certificate and private key for TLS tests, which only ever live in memory
///
/// The certificate is self-signed, for "NetSocket Test", with a P-256 key, and good until 2126.
/// It was made with:
///
/// ```
/// openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
///   -keyout key.pem -out cert.pem -days 36500 -subj "/CN=NetSocket Test"
/// openssl pkcs12 -export -inkey key.pem -in cert.pem -name "NetSocket Test" \
///   -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout pass:netsocket -out identity.p12
/// base64 -b 96 -i identity.p12
/// ```
///
/// Importing into memory only needs macOS 15 or iOS 18. Before that, macOS would add it to the
/// login keychain.
@available(macOS 15, iOS 18, tvOS 18, visionOS 2, *)
struct TestIdentity {
  let identity: SecIdentity
  let certificate: SecCertificate

  init() throws {
    let data = try #require(Data(base64Encoded: Self.pkcs12, options: .ignoreUnknownCharacters))
    let options = [
      kSecImportExportPassphrase as String: "netsocket",
      kSecImportToMemoryOnly as String: true,
    ] as CFDictionary
    var items: CFArray?
    let status = SecPKCS12Import(data as CFData, options, &items)
    try #require(status == errSecSuccess, "SecPKCS12Import failed with \(status)")

    let item = try #require((items as? [[String: Any]])?.first)
    let value = try #require(item[kSecImportItemIdentity as String] as CFTypeRef?)
    try #require(CFGetTypeID(value) == SecIdentityGetTypeID())
    self.identity = value as! SecIdentity

    var certificate: SecCertificate?
    try #require(SecIdentityCopyCertificate(self.identity, &certificate) == errSecSuccess)
    self.certificate = try #require(certificate)
  }

  private static let pkcs12 = """
    MIID0wIBAzCCA5EGCSqGSIb3DQEHAaCCA4IEggN+MIIDejCCAj8GCSqGSIb3DQEHBqCCAjAwggIsAgEAMIICJQYJKoZIhvcN
    AQcBMBwGCiqGSIb3DQEMAQMwDgQIjuGNEpORz2ECAggAgIIB+AoSGnrRcaM0DN/LmGStbXYXyEdCiNN9yA0bapCTanIWJMC+
    fGTnDAixyVVUFfhCPckaXF/hyuYGExO2jjPN6I111H3Dsw0BV0sxAaKJTplf+xr0fXJ58mxXn/84xytLKq3qOYbwaHoeaqT7
    lV8R7bHSCe7C0iD3DaSXINbFslr+aEux8AB1Aulezoi3X16rTTCuHfal6B4J8v7iYYZVUkwDMRZY2sUGTSpO5j40nO6LAVs2
    52CK68iCrCcJdqTWnAMNHsrbuThGHrW7rpJ3LC2FhUd7C/l097FUM3jgunJzJoL/q+rgtz/952nlbLp08m3IORbmFjDb9HZ2
    lpYOZu2KuP7pekU3R9r7BD5wVdBkz+bNg5INBgL3qpYiuxAR++mIjRYQ0Udf5F3qTiZ7JpZLkYa5ufDjbd7Qf53l4pSUPVuv
    k5ElGdMkdHQxYtVKUFwp9DYUG6XJVLgVL3GJnEvIu/mv+rWcxD35S9J9dLzPcOJt4A6xAO+XZKuT7m2LmOdkOPmf6g1U7/ez
    LCDtyHAvsTYej8ZbIZOEqIKjrIonMz1LGVA8NDvEvSWhmJC4nYTP+wD4nsA2iOzmJwzjUQi/+eE+RPDc1UqNO5/w6upgI7j2
    A73bpiAu7sWtZwVTGG+DrtTRp5DQAFMhOTqavNrn5Lht80MQ+TCCATMGCSqGSIb3DQEHAaCCASQEggEgMIIBHDCCARgGCyqG
    SIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQIEqNm/oLf1vkCAggABIGQBDCnTD1PJm+vp/dGfB3IjF5tLw7ZDWmX
    n5U/vjO1YhofFOTt1l0ru/CYcnLFlXj3fKMa/zACF2TuK0Xgm8C2woi4cpsceD8v+VM/HTTzni9h754tOVPqqOrTGoomiYxS
    ljK7TGki+2v8S6i3EDkbf68QortL1GGS5HQGecQZiK+9DqMNKr5HYttap6f3HZSmMVIwIwYJKoZIhvcNAQkVMRYEFDlXsDLg
    kxReqsrIiETPL2xMGxhpMCsGCSqGSIb3DQEJFDEeHhwATgBlAHQAUwBvAGMAawBlAHQAIABUAGUAcwB0MDkwITAJBgUrDgMC
    GgUABBRb+CVk/eSy3GW2LgPqnE0iqyftoQQQr7yZo6WMtazBajuDBhWveQICCAA=
    """
}

extension TLSPolicy {
  /// TLS that trusts `certificate` and nothing else, as a client that pinned it would
  static func trusting(_ certificate: SecCertificate) -> TLSPolicy {
    let expected = SecCertificateCopyData(certificate) as Data
    return .enabled { options in
      sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
        let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
        complete(chain?.first.map { SecCertificateCopyData($0) as Data } == expected)
      }, DispatchQueue(label: "TLSPolicy.trusting"))
    }
  }
}

extension NetSocketError {
  /// Whether the connection failed in its TLS handshake
  var isTLSFailure: Bool {
    guard case .failed(let underlying as NWError) = self, case .tls = underlying else {
      return false
    }
    return true
  }
}
