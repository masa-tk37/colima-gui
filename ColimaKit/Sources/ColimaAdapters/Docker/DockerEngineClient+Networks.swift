import ColimaCore
import Foundation

extension DockerEngineClient {
  public func listNetworks(danglingOnly: Bool) async throws(DockerError) -> [NetworkSummary] {
    let query = danglingOnly ? [("filters", #"{"dangling":["true"]}"#)] : []
    let response = try await send(.get, ["networks"], query: query, deadline: .read)
    return try decode([NetworkListItemWire].self, from: response).map { $0.toDomain() }
  }

  public func inspectNetwork(id: NetworkID) async throws(DockerError) -> NetworkDetail {
    let response = try await send(.get, ["networks", id.rawValue], deadline: .read)
    return try decode(NetworkInspectWire.self, from: response).toDomain()
  }

  public func createNetwork(_ request: ValidatedNetworkCreate) async throws(DockerError)
    -> NetworkID
  {
    let body = NetworkCreateBody(
      name: request.name,
      driver: request.driver,
      ipam: request.subnet.map { NetworkCreateBody.IPAM(config: [.init(subnet: $0.cidr)]) },
      enableIPv6: request.subnet?.family == .ipv6 ? true : nil)
    let response = try await sendJSON(.post, ["networks", "create"], body: body)
    return NetworkID(rawValue: try decode(NetworkCreateResponseWire.self, from: response).id)
  }

  /// Takes only the ID that `NetworkSummary.deletableID` yields, so a built-in network cannot be targeted.
  public func removeNetwork(_ id: DeletableNetworkID) async throws(DockerError) {
    let response = try await send(.delete, ["networks", id.id.rawValue], deadline: .mutate)
    try requireSuccess(response)
  }

  public func connect(container: ContainerID, to network: NetworkID) async throws(DockerError) {
    let response = try await sendJSON(
      .post, ["networks", network.rawValue, "connect"],
      body: ConnectBody(container: container.rawValue))
    try requireSuccess(response)
  }

  public func disconnect(container: ContainerID, from network: NetworkID) async throws(DockerError)
  {
    let response = try await sendJSON(
      .post, ["networks", network.rawValue, "disconnect"],
      body: DisconnectBody(container: container.rawValue, force: false))
    try requireSuccess(response)
  }

  private func sendJSON(
    _ method: DockerRequest.Method,
    _ segments: [String],
    body: some Encodable
  ) async throws(DockerError) -> DockerResponse {
    let payload: [UInt8]
    do {
      payload = Array(try JSONEncoder().encode(body))
    } catch {
      throw .unexpectedResponse(detail: "request body encoding failed: \(error)")
    }
    let request = DockerRequest(method, [Self.apiVersion] + segments, jsonBody: payload)
    return try await transport.send(request, deadline: .mutate)
  }
}

private struct NetworkCreateBody: Encodable {
  let name: String
  let driver: String
  let ipam: IPAM?
  let enableIPv6: Bool?

  struct IPAM: Encodable {
    let config: [Pool]
    private enum CodingKeys: String, CodingKey { case config = "Config" }
  }

  struct Pool: Encodable {
    let subnet: String
    private enum CodingKeys: String, CodingKey { case subnet = "Subnet" }
  }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case driver = "Driver"
    case ipam = "IPAM"
    case enableIPv6 = "EnableIPv6"
  }
}

private struct ConnectBody: Encodable {
  let container: String
  private enum CodingKeys: String, CodingKey { case container = "Container" }
}

private struct DisconnectBody: Encodable {
  let container: String
  let force: Bool
  private enum CodingKeys: String, CodingKey {
    case container = "Container"
    case force = "Force"
  }
}

private struct NetworkCreateResponseWire: Decodable {
  let id: String
  private enum CodingKeys: String, CodingKey { case id = "Id" }
}
