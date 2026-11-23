import Dispatch
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
}
