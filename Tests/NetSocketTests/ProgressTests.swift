import Foundation
@testable import NetSocket
import Testing

@Suite("TransferRateEstimator")
struct TransferRateEstimatorTests {
  @Test func noEstimateUntilEnoughSamples() {
    var estimator = TransferRateEstimator(total: 10_000, minElapsedTime: 100, minSamples: 3)
    let start = ContinuousClock.now

    // The first update only sets the start time; each one after is a rate sample.
    #expect(estimator.update(bytes: 1000, at: start).bytesPerSecond == nil)
    #expect(estimator.update(bytes: 1000, at: start + .seconds(1)).bytesPerSecond == nil)
    #expect(estimator.update(bytes: 1000, at: start + .seconds(2)).bytesPerSecond == nil)

    let progress = estimator.update(bytes: 1000, at: start + .seconds(3))
    #expect(progress.bytesPerSecond == 1000)
    #expect(progress.estimatedTimeRemaining == 6)
    #expect(progress.sent == 4000)
    #expect(progress.now == 1000)
    #expect(progress.progress == 0.4)
  }

  @Test func estimateAfterMinElapsedTime() {
    var estimator = TransferRateEstimator(total: nil, minElapsedTime: 2, minSamples: 100)
    let start = ContinuousClock.now

    estimator.update(bytes: 500, at: start)
    #expect(estimator.update(bytes: 500, at: start + .seconds(1)).bytesPerSecond == nil)

    let progress = estimator.update(bytes: 500, at: start + .seconds(2))
    #expect(progress.bytesPerSecond == 500)
    // No total, so no time remaining
    #expect(progress.estimatedTimeRemaining == nil)
    #expect(progress.progress == 0)
  }

  @Test func smoothsChangesInRate() {
    var estimator = TransferRateEstimator(total: nil, alpha: 0.5, minElapsedTime: 0, minSamples: 0)
    let start = ContinuousClock.now

    estimator.update(bytes: 0, at: start)
    #expect(estimator.update(bytes: 1000, at: start + .seconds(1)).bytesPerSecond == 1000)
    #expect(estimator.update(bytes: 3000, at: start + .seconds(2)).bytesPerSecond == 2000)
  }

  @Test func updateToRunningTotal() {
    var estimator = TransferRateEstimator(total: 1000)
    #expect(estimator.update(total: 500).sent == 500)
    // A smaller total never moves progress backwards.
    #expect(estimator.update(total: 400).sent == 500)
    #expect(estimator.update(total: 1000).progress == 1)
    #expect(estimator.transferred == 1000)
  }

  @Test func noTimeRemainingWhenDone() {
    var estimator = TransferRateEstimator(total: 2000, minElapsedTime: 0, minSamples: 0)
    let start = ContinuousClock.now
    estimator.update(bytes: 1000, at: start)
    #expect(estimator.update(bytes: 1000, at: start + .seconds(1)).estimatedTimeRemaining == 0)
  }
}

@Suite("FileProgress")
struct FileProgressTests {
  @Test func progressFraction() {
    #expect(NetSocket.FileProgress(sent: 50, total: 200).progress == 0.25)
    #expect(NetSocket.FileProgress(sent: 300, total: 200).progress == 1)
    #expect(NetSocket.FileProgress(sent: 0, total: 0).progress == 1)
    #expect(NetSocket.FileProgress(sent: 10, total: nil).progress == 0)
  }

  static let speeds: [Double] = [500, 45 * 1024, 2.5 * 1024 * 1024, 1.5 * 1024 * 1024 * 1024]
  static let formattedSpeeds: [String] = ["500B/sec", "45KB/sec", "2.5MB/sec", "1.5GB/sec"]

  @Test(arguments: zip(speeds, formattedSpeeds))
  func formattedSpeed(bytesPerSecond: Double, expected: String) {
    #expect(NetSocket.FileProgress(sent: 0, total: nil, bytesPerSecond: bytesPerSecond).formattedSpeed == expected)
  }

  @Test func formattedSpeedIsNilWithoutARate() {
    #expect(NetSocket.FileProgress(sent: 0, total: nil).formattedSpeed == nil)
    #expect(NetSocket.FileProgress(sent: 0, total: nil, bytesPerSecond: 0).formattedSpeed == nil)
  }
}
