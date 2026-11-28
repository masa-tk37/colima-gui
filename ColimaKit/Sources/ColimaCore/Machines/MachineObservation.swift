import Foundation

public enum MachineRunState: Sendable, Equatable {
  case running
  case stopped
  case broken(errors: [String])
  case other(rawStatus: String)
}

public struct MachineInstance: Sendable, Equatable {
  public let name: MachineName
  public let runState: MachineRunState
  public let cpus: Int
  public let memoryBytes: Int64
  public let diskBytes: Int64
  /// Effective mounts, including ones merged from `~/.lima/_config`.
  public let mounts: [MachineMount]
  public let templateID: String?

  public init(
    name: MachineName, runState: MachineRunState, cpus: Int, memoryBytes: Int64, diskBytes: Int64,
    mounts: [MachineMount], templateID: String?
  ) {
    self.name = name
    self.runState = runState
    self.cpus = cpus
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.mounts = mounts
    self.templateID = templateID
  }

  public static func broken(name: MachineName, errors: [String]) -> MachineInstance {
    MachineInstance(
      name: name, runState: .broken(errors: errors), cpus: 0, memoryBytes: 0, diskBytes: 0,
      mounts: [], templateID: nil)
  }
}

public struct LimaListing: Sendable, Equatable {
  public let machines: [MachineInstance]
  /// Instances without the marker whose name has the prefix in any case; they block a create with the same name.
  public let unownedMachineKeys: Set<MachineKey>

  public init(machines: [MachineInstance], unownedMachineKeys: Set<MachineKey>) {
    self.machines = machines
    self.unownedMachineKeys = unownedMachineKeys
  }
}

public enum MachineDisplayState: Sendable, Equatable {
  case creating, starting, stopping, deleting, saving
  case running, stopped
  case broken(errors: [String])
  case other(rawStatus: String)
}
