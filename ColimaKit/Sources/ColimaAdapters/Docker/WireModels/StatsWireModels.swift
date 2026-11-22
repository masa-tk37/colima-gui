import ColimaCore

/// `GET /containers/{id}/stats?stream=false`. An exited container reports zero counters and omits
/// `system_cpu_usage`, `online_cpus` and `memory_stats.usage`; `one-shot` reports a zeroed `precpu_stats`.
struct ContainerStatsWire: Decodable {
  struct CPU: Decodable {
    struct Usage: Decodable {
      let totalUsage: UInt64?

      private enum CodingKeys: String, CodingKey { case totalUsage = "total_usage" }
    }

    let cpuUsage: Usage?
    let systemCPUUsage: UInt64?
    let onlineCPUs: Int?

    private enum CodingKeys: String, CodingKey {
      case cpuUsage = "cpu_usage"
      case systemCPUUsage = "system_cpu_usage"
      case onlineCPUs = "online_cpus"
    }
  }

  struct Memory: Decodable {
    struct Detail: Decodable {
      let inactiveFile: UInt64?

      private enum CodingKeys: String, CodingKey { case inactiveFile = "inactive_file" }
    }

    let usage: UInt64?
    let stats: Detail?
  }

  let cpuStats: CPU?
  let precpuStats: CPU?
  let memoryStats: Memory?

  private enum CodingKeys: String, CodingKey {
    case cpuStats = "cpu_stats"
    case precpuStats = "precpu_stats"
    case memoryStats = "memory_stats"
  }

  func toDomain() -> ContainerStatsSample {
    ContainerStatsSample(
      cpuTotalUsage: cpuStats?.cpuUsage?.totalUsage ?? 0,
      previousCPUTotalUsage: precpuStats?.cpuUsage?.totalUsage ?? 0,
      systemCPUUsage: cpuStats?.systemCPUUsage,
      previousSystemCPUUsage: precpuStats?.systemCPUUsage,
      onlineCPUs: cpuStats?.onlineCPUs,
      memoryUsage: memoryStats?.usage,
      memoryInactiveFile: memoryStats?.stats?.inactiveFile
    )
  }
}
