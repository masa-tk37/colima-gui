import Foundation
import Testing

@testable import ColimaCore

enum DockerFixture {
  /// Decoded here because ColimaCoreTests does not depend on ColimaAdapters, where the production decoders live.
  static func images(_ name: String) throws -> [ImageSummary] {
    let wire = try JSONDecoder().decode([ImageWire].self, from: data(name))
    return wire.map {
      ImageSummary(
        id: $0.id,
        repoTags: $0.repoTags ?? [],
        size: $0.size,
        created: Date(timeIntervalSince1970: $0.created)
      )
    }
  }

  static func volumes(_ name: String) throws -> [VolumeSummary] {
    try JSONDecoder().decode(VolumeListWire.self, from: data(name)).volumes.map(\.summary)
  }

  static func volumeSizes(_ name: String) throws -> [String: VolumeSize] {
    let wire = try JSONDecoder().decode(DiskUsageWire.self, from: data(name))
    return Dictionary(
      uniqueKeysWithValues: wire.volumeUsage.items.map {
        ($0.name, VolumeSize(dockerSize: $0.usageData.size))
      }
    )
  }

  static func networks(_ name: String) throws -> [NetworkSummary] {
    try JSONDecoder().decode([NetworkWire].self, from: data(name)).map(\.summary)
  }

  static func networkDetail(_ name: String) throws -> NetworkDetail {
    let wire = try JSONDecoder().decode(NetworkWire.self, from: data(name))
    let containers = (wire.containers ?? [:]).map { id, endpoint in
      NetworkContainer(
        id: ContainerID(rawValue: id),
        name: endpoint.name,
        ipv4Address: endpoint.ipv4Address.nonEmpty,
        ipv6Address: endpoint.ipv6Address.nonEmpty
      )
    }
    return NetworkDetail(id: NetworkID(rawValue: wire.id), name: wire.name, containers: containers)
  }

  private static func data(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try Data(contentsOf: url)
  }

  private struct ImageWire: Decodable {
    let id: String
    let created: Double
    let size: Int64
    let repoTags: [String]?

    private enum CodingKeys: String, CodingKey {
      case id = "Id"
      case created = "Created"
      case size = "Size"
      case repoTags = "RepoTags"
    }
  }

  private struct VolumeWire: Decodable {
    let name: String
    let driver: String
    let createdAt: String?
    let labels: [String: String]?

    private enum CodingKeys: String, CodingKey {
      case name = "Name"
      case driver = "Driver"
      case createdAt = "CreatedAt"
      case labels = "Labels"
    }

    var summary: VolumeSummary {
      VolumeSummary(
        name: name,
        driver: driver,
        createdAt: createdAt.flatMap { try? Date($0, strategy: .iso8601) },
        labels: labels
      )
    }
  }

  private struct VolumeListWire: Decodable {
    let volumes: [VolumeWire]

    private enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
  }

  private struct DiskUsageWire: Decodable {
    struct Item: Decodable {
      struct Usage: Decodable {
        let size: Int64

        private enum CodingKeys: String, CodingKey { case size = "Size" }
      }
      let name: String
      let usageData: Usage

      private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case usageData = "UsageData"
      }
    }
    struct Volumes: Decodable {
      let items: [Item]

      private enum CodingKeys: String, CodingKey { case items = "Items" }
    }
    let volumeUsage: Volumes

    private enum CodingKeys: String, CodingKey { case volumeUsage = "VolumeUsage" }
  }

  private struct NetworkWire: Decodable {
    struct IPAMWire: Decodable {
      struct ConfigWire: Decodable {
        let subnet: String?
        let gateway: String?

        private enum CodingKeys: String, CodingKey {
          case subnet = "Subnet"
          case gateway = "Gateway"
        }
      }
      let config: [ConfigWire]?

      private enum CodingKeys: String, CodingKey { case config = "Config" }
    }
    struct EndpointWire: Decodable {
      let name: String
      let ipv4Address: String
      let ipv6Address: String

      private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case ipv4Address = "IPv4Address"
        case ipv6Address = "IPv6Address"
      }
    }
    let id: String
    let name: String
    let driver: String
    let scope: String
    let ipam: IPAMWire
    let containers: [String: EndpointWire]?

    private enum CodingKeys: String, CodingKey {
      case id = "Id"
      case name = "Name"
      case driver = "Driver"
      case scope = "Scope"
      case ipam = "IPAM"
      case containers = "Containers"
    }

    var summary: NetworkSummary {
      NetworkSummary(
        id: NetworkID(rawValue: id),
        name: name,
        driver: driver,
        scope: scope,
        ipam: (ipam.config ?? []).map { IPAMConfig(subnet: $0.subnet, gateway: $0.gateway) }
      )
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
