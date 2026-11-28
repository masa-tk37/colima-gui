import Foundation

public struct HostResources: Sendable, Equatable {
  public let cpus: Int
  public let memoryBytes: Int64
  public let diskGiB: Int

  public var memoryGiB: Int { Int(memoryBytes >> 30) }

  public init(cpus: Int, memoryGiB: Int, diskGiB: Int) {
    self.init(cpus: cpus, memoryBytes: Int64(max(1, memoryGiB)) << 30, diskGiB: diskGiB)
  }

  public init(cpus: Int, memoryBytes: Int64, diskGiB: Int) {
    self.cpus = max(1, cpus)
    self.memoryBytes = max(1 << 30, memoryBytes)
    self.diskGiB = max(1, diskGiB)
  }

  /// The disk is the capacity of the volume holding the home directory, where Colima keeps its disks.
  public static let current: HostResources = {
    let info = ProcessInfo.processInfo
    let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    let volumeBytes = (try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0
    return HostResources(
      cpus: info.activeProcessorCount,
      memoryBytes: Int64(clamping: info.physicalMemory),
      diskGiB: volumeBytes >> 30)
  }()
}
