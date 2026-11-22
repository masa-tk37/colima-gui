import Synchronization

@testable import ColimaCore

final class FakeDockerEngine: DockerEngine {
  enum Call: Equatable {
    case listContainers
    case inspectContainer(ContainerID)
    case perform(ContainerAction, ContainerID)
    case removeContainer(ContainerID)
    case containerStats(ContainerID)
    case consumeLogs(id: ContainerID, tail: Int, follow: Bool)
    case listImages
    case removeImage(ImageReference)
    case listVolumes(danglingOnly: Bool)
    case volumeSizes
    case removeVolume(String)
    case listNetworks(danglingOnly: Bool)
    case inspectNetwork(NetworkID)
    case createNetwork(ValidatedNetworkCreate)
    case removeNetwork(DeletableNetworkID)
    case connect(container: ContainerID, network: NetworkID)
    case disconnect(container: ContainerID, network: NetworkID)
  }

  /// Unconfigured inspect and stats answer 404, as a real engine does.
  struct Config: Sendable {
    var containers: Result<[ContainerSummary], DockerError> = .success([])
    var containerDetails: [ContainerID: Result<ContainerDetail, DockerError>] = [:]
    var containerStats: [ContainerID: Result<ContainerStatsSample, DockerError>] = [:]
    var containerActionFailures: [ContainerID: DockerError] = [:]
    var containerRemovalFailures: [ContainerID: DockerError] = [:]

    var logChunks: [ContainerID: [[UInt8]]] = [:]
    var logFailures: [ContainerID: DockerError] = [:]
    var logStreamStaysOpen = false
    var afterLogChunk: (@Sendable (Int) async -> Void)?

    var images: Result<[ImageSummary], DockerError> = .success([])
    var imageRemovalFailures: [ImageReference: DockerError] = [:]

    var volumes: Result<[VolumeSummary], DockerError> = .success([])
    var danglingVolumes: Result<[VolumeSummary], DockerError> = .success([])
    var volumeSizes: Result<[String: VolumeSize], DockerError> = .success([:])
    var volumeRemovalFailures: [String: DockerError] = [:]

    var networks: Result<[NetworkSummary], DockerError> = .success([])
    var danglingNetworks: Result<[NetworkSummary], DockerError> = .success([])
    var networkDetails: [NetworkID: Result<NetworkDetail, DockerError>] = [:]
    var createdNetworkID: Result<NetworkID, DockerError> = .success(
      NetworkID(rawValue: "fake-network"))
    var networkRemovalFailures: [NetworkID: DockerError] = [:]
    var connectFailures: [NetworkMembership: DockerError] = [:]
    var disconnectFailures: [NetworkMembership: DockerError] = [:]

    var beforeReturn: (@Sendable (Call) async -> Void)?
  }

  private struct State {
    var config = Config()
    var calls: [Call] = []
  }

  private let state = Mutex(State())

  func configure(_ body: (inout Config) -> Void) {
    state.withLock { body(&$0.config) }
  }

  var calls: [Call] { state.withLock { $0.calls } }

  private func respond<T: Sendable>(
    _ call: Call,
    _ pick: (Config) -> Result<T, DockerError>
  ) async throws(DockerError) -> T {
    let hook = state.withLock { state in
      state.calls.append(call)
      return state.config.beforeReturn
    }
    if Task.isCancelled { throw .cancelled }
    await hook?(call)
    if Task.isCancelled { throw .cancelled }
    return try state.withLock { pick($0.config) }.get()
  }

  private static func outcome(_ failure: DockerError?) -> Result<Void, DockerError> {
    failure.map { .failure($0) } ?? .success(())
  }

  private static func notFound<T>(_ kind: String, _ id: String) -> Result<T, DockerError> {
    .failure(.api(status: 404, message: "No such \(kind): \(id)"))
  }

  func listContainers() async throws(DockerError) -> [ContainerSummary] {
    try await respond(.listContainers) { $0.containers }
  }

  func inspectContainer(id: ContainerID) async throws(DockerError) -> ContainerDetail {
    try await respond(.inspectContainer(id)) {
      $0.containerDetails[id] ?? Self.notFound("container", id.rawValue)
    }
  }

  func perform(_ action: ContainerAction, on id: ContainerID) async throws(DockerError) {
    try await respond(.perform(action, id)) { Self.outcome($0.containerActionFailures[id]) }
  }

  func removeContainer(id: ContainerID) async throws(DockerError) {
    try await respond(.removeContainer(id)) { Self.outcome($0.containerRemovalFailures[id]) }
  }

  func containerStats(id: ContainerID) async throws(DockerError) -> ContainerStatsSample {
    try await respond(.containerStats(id)) {
      $0.containerStats[id] ?? Self.notFound("container", id.rawValue)
    }
  }

  func consumeLogs(
    id: ContainerID,
    tail: Int,
    follow: Bool,
    onChunk: @Sendable ([UInt8]) async -> Void
  ) async throws(DockerError) {
    let chunks = try await respond(.consumeLogs(id: id, tail: tail, follow: follow)) { config in
      Result<[[UInt8]], DockerError>.success(config.logChunks[id] ?? [])
    }
    let afterChunk = state.withLock { $0.config.afterLogChunk }
    for (index, chunk) in chunks.enumerated() {
      if Task.isCancelled { throw .cancelled }
      await onChunk(chunk)
      await afterChunk?(index)
    }
    let (failure, staysOpen) = state.withLock {
      ($0.config.logFailures[id], $0.config.logStreamStaysOpen)
    }
    if let failure { throw failure }
    if staysOpen {
      try? await Task.sleep(for: .seconds(3600))
      throw .cancelled
    }
  }

  func listImages() async throws(DockerError) -> [ImageSummary] {
    try await respond(.listImages) { $0.images }
  }

  func removeImage(_ reference: ImageReference) async throws(DockerError) {
    try await respond(.removeImage(reference)) { Self.outcome($0.imageRemovalFailures[reference]) }
  }

  func listVolumes(danglingOnly: Bool) async throws(DockerError) -> [VolumeSummary] {
    try await respond(.listVolumes(danglingOnly: danglingOnly)) {
      danglingOnly ? $0.danglingVolumes : $0.volumes
    }
  }

  func volumeSizes() async throws(DockerError) -> [String: VolumeSize] {
    try await respond(.volumeSizes) { $0.volumeSizes }
  }

  func removeVolume(name: String) async throws(DockerError) {
    try await respond(.removeVolume(name)) { Self.outcome($0.volumeRemovalFailures[name]) }
  }

  func listNetworks(danglingOnly: Bool) async throws(DockerError) -> [NetworkSummary] {
    try await respond(.listNetworks(danglingOnly: danglingOnly)) {
      danglingOnly ? $0.danglingNetworks : $0.networks
    }
  }

  func inspectNetwork(id: NetworkID) async throws(DockerError) -> NetworkDetail {
    try await respond(.inspectNetwork(id)) {
      $0.networkDetails[id] ?? Self.notFound("network", id.rawValue)
    }
  }

  func createNetwork(_ request: ValidatedNetworkCreate) async throws(DockerError) -> NetworkID {
    try await respond(.createNetwork(request)) { $0.createdNetworkID }
  }

  func removeNetwork(_ id: DeletableNetworkID) async throws(DockerError) {
    try await respond(.removeNetwork(id)) { Self.outcome($0.networkRemovalFailures[id.id]) }
  }

  func connect(container: ContainerID, to network: NetworkID) async throws(DockerError) {
    let key = NetworkMembership(container: container, network: network)
    try await respond(.connect(container: container, network: network)) {
      Self.outcome($0.connectFailures[key])
    }
  }

  func disconnect(container: ContainerID, from network: NetworkID) async throws(DockerError) {
    let key = NetworkMembership(container: container, network: network)
    try await respond(.disconnect(container: container, network: network)) {
      Self.outcome($0.disconnectFailures[key])
    }
  }
}
