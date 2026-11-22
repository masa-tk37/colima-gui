import ColimaCore
import Foundation

public final class DockerEngineClient: Sendable {
  static let apiVersion = "v1.54"

  let transport: DockerHTTPTransport

  public convenience init(socketPath: String) {
    self.init(socketPath: socketPath, timeouts: .standard)
  }

  init(socketPath: String, timeouts: DockerHTTPTransport.Timeouts) {
    transport = DockerHTTPTransport(socketPath: socketPath, timeouts: timeouts)
  }

  public func shutdown() async {
    await transport.shutdown()
  }

  // MARK: Containers

  public func listContainers() async throws(DockerError) -> [ContainerSummary] {
    let response = try await send(
      .get, ["containers", "json"], query: [("all", "1")], deadline: .read)
    return try decode([ContainerListItemWire].self, from: response).map { $0.toDomain() }
  }

  public func inspectContainer(id: ContainerID) async throws(DockerError) -> ContainerDetail {
    let response = try await send(.get, ["containers", id.rawValue, "json"], deadline: .read)
    return try decode(ContainerInspectWire.self, from: response).toDomain()
  }

  /// An engine answer of "already in that state" (304) is a success.
  public func perform(_ action: ContainerAction, on id: ContainerID) async throws(DockerError) {
    let response = try await send(
      .post, ["containers", id.rawValue, action.pathSegment], deadline: .mutate)
    if response.status == 304 { return }
    try requireSuccess(response)
  }

  /// Never forces and never removes anonymous volumes, so a running container is refused with 409.
  public func removeContainer(id: ContainerID) async throws(DockerError) {
    let response = try await send(
      .delete, ["containers", id.rawValue], query: [("force", "false"), ("v", "false")],
      deadline: .mutate)
    try requireSuccess(response)
  }

  /// `stream=false` is the only form that fills `precpu_stats`, which the CPU percentage is computed from.
  public func containerStats(id: ContainerID) async throws(DockerError) -> ContainerStatsSample {
    let response = try await send(
      .get, ["containers", id.rawValue, "stats"], query: [("stream", "false")], deadline: .read)
    return try decode(ContainerStatsWire.self, from: response).toDomain()
  }
}

extension DockerEngineClient {
  func send(
    _ method: DockerRequest.Method,
    _ segments: [String],
    query: [(String, String)] = [],
    deadline: DockerDeadline
  ) async throws(DockerError) -> DockerResponse {
    let request = DockerRequest(
      method,
      [Self.apiVersion] + segments,
      query: query.map { URLQueryItem(name: $0.0, value: $0.1) }
    )
    return try await transport.send(request, deadline: deadline)
  }

  /// 3xx is returned by the transport as a response, so a status other than 2xx here is a protocol surprise.
  func requireSuccess(_ response: DockerResponse) throws(DockerError) {
    guard (200..<300).contains(response.status) else {
      throw .unexpectedResponse(detail: "unexpected status \(response.status)")
    }
  }

  func decode<T: Decodable>(_ type: T.Type, from response: DockerResponse) throws(DockerError) -> T
  {
    try requireSuccess(response)
    do {
      return try JSONDecoder().decode(type, from: Data(response.body))
    } catch {
      if Task.isCancelled { throw .cancelled }
      ColimaLog.docker.error(
        "response decode failed: \(String(describing: error), privacy: .public)")
      throw .unexpectedResponse(detail: String(describing: error))
    }
  }
}

extension ContainerAction {
  fileprivate var pathSegment: String {
    switch self {
    case .start: "start"
    case .stop: "stop"
    case .restart: "restart"
    }
  }
}

extension DockerEngineClient: DockerEngine {}
