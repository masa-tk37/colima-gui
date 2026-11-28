import Foundation

public struct MachineResources: Sendable, Equatable {
  public let cpus: Int
  public let memoryGiB: Double
  public let diskGiB: Int

  init(cpus: Int, memoryGiB: Double, diskGiB: Int) {
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    self.diskGiB = diskGiB
  }
}

public struct MachineMount: Sendable, Hashable, Codable {
  public let path: String
  public let writable: Bool
  /// The guest path of a mount Lima already holds (from `~/.lima/_config`, for example); nil means it equals `path`.
  /// An edit writes the whole mount list back, so it has to carry what the user did not touch.
  public let mountPoint: String?

  public init(path: String, writable: Bool, mountPoint: String? = nil) {
    self.path = path
    self.writable = writable
    self.mountPoint = mountPoint == path ? nil : mountPoint
  }
}

public struct MachineCreateSpec: Sendable, Equatable {
  public let name: MachineName
  public let template: MachineTemplate
  public let resources: MachineResources
  public let mounts: [MachineMount]

  init(name: MachineName, template: MachineTemplate, resources: MachineResources, mounts: [MachineMount]) {
    self.name = name
    self.template = template
    self.resources = resources
    self.mounts = mounts
  }
}

public struct MachineEditSpec: Sendable, Equatable {
  public let resources: MachineResources
  public let mounts: [MachineMount]

  init(resources: MachineResources, mounts: [MachineMount]) {
    self.resources = resources
    self.mounts = mounts
  }
}

public enum MachineField: Sendable, Hashable { case name, template, cpu, memory, disk, mount(index: Int) }

public struct MachineFieldError: Sendable, Equatable {
  public let field: MachineField
  public let message: String

  public init(field: MachineField, message: String) {
    self.field = field
    self.message = message
  }
}

public struct MachineValidationFailure: Error, Equatable {
  public let fields: [MachineFieldError]
}
