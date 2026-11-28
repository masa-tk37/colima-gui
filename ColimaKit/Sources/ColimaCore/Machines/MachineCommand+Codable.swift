import Foundation

/// The wire form carries the display name; `MachineName.instanceName` adds the prefix only when argv is built, so a
/// decoded command can never address an instance the app does not own.
extension MachineCommand: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, name, template, cpus, memoryGiB, diskGiB, mounts
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(MachineOperationKind.self, forKey: .kind)
    let name = try Self.decodeName(container)
    switch kind {
    case .start: self = .start(name)
    case .stop: self = .stop(name)
    case .delete: self = .delete(name)
    case .create:
      let templateID = try container.decode(String.self, forKey: .template)
      guard let template = MachineTemplate(id: templateID) else {
        throw DecodingError.dataCorruptedError(
          forKey: .template, in: container, debugDescription: "template is not in the allow-list")
      }
      self = .create(
        MachineCreateSpec(
          name: name, template: template, resources: try Self.decodeResources(container),
          mounts: try Self.decodeMounts(container)))
    case .edit:
      self = .edit(
        name,
        MachineEditSpec(resources: try Self.decodeResources(container), mounts: try Self.decodeMounts(container)))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(name.rawValue, forKey: .name)
    switch self {
    case .create(let spec):
      try container.encode(spec.template.id, forKey: .template)
      try Self.encode(spec.resources, mounts: spec.mounts, into: &container)
    case .edit(_, let spec):
      try Self.encode(spec.resources, mounts: spec.mounts, into: &container)
    case .start, .stop, .delete:
      break
    }
  }

  private static func encode(
    _ resources: MachineResources, mounts: [MachineMount], into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(resources.cpus, forKey: .cpus)
    try container.encode(resources.memoryGiB, forKey: .memoryGiB)
    try container.encode(resources.diskGiB, forKey: .diskGiB)
    try container.encode(mounts, forKey: .mounts)
  }

  /// Checks the character rule and the reserved names only; length is left to limactl for the reason on `MachineName.init(instanceName:)`.
  private static func decodeName(_ container: KeyedDecodingContainer<CodingKeys>) throws -> MachineName {
    let text = try container.decode(String.self, forKey: .name)
    guard let name = MachineName(instanceName: MachineName.instancePrefix + text),
      !MachineName.reservedKeys.contains(name.key)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .name, in: container, debugDescription: "name is invalid or reserved")
    }
    return name
  }

  // These are checked as numbers: `VMSettingsValidator`'s text parsing rejects exponent notation,
  // and its localized messages would load a resource bundle the agent does not ship.
  private static func decodeResources(_ container: KeyedDecodingContainer<CodingKeys>) throws -> MachineResources {
    let cpus = try container.decode(Int.self, forKey: .cpus)
    let memoryGiB = try container.decode(Double.self, forKey: .memoryGiB)
    let diskGiB = try container.decode(Int.self, forKey: .diskGiB)
    guard cpus >= 1, memoryGiB.isFinite, memoryGiB >= 1, diskGiB >= 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .cpus, in: container, debugDescription: "resources out of range")
    }
    return MachineResources(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB)
  }

  /// `{{` is rejected because Lima expands `location` as a Go template.
  private static func decodeMounts(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [MachineMount] {
    let mounts = try container.decode([MachineMount].self, forKey: .mounts)
    func isSafe(_ path: String) -> Bool { path.hasPrefix("/") && !path.contains("{{") }
    guard mounts.allSatisfy({ isSafe($0.path) && ($0.mountPoint.map(isSafe) ?? true) }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .mounts, in: container, debugDescription: "mount paths must be absolute and free of \"{{\"")
    }
    return mounts
  }
}
