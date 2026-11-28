import Foundation

public struct MachineFormInput: Sendable, Equatable {
  public var name: String
  public var templateID: String?
  public var cpus: String
  public var memoryGiB: String
  public var diskGiB: String

  public init(name: String, templateID: String?, cpus: String, memoryGiB: String, diskGiB: String) {
    self.name = name
    self.templateID = templateID
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    self.diskGiB = diskGiB
  }

  public static func defaults(firstTemplateID: String?) -> MachineFormInput {
    MachineFormInput(name: "", templateID: firstTemplateID, cpus: "2", memoryGiB: "4", diskGiB: "100")
  }
}

public struct MachineEditInput: Sendable, Equatable {
  public var cpus: String
  public var memoryGiB: String
  public var diskGiB: String
  public var mounts: [MachineMount]

  public init(cpus: String, memoryGiB: String, diskGiB: String, mounts: [MachineMount]) {
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    self.diskGiB = diskGiB
    self.mounts = mounts
  }
}

public struct MachineCreateContext: Sendable {
  public let host: HostResources
  public let homeDirectory: String
  public let limaHomeUTF8Count: Int
  public let appMachineKeys: Set<MachineKey>
  public let unownedMachineKeys: Set<MachineKey>
  public let templates: [MachineTemplate]

  public init(
    host: HostResources, homeDirectory: String, limaHomeUTF8Count: Int,
    appMachineKeys: Set<MachineKey>, unownedMachineKeys: Set<MachineKey>, templates: [MachineTemplate]
  ) {
    self.host = host
    self.homeDirectory = homeDirectory
    self.limaHomeUTF8Count = limaHomeUTF8Count
    self.appMachineKeys = appMachineKeys
    self.unownedMachineKeys = unownedMachineKeys
    self.templates = templates
  }
}
