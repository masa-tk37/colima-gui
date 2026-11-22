public enum ContainerState: Sendable, Equatable {
  case running
  case other(rawState: String)

  public init(dockerState: String) {
    self = dockerState == "running" ? .running : .other(rawState: dockerState)
  }

  public var isRunning: Bool { self == .running }
}

public struct ContainerPort: Sendable, Equatable {
  public let ip: String?
  public let privatePort: Int
  public let publicPort: Int?
  public let protocolName: String

  public init(ip: String?, privatePort: Int, publicPort: Int?, protocolName: String) {
    self.ip = ip
    self.privatePort = privatePort
    self.publicPort = publicPort
    self.protocolName = protocolName
  }
}

public struct ContainerSummary: Sendable, Equatable, Identifiable {
  public let id: ContainerID
  public let name: String
  public let image: String
  public let state: ContainerState
  public let ports: [ContainerPort]
  public let labels: [String: String]
  public let networkNames: [String]
  /// The image's full ID (`sha256:…`), which tags and short IDs both resolve to; empty when the engine did not send it.
  public let imageID: String

  public init(
    id: ContainerID,
    name: String,
    image: String,
    state: ContainerState,
    ports: [ContainerPort],
    labels: [String: String],
    networkNames: [String],
    imageID: String = ""
  ) {
    self.id = id
    self.name = name
    self.image = image
    self.state = state
    self.ports = ports
    self.labels = labels
    self.networkNames = networkNames
    self.imageID = imageID
  }
}

public struct ContainerDetail: Sendable, Equatable {
  public let id: ContainerID
  public let hasTTY: Bool
  public let isRunning: Bool
  public let networkNames: [String]

  public init(id: ContainerID, hasTTY: Bool, isRunning: Bool, networkNames: [String]) {
    self.id = id
    self.hasTTY = hasTTY
    self.isRunning = isRunning
    self.networkNames = networkNames
  }
}

public enum ContainerAction: Sendable, Equatable, CaseIterable {
  case start, stop, restart
}
