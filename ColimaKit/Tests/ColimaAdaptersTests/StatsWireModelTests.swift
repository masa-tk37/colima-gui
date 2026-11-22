import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func sample(_ fixture: String) throws -> ContainerStatsSample {
  try JSONDecoder().decode(ContainerStatsWire.self, from: try wireFixture(fixture)).toDomain()
}

@Test func runningStatsCarryPreviousReadAndInactiveFile() throws {
  let stats = try sample("docker-container-stats-running.json")

  #expect(
    stats
      == ContainerStatsSample(
        cpuTotalUsage: 10_083_344_000,
        previousCPUTotalUsage: 9_033_070_000,
        systemCPUUsage: 976_070_600_000_000,
        previousSystemCPUUsage: 976_060_520_000_000,
        onlineCPUs: 10,
        memoryUsage: 4_747_264,
        memoryInactiveFile: 4096))
  #expect(stats.memoryBytes == 4_743_168)
  let cpu = try #require(stats.cpuPercent)
  #expect(abs(cpu - (1_050_274_000.0 / 10_080_000_000.0 * 10 * 100)) < 0.0001)
}

@Test func oneShotStatsHavePreviousCountersAtZeroAndNoCPUPercent() throws {
  let stats = try sample("docker-container-stats-running-oneshot.json")

  #expect(stats.previousCPUTotalUsage == 0)
  #expect(stats.previousSystemCPUUsage == nil)
  #expect(stats.cpuTotalUsage == 10_110_861_000)
  #expect(stats.memoryUsage == 3_989_504)
  #expect(stats.cpuPercent == nil)
}

@Test func exitedContainerStatsDecodeWithMissingFieldsAsNil() throws {
  let stats = try sample("docker-container-stats-exited.json")

  #expect(
    stats
      == ContainerStatsSample(
        cpuTotalUsage: 0, previousCPUTotalUsage: 0,
        systemCPUUsage: nil, previousSystemCPUUsage: nil,
        onlineCPUs: nil, memoryUsage: nil, memoryInactiveFile: nil))
  #expect(stats.cpuPercent == nil)
  #expect(stats.memoryBytes == nil)
}

@Test func statsWithoutAnySectionDecodeAsEmptySample() throws {
  let stats = try JSONDecoder().decode(ContainerStatsWire.self, from: Data("{}".utf8)).toDomain()

  #expect(stats.cpuTotalUsage == 0)
  #expect(stats.memoryUsage == nil)
}

@Test func statsKeepFullUInt64Range() throws {
  let json =
    #"{"cpu_stats":{"cpu_usage":{"total_usage":18446744073709551615}},"memory_stats":{"usage":9007199254740993}}"#
  let stats = try JSONDecoder().decode(ContainerStatsWire.self, from: Data(json.utf8)).toDomain()

  #expect(stats.cpuTotalUsage == UInt64.max)
  #expect(stats.memoryUsage == 9_007_199_254_740_993)
}
