import Testing

@testable import ColimaCore

@Test func runningStatsGiveCPUPercentOfOneCore() throws {
  let sample = try UsageFixture.statsSample("docker-container-stats-running")
  // (10083344000 - 9033070000) / (976070600000000 - 976060520000000) * 10 cpus * 100
  let percent = try #require(sample.cpuPercent)
  #expect(abs(percent - 1_050_274_000.0 / 10_080_000_000.0 * 10 * 100) < 1e-9)
}

@Test func runningStatsMemorySubtractsInactiveFile() throws {
  let sample = try UsageFixture.statsSample("docker-container-stats-running")
  #expect(sample.memoryBytes == 4_747_264 - 4_096)
}

@Test func oneShotStatsHaveNoCPUButHaveMemory() throws {
  let sample = try UsageFixture.statsSample("docker-container-stats-running-oneshot")
  #expect(sample.cpuPercent == nil)
  #expect(sample.memoryBytes == 3_989_504 - 4_096)
}

@Test func exitedStatsHaveNeitherCPUNorMemory() throws {
  let sample = try UsageFixture.statsSample("docker-container-stats-exited")
  #expect(sample.cpuPercent == nil)
  #expect(sample.memoryBytes == nil)
}

private func sample(
  cpu: UInt64 = 200, previousCPU: UInt64 = 100,
  system: UInt64? = 2_000, previousSystem: UInt64? = 1_000,
  onlineCPUs: Int? = 4,
  memory: UInt64? = 1_000, inactive: UInt64? = 100
) -> ContainerStatsSample {
  ContainerStatsSample(
    cpuTotalUsage: cpu, previousCPUTotalUsage: previousCPU,
    systemCPUUsage: system, previousSystemCPUUsage: previousSystem,
    onlineCPUs: onlineCPUs, memoryUsage: memory, memoryInactiveFile: inactive
  )
}

@Test func cpuPercentScalesWithOnlineCPUs() {
  #expect(sample().cpuPercent == 40)
}

@Test func idleContainerIsZeroPercentNotAGap() {
  #expect(sample(cpu: 100).cpuPercent == 0)
}

@Test func missingOrZeroPreviousSystemUsageIsAGap() {
  #expect(sample(previousSystem: nil).cpuPercent == nil)
  #expect(sample(previousSystem: 0).cpuPercent == nil)
}

@Test func missingSystemUsageOrOnlineCPUsIsAGap() {
  #expect(sample(system: nil).cpuPercent == nil)
  #expect(sample(onlineCPUs: nil).cpuPercent == nil)
  #expect(sample(onlineCPUs: 0).cpuPercent == nil)
}

@Test func unchangedSystemUsageIsAGapNotADivisionByZero() {
  #expect(sample(system: 1_000, previousSystem: 1_000).cpuPercent == nil)
}

@Test func decreasingCountersAreAGap() {
  #expect(sample(cpu: 50, previousCPU: 100).cpuPercent == nil)
  #expect(sample(system: 500, previousSystem: 1_000).cpuPercent == nil)
}

@Test func missingInactiveFileLeavesUsageUntouched() {
  #expect(sample(memory: 1_000, inactive: nil).memoryBytes == 1_000)
}

@Test func inactiveFileNotBelowUsageIsIgnored() {
  // Same rule as `docker stats`: subtract only while inactive_file < usage.
  #expect(sample(memory: 1_000, inactive: 1_000).memoryBytes == 1_000)
  #expect(sample(memory: 1_000, inactive: 2_000).memoryBytes == 1_000)
}

@Test func missingMemoryUsageIsAGap() {
  #expect(sample(memory: nil).memoryBytes == nil)
}
