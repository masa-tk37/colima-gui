import Foundation

extension VMCommand: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, cpus, memoryGiB, diskGiB, vmType
  }

  private enum Kind: String, Codable {
    case start, stop, delete, create
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .start: self = .start
    case .stop: self = .stop
    case .delete: self = .delete
    case .create:
      let cpus = try container.decode(Int.self, forKey: .cpus)
      let memoryGiB = try container.decode(Double.self, forKey: .memoryGiB)
      let diskGiB = try container.decode(Int.self, forKey: .diskGiB)
      let vmType = try container.decode(VMType.self, forKey: .vmType)
      // A decoded spec reaches `colima start` without another check, so it must meet `VMSettingsValidator`'s ranges.
      // The numbers are checked directly: the validator's text parsing rejects exponent notation,
      // and its localized messages would load a resource bundle the agent does not ship.
      guard cpus >= 1, memoryGiB.isFinite, memoryGiB >= 1, diskGiB >= 1 else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind, in: container, debugDescription: "create resources out of range")
      }
      self = .create(
        VMCreateSpec(
          resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
          vmType: vmType))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .start: try container.encode(Kind.start, forKey: .kind)
    case .stop: try container.encode(Kind.stop, forKey: .kind)
    case .delete: try container.encode(Kind.delete, forKey: .kind)
    case .create(let spec):
      try container.encode(Kind.create, forKey: .kind)
      try container.encode(spec.resources.cpus, forKey: .cpus)
      try container.encode(spec.resources.memoryGiB, forKey: .memoryGiB)
      try container.encode(spec.resources.diskGiB, forKey: .diskGiB)
      try container.encode(spec.vmType, forKey: .vmType)
    }
  }
}
