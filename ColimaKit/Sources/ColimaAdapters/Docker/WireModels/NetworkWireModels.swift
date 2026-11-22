import ColimaCore
import Foundation

private struct IPAMWire: Decodable {
  let config: [IPAMConfigWire]

  private enum CodingKeys: String, CodingKey { case config = "Config" }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    config = try container.decodeIfPresent([IPAMConfigWire].self, forKey: .config) ?? []
  }
}

private struct IPAMConfigWire: Decodable {
  let subnet: String?
  let gateway: String?

  private enum CodingKeys: String, CodingKey {
    case subnet = "Subnet"
    case gateway = "Gateway"
  }

  func toDomain() -> IPAMConfig {
    IPAMConfig(subnet: subnet.nonEmpty, gateway: gateway.nonEmpty)
  }
}

extension String? {
  fileprivate var nonEmpty: String? {
    guard let self, !self.isEmpty else { return nil }
    return self
  }
}

struct NetworkListItemWire: Decodable {
  let id: String
  let name: String
  let driver: String
  let scope: String
  private let ipam: IPAMWire?

  private enum CodingKeys: String, CodingKey {
    case id = "Id"
    case name = "Name"
    case driver = "Driver"
    case scope = "Scope"
    case ipam = "IPAM"
  }

  func toDomain() -> NetworkSummary {
    NetworkSummary(
      id: NetworkID(rawValue: id), name: name, driver: driver, scope: scope,
      ipam: (ipam?.config ?? []).map { $0.toDomain() })
  }
}

/// `GET /networks/{id}`. `Containers` is a map keyed by container ID, `{}`, `null` or absent when nothing is
/// attached.
struct NetworkInspectWire: Decodable {
  let id: String
  let name: String
  let containers: [String: EndpointWire]?

  struct EndpointWire: Decodable {
    let name: String
    let ipv4Address: String?
    let ipv6Address: String?

    private enum CodingKeys: String, CodingKey {
      case name = "Name"
      case ipv4Address = "IPv4Address"
      case ipv6Address = "IPv6Address"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id = "Id"
    case name = "Name"
    case containers = "Containers"
  }

  func toDomain() -> NetworkDetail {
    let attached = (containers ?? [:])
      .map { key, endpoint in
        NetworkContainer(
          id: ContainerID(rawValue: key), name: endpoint.name,
          ipv4Address: endpoint.ipv4Address.nonEmpty, ipv6Address: endpoint.ipv6Address.nonEmpty)
      }
      .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    return NetworkDetail(id: NetworkID(rawValue: id), name: name, containers: attached)
  }
}
