public struct IPAMConfig: Sendable, Equatable {
  public let subnet: String?
  public let gateway: String?

  public init(subnet: String?, gateway: String?) {
    self.subnet = subnet
    self.gateway = gateway
  }
}

public struct NetworkSummary: Sendable, Equatable, Identifiable {
  public static let builtInNames: Set<String> = ["bridge", "host", "none"]

  public let id: NetworkID
  public let name: String
  public let driver: String
  public let scope: String
  public let ipam: [IPAMConfig]

  public init(id: NetworkID, name: String, driver: String, scope: String, ipam: [IPAMConfig]) {
    self.id = id
    self.name = name
    self.driver = driver
    self.scope = scope
    self.ipam = ipam
  }

  /// An ID equal to a built-in name also counts: the engine resolves those names as references.
  public var deletableID: DeletableNetworkID? {
    guard !Self.builtInNames.contains(name), !Self.builtInNames.contains(id.rawValue) else {
      return nil
    }
    return DeletableNetworkID(id)
  }
}

/// The initializer is `internal` on purpose: `NetworkSummary.deletableID` is the only source outside
/// `ColimaCore`, so a built-in network can never reach a delete request.
public struct DeletableNetworkID: Sendable, Hashable {
  public let id: NetworkID

  init(_ id: NetworkID) {
    self.id = id
  }
}

public struct NetworkContainer: Sendable, Equatable, Identifiable {
  public let id: ContainerID
  public let name: String
  /// As the engine reports it, with the prefix length (`172.18.0.2/16`); `nil` when the endpoint has none.
  public let ipv4Address: String?
  public let ipv6Address: String?

  public init(id: ContainerID, name: String, ipv4Address: String?, ipv6Address: String?) {
    self.id = id
    self.name = name
    self.ipv4Address = ipv4Address
    self.ipv6Address = ipv6Address
  }
}

public struct NetworkDetail: Sendable, Equatable, Identifiable {
  public let id: NetworkID
  public let name: String
  public let containers: [NetworkContainer]

  public init(id: NetworkID, name: String, containers: [NetworkContainer]) {
    self.id = id
    self.name = name
    self.containers = containers
  }
}
