/// Every method throws `.cancelled` when the calling task is cancelled, whatever the underlying error was.
public protocol DockerEngine: Sendable {
  func listContainers() async throws(DockerError) -> [ContainerSummary]
  func inspectContainer(id: ContainerID) async throws(DockerError) -> ContainerDetail
  /// An engine answer of "already in that state" (304) is a success.
  func perform(_ action: ContainerAction, on id: ContainerID) async throws(DockerError)
  func removeContainer(id: ContainerID) async throws(DockerError)
  func containerStats(id: ContainerID) async throws(DockerError) -> ContainerStatsSample
  func consumeLogs(
    id: ContainerID,
    tail: Int,
    follow: Bool,
    onChunk: @Sendable ([UInt8]) async -> Void
  ) async throws(DockerError)

  func listImages() async throws(DockerError) -> [ImageSummary]
  func removeImage(_ reference: ImageReference) async throws(DockerError)

  func listVolumes(danglingOnly: Bool) async throws(DockerError) -> [VolumeSummary]
  func volumeSizes() async throws(DockerError) -> [String: VolumeSize]
  func removeVolume(name: String) async throws(DockerError)

  func listNetworks(danglingOnly: Bool) async throws(DockerError) -> [NetworkSummary]
  func inspectNetwork(id: NetworkID) async throws(DockerError) -> NetworkDetail
  func createNetwork(_ request: ValidatedNetworkCreate) async throws(DockerError) -> NetworkID
  func removeNetwork(_ id: DeletableNetworkID) async throws(DockerError)
  func connect(container: ContainerID, to network: NetworkID) async throws(DockerError)
  func disconnect(container: ContainerID, from network: NetworkID) async throws(DockerError)
}
