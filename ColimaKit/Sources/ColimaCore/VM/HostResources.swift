import Foundation

public struct HostResources: Sendable, Equatable {
  public let cpus: Int
  public let memoryGiB: Int
  public let diskGiB: Int

  public init(cpus: Int, memoryGiB: Int, diskGiB: Int) {
    self.cpus = max(1, cpus)
    self.memoryGiB = max(1, memoryGiB)
    self.diskGiB = max(1, diskGiB)
  }

  /// The disk is the capacity of the volume holding the home directory, where Colima keeps its disks.
  public static let current: HostResources = {
    let info = ProcessInfo.processInfo
    let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    let volumeBytes = (try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0
    return HostResources(
      cpus: info.activeProcessorCount,
      memoryGiB: Int(info.physicalMemory >> 30),
      diskGiB: volumeBytes >> 30)
  }()
}
