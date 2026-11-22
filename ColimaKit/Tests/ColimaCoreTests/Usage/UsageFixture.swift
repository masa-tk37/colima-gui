import Foundation
import Testing

@testable import ColimaCore

enum UsageFixture {
  static func text(_ name: String, extension ext: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext))
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func procSnapshot(_ name: String) throws -> ProcSnapshot {
    try ProcSnapshot.parse(text(name, extension: "txt"))
  }

  /// Decoded here because ColimaCoreTests does not depend on ColimaAdapters, where the production decoder lives.
  static func statsSample(_ name: String) throws -> ContainerStatsSample {
    let url = try #require(
      Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let wire = try decoder.decode(Wire.self, from: Data(contentsOf: url))
    return ContainerStatsSample(
      cpuTotalUsage: wire.cpuStats.cpuUsage.totalUsage,
      previousCPUTotalUsage: wire.precpuStats.cpuUsage.totalUsage,
      systemCPUUsage: wire.cpuStats.systemCpuUsage,
      previousSystemCPUUsage: wire.precpuStats.systemCpuUsage,
      onlineCPUs: wire.cpuStats.onlineCpus,
      memoryUsage: wire.memoryStats.usage,
      memoryInactiveFile: wire.memoryStats.stats?.inactiveFile
    )
  }

  private struct Wire: Decodable {
    struct CPU: Decodable {
      struct Usage: Decodable { let totalUsage: UInt64 }
      let cpuUsage: Usage
      let systemCpuUsage: UInt64?
      let onlineCpus: Int?
    }
    struct Memory: Decodable {
      struct Stats: Decodable { let inactiveFile: UInt64? }
      let usage: UInt64?
      let stats: Stats?
    }
    let cpuStats: CPU
    let precpuStats: CPU
    let memoryStats: Memory
  }
}
