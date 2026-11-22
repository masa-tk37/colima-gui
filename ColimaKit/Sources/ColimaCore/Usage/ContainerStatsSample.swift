/// The numbers of one `stats?stream=false` response that the CPU and memory figures derive from.
public struct ContainerStatsSample: Sendable, Equatable {
  public let cpuTotalUsage: UInt64
  public let previousCPUTotalUsage: UInt64
  public let systemCPUUsage: UInt64?
  public let previousSystemCPUUsage: UInt64?
  public let onlineCPUs: Int?
  public let memoryUsage: UInt64?
  public let memoryInactiveFile: UInt64?

  public init(
    cpuTotalUsage: UInt64,
    previousCPUTotalUsage: UInt64,
    systemCPUUsage: UInt64?,
    previousSystemCPUUsage: UInt64?,
    onlineCPUs: Int?,
    memoryUsage: UInt64?,
    memoryInactiveFile: UInt64?
  ) {
    self.cpuTotalUsage = cpuTotalUsage
    self.previousCPUTotalUsage = previousCPUTotalUsage
    self.systemCPUUsage = systemCPUUsage
    self.previousSystemCPUUsage = previousSystemCPUUsage
    self.onlineCPUs = onlineCPUs
    self.memoryUsage = memoryUsage
    self.memoryInactiveFile = memoryInactiveFile
  }

  /// One fully used core is 100, so it can exceed 100. `nil` (a gap) on the first sample or a `one-shot` read
  /// (no previous), and for an exited container, where the engine omits `system_cpu_usage` / `online_cpus`.
  public var cpuPercent: Double? {
    guard let system = systemCPUUsage,
      let previousSystem = previousSystemCPUUsage, previousSystem > 0,
      let cpus = onlineCPUs, cpus > 0,
      cpuTotalUsage >= previousCPUTotalUsage,
      system > previousSystem
    else { return nil }
    let cpuDelta = Double(cpuTotalUsage - previousCPUTotalUsage)
    let systemDelta = Double(system - previousSystem)
    return cpuDelta / systemDelta * Double(cpus) * 100
  }

  /// Usage minus the reclaimable page cache (cgroup v2 `inactive_file`), subtracted only while it is
  /// below usage, as `docker stats` does.
  public var memoryBytes: UInt64? {
    guard let usage = memoryUsage else { return nil }
    guard let inactive = memoryInactiveFile, inactive < usage else { return usage }
    return usage - inactive
  }
}
