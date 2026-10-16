import Network
@testable import NetSocket
import os
import Testing

@Suite("TLSPolicy")
struct TLSPolicyTests {
  @Test func disabledIsPlainTCP() {
    let parameters = TLSPolicy.disabled.makeParameters()
    #expect(!TLSPolicy.disabled.enabled)
    #expect(!parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
  }

  @Test func enabledAddsTLSAndRunsConfigure() {
    let configured = OSAllocatedUnfairLock(initialState: false)
    let policy = TLSPolicy.enabled { _ in configured.withLock { $0 = true } }
    let parameters = policy.makeParameters()

    #expect(policy.enabled)
    #expect(configured.withLock { $0 })
    #expect(parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
  }
}
