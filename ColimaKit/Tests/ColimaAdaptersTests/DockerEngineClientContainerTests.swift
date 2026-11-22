import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private let shortTimeouts = DockerHTTPTransport.Timeouts(
  read: .seconds(5),
  mutate: .seconds(5),
  logHead: .seconds(5)
)

private let containerID = ContainerID(
  rawValue: "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74")
private let containerPath = "/v1.54/containers/\(containerID.rawValue)"

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

/// Shuts the client down on every exit path; the underlying HTTP client traps in debug builds when dropped while running.
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

@Suite struct DockerEngineClientContainerTests {
  // MARK: List

  @Test func listsAllContainersIncludingStoppedOnes() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/containers/json",
      jsonReply(try wireFixture("docker-containers-list.json")))

    let summaries = try await withClient(server) { try await $0.listContainers() }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/containers/json")
    #expect(request.queryItems == ["all": "1"])
    #expect(summaries.count == 5)
    #expect(summaries.last?.id == containerID)
    #expect(summaries.last?.state == .running)
    #expect(summaries.first?.state == .other(rawState: "exited"))
  }

  @Test func emptyListIsEmpty() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply("[]"))

    let summaries = try await withClient(server) { try await $0.listContainers() }

    #expect(summaries.isEmpty)
  }

  @Test func undecodableListBodyIsAnUnexpectedResponse() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"{"not":"a list"}"#))

    let error = try await withClient(server) { client in
      await failure { try await client.listContainers() }
    }

    guard case .unexpectedResponse = error else {
      Issue.record("expected unexpectedResponse, got \(String(describing: error))")
      return
    }
  }

  // MARK: Inspect

  @Test func inspectsAContainerByID() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "\(containerPath)/json",
      jsonReply(try wireFixture("docker-container-inspect-running.json")))

    let detail = try await withClient(server) { try await $0.inspectContainer(id: containerID) }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "\(containerPath)/json")
    #expect(request.query == nil)
    #expect(detail.id == containerID)
    #expect(detail.isRunning)
  }

  @Test func containerIDsCannotChangeTheRoute() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "No such container: x"))

    _ = try await withClient(server) { client in
      await failure { try await client.inspectContainer(id: ContainerID(rawValue: "a/b?c")) }
    }

    #expect(server.requests.first?.path == "/v1.54/containers/a%2Fb%3Fc/json")
  }

  // MARK: Actions

  @Test(arguments: [(ContainerAction.start, "start"), (.stop, "stop"), (.restart, "restart")])
  func performsActionsWithAPOSTAndNoQuery(action: ContainerAction, segment: String) async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    try await withClient(server) { try await $0.perform(action, on: containerID) }

    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "\(containerPath)/\(segment)")
    #expect(request.query == nil)
    #expect(request.body.isEmpty)
  }

  @Test(arguments: [ContainerAction.start, .stop, .restart])
  func treatsNotModifiedAsSuccess(action: ContainerAction) async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 304)))

    try await withClient(server) { try await $0.perform(action, on: containerID) }

    #expect(server.requests.count == 1)
  }

  @Test func actionOnAMissingContainerKeepsTheEngineMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "No such container: 470c6b6f"))

    let error = try await withClient(server) { client in
      await failure { try await client.perform(.start, on: containerID) }
    }

    #expect(error == .api(status: 404, message: "No such container: 470c6b6f"))
  }

  @Test func serverErrorOnActionKeepsTheEngineMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(500, "driver failed programming external connectivity"))

    let error = try await withClient(server) { client in
      await failure { try await client.perform(.restart, on: containerID) }
    }

    #expect(error == .api(status: 500, message: "driver failed programming external connectivity"))
  }

  @Test func unexpectedRedirectStatusOnActionIsNotASuccess() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 301)))

    let error = try await withClient(server) { client in
      await failure { try await client.perform(.stop, on: containerID) }
    }

    guard case .unexpectedResponse = error else {
      Issue.record("expected unexpectedResponse, got \(String(describing: error))")
      return
    }
  }

  // MARK: Remove

  @Test func removesWithoutForceAndWithoutVolumes() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    try await withClient(server) { try await $0.removeContainer(id: containerID) }

    let request = try #require(server.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.path == containerPath)
    #expect(request.queryItems == ["force": "false", "v": "false"])
  }

  @Test func removingARunningContainerSurfacesTheConflictMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let message =
      "cannot remove container \\\"/web\\\": container is running: stop the container before removing or force remove"
    server.script(errorReply(409, message))

    let error = try await withClient(server) { client in
      await failure { try await client.removeContainer(id: containerID) }
    }

    #expect(
      error
        == .api(
          status: 409,
          message:
            #"cannot remove container "/web": container is running: stop the container before removing or force remove"#
        ))
  }

  @Test func removingAMissingContainerSurfacesTheNotFoundMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "No such container: 470c6b6f"))

    let error = try await withClient(server) { client in
      await failure { try await client.removeContainer(id: containerID) }
    }

    #expect(error == .api(status: 404, message: "No such container: 470c6b6f"))
  }

  // MARK: Stats

  @Test func fetchesOneNonStreamingStatsSample() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(try wireFixture("docker-container-stats-running.json")))

    let sample = try await withClient(server) { try await $0.containerStats(id: containerID) }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "\(containerPath)/stats")
    #expect(request.queryItems == ["stream": "false"])
    #expect(sample.cpuTotalUsage == 10_083_344_000)
    #expect(sample.previousCPUTotalUsage == 9_033_070_000)
    #expect(sample.onlineCPUs == 10)
  }

  @Test func statsOfAMissingContainerKeepTheEngineMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "No such container: 470c6b6f"))

    let error = try await withClient(server) { client in
      await failure { try await client.containerStats(id: containerID) }
    }

    #expect(error == .api(status: 404, message: "No such container: 470c6b6f"))
  }

  // MARK: Cancellation and shutdown

  @Test func aCancelledCallerGetsCancelledWhileTheEngineIsStillAnswering() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(.reply(ScriptedReply(gate: gate)))

    let result = try await withClient(server) { client in
      let task = Task { await failure { try await client.containerStats(id: containerID) } }
      #expect(await server.waitForRequests(count: 1))
      task.cancel()
      return await task.value
    }

    #expect(result == .cancelled)
  }

  @Test func aCancelledCallerDoesNotSendAMutation() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    let result = try await withClient(server) { client in
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await failure { try await client.removeContainer(id: containerID) }
      }
      return await task.value
    }

    #expect(result == .cancelled)
    #expect(server.requests.isEmpty)
  }

  @Test func cancellingAListReturnsCancelledRatherThanAFailure() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(.reply(ScriptedReply(gate: gate)))

    let result = try await withClient(server) { client in
      let task = Task { await failure { try await client.listContainers() } }
      #expect(await server.waitForRequests(count: 1))
      task.cancel()
      return await task.value
    }

    #expect(result == .cancelled)
  }

  @Test func shutdownIsIdempotentAndLaterCallsFailWithADockerError() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply("[]"))
    let client = DockerEngineClient(socketPath: server.socketPath, timeouts: shortTimeouts)

    await client.shutdown()
    await client.shutdown()
    let error = await failure { try await client.listContainers() }

    #expect(error != nil)
    #expect(server.requests.isEmpty)
  }

  @Test func missingSocketIsReportedAsUnreachable() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("cgs-absent-\(UUID().uuidString.prefix(8)).sock").path
    let client = DockerEngineClient(socketPath: path, timeouts: shortTimeouts)

    let error = await failure { try await client.listContainers() }
    await client.shutdown()

    guard case .engineUnreachable = error else {
      Issue.record("expected engineUnreachable, got \(String(describing: error))")
      return
    }
  }
}
