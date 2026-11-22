import ColimaCore
import Foundation

struct VolumeListWire: Decodable {
  let volumes: [VolumeWire]

  private enum CodingKeys: String, CodingKey { case volumes = "Volumes" }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    volumes = try container.decodeIfPresent([VolumeWire].self, forKey: .volumes) ?? []
  }

  func toDomain() -> [VolumeSummary] {
    volumes.map { $0.toDomain() }
  }
}

struct VolumeWire: Decodable {
  let name: String
  let driver: String
  let createdAt: Date?
  let labels: [String: String]?

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case driver = "Driver"
    case createdAt = "CreatedAt"
    case labels = "Labels"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    driver = try container.decode(String.self, forKey: .driver)
    createdAt = try container.decodeIfPresent(WireTimestamp.self, forKey: .createdAt)?.date
    labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
  }

  func toDomain() -> VolumeSummary {
    VolumeSummary(name: name, driver: driver, createdAt: createdAt, labels: labels)
  }
}

/// `GET /system/df?type=volume&verbose=true`. Only `VolumeUsage.Items[].UsageData.Size` is read; whether a volume
/// is in use comes from the `dangling` filter on the list instead.
struct SystemDfVolumesWire: Decodable {
  let items: [VolumeUsageItemWire]

  private enum CodingKeys: String, CodingKey { case volumeUsage = "VolumeUsage" }
  private enum UsageKeys: String, CodingKey { case items = "Items" }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.volumeUsage), try !container.decodeNil(forKey: .volumeUsage) else {
      items = []
      return
    }
    let usage = try container.nestedContainer(keyedBy: UsageKeys.self, forKey: .volumeUsage)
    items = try usage.decodeIfPresent([VolumeUsageItemWire].self, forKey: .items) ?? []
  }

  func toDomain() -> [String: VolumeSize] {
    Dictionary(items.map { ($0.name, $0.size) }, uniquingKeysWith: { _, last in last })
  }
}

struct VolumeUsageItemWire: Decodable {
  let name: String
  let size: VolumeSize

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case usageData = "UsageData"
  }
  private enum UsageDataKeys: String, CodingKey { case size = "Size" }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    // The engine reports -1 when it could not measure a volume; a missing UsageData means the same to the UI.
    guard container.contains(.usageData), try !container.decodeNil(forKey: .usageData) else {
      size = .unknown
      return
    }
    let usage = try container.nestedContainer(keyedBy: UsageDataKeys.self, forKey: .usageData)
    size =
      try usage.decodeIfPresent(Int64.self, forKey: .size).map(VolumeSize.init(dockerSize:))
      ?? .unknown
  }
}
