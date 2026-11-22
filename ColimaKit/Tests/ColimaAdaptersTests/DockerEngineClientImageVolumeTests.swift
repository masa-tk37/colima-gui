import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private let shortTimeouts = DockerHTTPTransport.Timeouts(
  read: .seconds(5),
  mutate: .seconds(5),
  logHead: .seconds(5)
)

private func jsonReply(_ body: Data) -> ScriptedBehavior {
  .reply(
    ScriptedReply(status: 200, headers: ["Content-Type": "application/json"], body: Array(body)))
}

private func jsonReply(_ text: String) -> ScriptedBehavior {
  jsonReply(Data(text.utf8))
}

private func errorReply(_ status: Int, _ message: String) -> ScriptedBehavior {
  .reply(
    ScriptedReply(
      status: status,
      headers: ["Content-Type": "application/json"],
      body: Array(#"{"message":"\#(message)"}"#.utf8)
    ))
}

private func withClient<T: Sendable>(
  _ server: TestUnixHTTPServer,
  _ body: (DockerEngineClient) async throws -> T
) async throws -> T {
  let client = DockerEngineClient(socketPath: server.socketPath, timeouts: shortTimeouts)
  do {
    let value = try await body(client)
    await client.shutdown()
    return value
  } catch {
    await client.shutdown()
    throw error
  }
}

private func failure<T>(_ operation: () async throws -> T) async -> DockerError? {
  do {
    _ = try await operation()
    return nil
  } catch {
    if let error = error as? DockerError { return error }
    Issue.record("the client threw a non-DockerError: \(error)")
    return .unexpectedResponse(detail: String(describing: error))
  }
}

@Suite struct DockerEngineClientImageVolumeTests {
  // MARK: Images

  @Test func listsImages() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/images/json",
      jsonReply(try wireFixture("docker-images-list.json")))

    let images = try await withClient(server) { try await $0.listImages() }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/images/json")
    #expect(request.query == nil)
    #expect(images.count == 1)
    #expect(images.first?.repoTags == ["amazon/aws-cli:latest", "cgprobe-img:a", "cgprobe-img:b"])
    #expect(images.first?.size == 691_953_477)
  }

  @Test func removesATaggedImageAsOnePercentEncodedSegmentWithoutForceAndKeepingParents()
    async throws
  {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"[{"Untagged":"amazon/aws-cli:latest"}]"#))

    try await withClient(server) {
      try await $0.removeImage(.tag(repository: "amazon/aws-cli", tag: "latest"))
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.path == "/v1.54/images/amazon%2Faws-cli%3Alatest")
    #expect(request.queryItems == ["force": "false", "noprune": "true"])
    #expect(request.query?.contains("force=false") == true)
    #expect(request.query?.contains("noprune=true") == true)
  }

  @Test func removesAnUntaggedImageByItsID() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"[{"Deleted":"sha256:abc"}]"#))

    try await withClient(server) { try await $0.removeImage(.imageID("sha256:abc")) }

    let request = try #require(server.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.path == "/v1.54/images/sha256%3Aabc")
    #expect(request.queryItems == ["force": "false", "noprune": "true"])
  }

  @Test func removingAnImageUsedByAContainerSurfacesTheConflictMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let message =
      "conflict: unable to delete a731f68fd7e3 (cannot be forced) - image is being used by running container 470c6b6fea50"
    server.script(errorReply(409, message))

    let error = try await withClient(server) { client in
      await failure { try await client.removeImage(.imageID("sha256:a731f68fd7e3")) }
    }

    #expect(error == .api(status: 409, message: message))
  }

  @Test func removingAMissingImageSurfacesTheNotFoundMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "No such image: gone:latest"))

    let error = try await withClient(server) { client in
      await failure { try await client.removeImage(.tag(repository: "gone", tag: "latest")) }
    }

    #expect(error == .api(status: 404, message: "No such image: gone:latest"))
  }

  // MARK: Volumes

  @Test func listsAllVolumesWithoutAFilter() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/volumes", jsonReply(try wireFixture("docker-volumes-list.json")))

    let volumes = try await withClient(server) { try await $0.listVolumes(danglingOnly: false) }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/volumes")
    #expect(request.query == nil)
    #expect(volumes.count == 5)
    #expect(volumes.first?.name == "cgprobe-vol-unref")
    #expect(volumes.filter(\.isAnonymous).count == 1)
  }

  @Test func listsDanglingVolumesWithAJSONFilterQuery() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/volumes",
      jsonReply(try wireFixture("docker-volumes-list-dangling.json")))

    let volumes = try await withClient(server) { try await $0.listVolumes(danglingOnly: true) }

    let request = try #require(server.requests.first)
    #expect(request.path == "/v1.54/volumes")
    #expect(request.queryItems == ["filters": #"{"dangling":["true"]}"#])
    #expect(request.query?.contains("%7B%22dangling%22%3A%5B%22true%22%5D%7D") == true)
    #expect(!volumes.isEmpty)
  }

  @Test func aVolumeListWithNullVolumesIsEmpty() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"{"Volumes":null,"Warnings":null}"#))

    let volumes = try await withClient(server) { try await $0.listVolumes(danglingOnly: false) }

    #expect(volumes.isEmpty)
  }

  @Test func readsVolumeSizesFromSystemDf() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      jsonReply(
        """
        {"VolumeUsage":{"Items":[
          {"Name":"a","UsageData":{"RefCount":0,"Size":4096}},
          {"Name":"b","UsageData":{"RefCount":1,"Size":-1}},
          {"Name":"c"}
        ]}}
        """))

    let sizes = try await withClient(server) { try await $0.volumeSizes() }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/system/df")
    #expect(request.queryItems == ["type": "volume", "verbose": "true"])
    #expect(sizes == ["a": .bytes(4096), "b": .unknown, "c": .unknown])
  }

  @Test func volumeSizesFromTheRealFixtureCoverEveryVolume() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(try wireFixture("docker-system-df-volume-verbose.json")))

    let sizes = try await withClient(server) { try await $0.volumeSizes() }

    #expect(sizes.count == 5)
    #expect(sizes["cgprobe-vol-unref"] == .bytes(0))
  }

  @Test func undecodableSystemDfBodyIsAnUnexpectedResponse() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply("[]"))

    let error = try await withClient(server) { client in
      await failure { try await client.volumeSizes() }
    }

    guard case .unexpectedResponse = error else {
      Issue.record("expected unexpectedResponse, got \(String(describing: error))")
      return
    }
  }

  @Test func removesAVolumeWithoutForceAsOnePercentEncodedSegment() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    try await withClient(server) { try await $0.removeVolume(name: "my/vol") }

    let request = try #require(server.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.path == "/v1.54/volumes/my%2Fvol")
    #expect(request.queryItems == ["force": "false"])
  }

  @Test func removingAVolumeInUseSurfacesTheConflictMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let message =
      "remove cgprobe-vol-ref-running: volume is in use - [470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74]"
    server.script(errorReply(409, message))

    let error = try await withClient(server) { client in
      await failure { try await client.removeVolume(name: "cgprobe-vol-ref-running") }
    }

    #expect(error == .api(status: 409, message: message))
  }

  @Test func removingAMissingVolumeSurfacesTheNotFoundMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "get gone: no such volume"))

    let error = try await withClient(server) { client in
      await failure { try await client.removeVolume(name: "gone") }
    }

    #expect(error == .api(status: 404, message: "get gone: no such volume"))
  }
}
