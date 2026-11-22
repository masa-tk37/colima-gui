import ColimaCore
import Foundation

extension DockerEngineClient {
  /// Chunks are the raw bytes of the engine's log stream; multiplex framing is left for the caller to decode.
  public func consumeLogs(
    id: ContainerID,
    tail: Int,
    follow: Bool,
    onChunk: @Sendable ([UInt8]) async -> Void
  ) async throws(DockerError) {
    let request = DockerRequest(
      .get,
      [Self.apiVersion, "containers", id.rawValue, "logs"],
      query: [
        URLQueryItem(name: "stdout", value: "1"),
        URLQueryItem(name: "stderr", value: "1"),
        URLQueryItem(name: "tail", value: String(tail)),
        URLQueryItem(name: "follow", value: follow ? "1" : "0"),
      ]
    )
    try await transport.stream(request, onChunk: onChunk)
  }
}
