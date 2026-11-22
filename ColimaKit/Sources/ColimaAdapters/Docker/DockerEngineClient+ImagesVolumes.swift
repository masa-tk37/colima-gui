import ColimaCore
import Foundation

extension DockerEngineClient {
  // MARK: Images

  public func listImages() async throws(DockerError) -> [ImageSummary] {
    let response = try await send(.get, ["images", "json"], deadline: .read)
    return try decode([ImageListItemWire].self, from: response).map { $0.toDomain() }
  }

  /// Never forces and keeps untagged parents, so deleting one tag leaves the image's other tags and layers intact.
  public func removeImage(_ reference: ImageReference) async throws(DockerError) {
    let response = try await send(
      .delete, ["images", reference.value], query: [("force", "false"), ("noprune", "true")],
      deadline: .mutate)
    try requireSuccess(response)
  }

  // MARK: Volumes

  public func listVolumes(danglingOnly: Bool) async throws(DockerError) -> [VolumeSummary] {
    let query = danglingOnly ? [("filters", #"{"dangling":["true"]}"#)] : []
    let response = try await send(.get, ["volumes"], query: query, deadline: .read)
    return try decode(VolumeListWire.self, from: response).toDomain()
  }

  /// Sizes come from a separate call because `GET /volumes` carries no usage data.
  public func volumeSizes() async throws(DockerError) -> [String: VolumeSize] {
    let response = try await send(
      .get, ["system", "df"], query: [("type", "volume"), ("verbose", "true")], deadline: .read)
    return try decode(SystemDfVolumesWire.self, from: response).toDomain()
  }

  /// Never forces, so a volume in use is refused with 409.
  public func removeVolume(name: String) async throws(DockerError) {
    let response = try await send(
      .delete, ["volumes", name], query: [("force", "false")], deadline: .mutate)
    try requireSuccess(response)
  }
}
