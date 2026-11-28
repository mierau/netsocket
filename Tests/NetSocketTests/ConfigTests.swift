import Dispatch
import Network
@testable import NetSocket
import Testing

@Suite("Config")
struct ConfigTests {
  @Test func noPriorityLeavesTheQueuesUnspecified() {
    #expect(NetSocket.Config().dispatchQoS == .unspecified)
  }

  @Test func priorityChoosesTheQueuesQualityOfService() {
    let expected: [(TaskPriority, DispatchQoS)] = [
      (.high, .userInitiated),
      (.medium, .default),
      (.low, .utility),
      (.background, .background),
      (TaskPriority(rawValue: 20), .utility),
    ]
    var config = NetSocket.Config()
    for (priority, qos) in expected {
      config.priority = priority
      #expect(config.dispatchQoS == qos, "priority \(priority.rawValue)")
    }
  }

  @Test func noDelayAndKeepaliveGoIntoTheTCPOptions() throws {
    var config = NetSocket.Config()
    config.noDelay = true
    config.enableKeepAlive = true
    config.keepAliveIdleTime = 30
    let parameters = NWParameters.tcp
    NetSocket.applyTCPOptions(config, to: parameters)
    let tcp = try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    #expect(tcp.noDelay && tcp.enableKeepalive && tcp.keepaliveIdle == 30)
  }

  @Test func theTCPOptionsAreLeftAsTheyAreByDefault() throws {
    let parameters = NWParameters.tcp
    NetSocket.applyTCPOptions(NetSocket.Config(), to: parameters)
    let tcp = try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    #expect(!tcp.noDelay && !tcp.enableKeepalive)
  }
}
