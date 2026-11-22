import ColimaCore
import Foundation

struct ContainerListItemWire: Decodable {
  struct Port: Decodable {
    let ip: String?
    let privatePort: Int
    let publicPort: Int?
    let type: String

    private enum CodingKeys: String, CodingKey {
      case ip = "IP"
      case privatePort = "PrivatePort"
      case publicPort = "PublicPort"
      case type = "Type"
    }
  }

  struct NetworkSettings: Decodable {
    let networks: [String: EmptyObject]?

    private enum CodingKeys: String, CodingKey { case networks = "Networks" }
  }

  let id: String
  let names: [String]?
  let image: String
  let imageID: String?
  let state: String
  let ports: [Port]?
  let labels: [String: String]?
  let networkSettings: NetworkSettings?

  private enum CodingKeys: String, CodingKey {
    case id = "Id"
    case names = "Names"
    case image = "Image"
    case imageID = "ImageID"
    case state = "State"
    case ports = "Ports"
    case labels = "Labels"
    case networkSettings = "NetworkSettings"
  }

  func toDomain() -> ContainerSummary {
    ContainerSummary(
      id: ContainerID(rawValue: id),
      name: displayName,
      image: image,
      state: ContainerState(dockerState: state),
      ports: (ports ?? []).map {
        ContainerPort(
          ip: $0.ip, privatePort: $0.privatePort, publicPort: $0.publicPort, protocolName: $0.type)
      },
      labels: labels ?? [:],
      networkNames: (networkSettings?.networks ?? [:]).keys.sorted(),
      imageID: imageID ?? ""
    )
  }

  /// `Names` holds "/name" plus "/other/alias" entries for legacy links; the container's own name has one slash.
  private var displayName: String {
    let all = names ?? []
    let own = all.first { $0.hasPrefix("/") && !$0.dropFirst().contains("/") }
    guard let chosen = own ?? all.first else { return String(id.prefix(12)) }
    return chosen.hasPrefix("/") ? String(chosen.dropFirst()) : chosen
  }
}

/// `GET /containers/{id}/json`. `Config.Tty` decides how logs are framed, so it is required: a response
/// without it fails to decode rather than being read as a non-TTY container.
struct ContainerInspectWire: Decodable {
  struct State: Decodable {
    let running: Bool

    private enum CodingKeys: String, CodingKey { case running = "Running" }
  }

  struct Config: Decodable {
    let tty: Bool

    private enum CodingKeys: String, CodingKey { case tty = "Tty" }
  }

  struct NetworkSettings: Decodable {
    let networks: [String: EmptyObject]?

    private enum CodingKeys: String, CodingKey { case networks = "Networks" }
  }

  let id: String
  let state: State
  let config: Config
  let networkSettings: NetworkSettings?

  private enum CodingKeys: String, CodingKey {
    case id = "Id"
    case state = "State"
    case config = "Config"
    case networkSettings = "NetworkSettings"
  }

  func toDomain() -> ContainerDetail {
    ContainerDetail(
      id: ContainerID(rawValue: id),
      hasTTY: config.tty,
      isRunning: state.running,
      networkNames: (networkSettings?.networks ?? [:]).keys.sorted()
    )
  }
}

struct EmptyObject: Decodable {
  init(from decoder: any Decoder) throws {}
}
