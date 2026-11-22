import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

@Suite struct DockerEngineClientConformanceTests {
  @Test func clientIsUsableAsTheEnginePort() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/containers/json",
      .reply(
        ScriptedReply(
          status: 200, headers: ["Content-Type": "application/json"], body: Array("[]".utf8))))

    let client = DockerEngineClient(socketPath: server.socketPath)
    let engine: any DockerEngine = client
    do {
      let summaries = try await engine.listContainers()
      #expect(summaries.isEmpty)
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }
}
