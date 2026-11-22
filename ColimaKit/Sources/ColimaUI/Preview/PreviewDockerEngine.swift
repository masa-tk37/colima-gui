#if DEBUG
  import ColimaCore
  import Foundation
  import Synchronization

  enum PreviewBehavior: Sendable {
    case succeed
    case fail(DockerError)
    case hang
  }

  final class PreviewDockerEngine: DockerEngine {
    struct LogScript: Sendable {
      enum Ending: Sendable {
        case staysOpen
        case closes
        case fails(DockerError)
      }

      var chunks: [[UInt8]] = []
      var ending = Ending.closes
    }

    struct Config: Sendable {
      var containers: Result<[ContainerSummary], DockerError> = .success([])
      var ttyContainers: Set<ContainerID> = []
      var stats: Result<ContainerStatsSample, DockerError> = .success(
        PreviewDockerEngine.busySample)
      var containerActions: [ContainerID: PreviewBehavior] = [:]
      var containerRemovals: [ContainerID: PreviewBehavior] = [:]
      var logs: [ContainerID: LogScript] = [:]

      var images: Result<[ImageSummary], DockerError> = .success([])
      var imageRemovals: [ImageReference: PreviewBehavior] = [:]

      var volumes: Result<[VolumeSummary], DockerError> = .success([])
      var unusedVolumes: Result<[VolumeSummary], DockerError> = .success([])
      var volumeSizes: Result<[String: VolumeSize], DockerError> = .success([:])
      var volumeRemovals: [String: PreviewBehavior] = [:]

      var networks: Result<[NetworkSummary], DockerError> = .success([])
      var unusedNetworks: Result<[NetworkSummary], DockerError> = .success([])
      var networkDetails: [NetworkID: NetworkDetail] = [:]
      var networkCreation = PreviewBehavior.succeed
      var createdNetworkID = NetworkID(rawValue: "created-network")
      var networkRemovals: [NetworkID: PreviewBehavior] = [:]
      var connections: [NetworkMembership: PreviewBehavior] = [:]
      var disconnections: [NetworkMembership: PreviewBehavior] = [:]
    }

    /// One fully busy core out of four is 100; this sample reads as 40 %.
    static let busySample = ContainerStatsSample(
      cpuTotalUsage: 2_000_000_000, previousCPUTotalUsage: 1_900_000_000,
      systemCPUUsage: 200_000_000_000, previousSystemCPUUsage: 199_000_000_000,
      onlineCPUs: 4, memoryUsage: 300 << 20, memoryInactiveFile: 44 << 20
    )

    private let state = Mutex(Config())

    func configure(_ body: (inout Config) -> Void) {
      state.withLock { body(&$0) }
    }

    /// One frame of the engine's multiplexed log stream.
    static func frame(_ stream: LogStreamKind, _ text: String) -> [UInt8] {
      let payload = Array(text.utf8)
      let length = payload.count
      let type: UInt8 = stream == .stderr ? 2 : 1
      let header: [UInt8] = [
        type, 0, 0, 0,
        UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
      ]
      return header + payload
    }

    private func read<Value: Sendable>(
      _ pick: (Config) -> Result<Value, DockerError>
    ) throws(DockerError) -> Value {
      if Task.isCancelled { throw .cancelled }
      return try state.withLock { pick($0) }.get()
    }

    private func notFound<Value>(_ kind: String, _ id: String) -> Result<Value, DockerError> {
      .failure(.api(status: 404, message: "No such \(kind): \(id)"))
    }

    private func carryOut(_ pick: (Config) -> PreviewBehavior?) async throws(DockerError) {
      if Task.isCancelled { throw .cancelled }
      switch state.withLock({ pick($0) }) ?? .succeed {
      case .succeed:
        return
      case .fail(let error):
        throw error
      case .hang:
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        throw .cancelled
      }
    }

    // MARK: Containers

    func listContainers() async throws(DockerError) -> [ContainerSummary] {
      try read { $0.containers }
    }

    func inspectContainer(id: ContainerID) async throws(DockerError) -> ContainerDetail {
      try read { config in
        guard let listed = (try? config.containers.get())?.first(where: { $0.id == id }) else {
          return notFound("container", id.rawValue)
        }
        return .success(
          ContainerDetail(
            id: id, hasTTY: config.ttyContainers.contains(id),
            isRunning: listed.state.isRunning, networkNames: listed.networkNames
          ))
      }
    }

    func perform(_ action: ContainerAction, on id: ContainerID) async throws(DockerError) {
      try await carryOut { $0.containerActions[id] }
    }

    func removeContainer(id: ContainerID) async throws(DockerError) {
      try await carryOut { $0.containerRemovals[id] }
    }

    func containerStats(id: ContainerID) async throws(DockerError) -> ContainerStatsSample {
      try read { $0.stats }
    }

    func consumeLogs(
      id: ContainerID,
      tail: Int,
      follow: Bool,
      onChunk: @Sendable ([UInt8]) async -> Void
    ) async throws(DockerError) {
      if Task.isCancelled { throw .cancelled }
      let script = state.withLock { $0.logs[id] } ?? LogScript()
      for chunk in script.chunks {
        if Task.isCancelled { throw .cancelled }
        await onChunk(chunk)
      }
      switch script.ending {
      case .closes:
        return
      case .fails(let error):
        throw error
      case .staysOpen:
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        throw .cancelled
      }
    }

    // MARK: Images

    func listImages() async throws(DockerError) -> [ImageSummary] {
      try read { $0.images }
    }

    func removeImage(_ reference: ImageReference) async throws(DockerError) {
      try await carryOut { $0.imageRemovals[reference] }
    }

    // MARK: Volumes

    func listVolumes(danglingOnly: Bool) async throws(DockerError) -> [VolumeSummary] {
      try read { danglingOnly ? $0.unusedVolumes : $0.volumes }
    }

    func volumeSizes() async throws(DockerError) -> [String: VolumeSize] {
      try read { $0.volumeSizes }
    }

    func removeVolume(name: String) async throws(DockerError) {
      try await carryOut { $0.volumeRemovals[name] }
    }

    // MARK: Networks

    func listNetworks(danglingOnly: Bool) async throws(DockerError) -> [NetworkSummary] {
      try read { danglingOnly ? $0.unusedNetworks : $0.networks }
    }

    func inspectNetwork(id: NetworkID) async throws(DockerError) -> NetworkDetail {
      try read { config in
        config.networkDetails[id].map { .success($0) } ?? notFound("network", id.rawValue)
      }
    }

    func createNetwork(_ request: ValidatedNetworkCreate) async throws(DockerError) -> NetworkID {
      try await carryOut { $0.networkCreation }
      return state.withLock { $0.createdNetworkID }
    }

    func removeNetwork(_ id: DeletableNetworkID) async throws(DockerError) {
      try await carryOut { $0.networkRemovals[id.id] }
    }

    func connect(container: ContainerID, to network: NetworkID) async throws(DockerError) {
      try await carryOut {
        $0.connections[NetworkMembership(container: container, network: network)]
      }
    }

    func disconnect(container: ContainerID, from network: NetworkID) async throws(DockerError) {
      try await carryOut {
        $0.disconnections[NetworkMembership(container: container, network: network)]
      }
    }
  }
#endif
