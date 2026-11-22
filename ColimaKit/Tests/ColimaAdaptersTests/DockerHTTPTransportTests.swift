import ColimaCore
import Darwin
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters

private let shortTimeouts = DockerHTTPTransport.Timeouts(
  read: .milliseconds(300),
  mutate: .seconds(3),
  logHead: .milliseconds(300)
)

private func json(_ text: String) -> ScriptedReply {
  ScriptedReply(status: 200, headers: ["Content-Type": "application/json"], body: Array(text.utf8))
}

private func apiError(_ status: Int, _ body: String) -> ScriptedBehavior {
  .reply(
    ScriptedReply(
      status: status, headers: ["Content-Type": "application/json"], body: Array(body.utf8)))
}

/// Shuts the transport down on every exit path; an AsyncHTTPClient dropped while running traps in debug builds.
private func withTransport<T: Sendable>(
  socketPath: String,
  timeouts: DockerHTTPTransport.Timeouts = shortTimeouts,
  maxBodyBytes: Int = DockerHTTPTransport.maxBodyBytes,
  requestConnectionLimit: Int = DockerHTTPTransport.requestConnectionLimit,
  logConnectionLimit: Int = DockerHTTPTransport.logConnectionLimit,
  _ body: (DockerHTTPTransport) async throws -> T
) async throws -> T {
  let transport = DockerHTTPTransport(
    socketPath: socketPath,
    timeouts: timeouts,
    maxBodyBytes: maxBodyBytes,
    requestConnectionLimit: requestConnectionLimit,
    logConnectionLimit: logConnectionLimit
  )
  do {
    let value = try await body(transport)
    await transport.shutdown()
    return value
  } catch {
    await transport.shutdown()
    throw error
  }
}

private func asDockerError(_ error: any Error) -> DockerError {
  if let error = error as? DockerError { return error }
  Issue.record("the transport threw a non-DockerError: \(error)")
  return .unexpectedResponse(detail: String(describing: error))
}

private func outcome(
  _ operation: () async throws -> DockerResponse
) async -> Result<DockerResponse, DockerError> {
  do { return .success(try await operation()) } catch { return .failure(asDockerError(error)) }
}

private func streamOutcome(_ operation: () async throws -> Void) async -> DockerError? {
  do {
    try await operation()
    return nil
  } catch {
    return asDockerError(error)
  }
}

private final class ChunkCollector: Sendable {
  private let state = Mutex<[UInt8]>([])
  var bytes: [UInt8] { state.withLock { $0 } }
  var text: String { String(decoding: bytes, as: UTF8.self) }
  func append(_ chunk: [UInt8]) { state.withLock { $0 += chunk } }
}

/// Spaces writes so each chunk is read before the stream ends; same Darwin lost-bytes race as `feed` in DockerEngineClientLogTests.
private func feed(
  _ stream: ScriptedStream,
  _ chunks: [[UInt8]],
  then end: @escaping @Sendable (ScriptedStream) -> Void
) -> Task<Void, Never> {
  Task {
    guard await stream.waitUntilOpened() else { return }
    for chunk in chunks {
      stream.send(chunk)
      try? await Task.sleep(for: .milliseconds(100))
    }
    end(stream)
  }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func missingSocketPath() -> String {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "cgs-absent-\(UUID().uuidString.prefix(8)).sock"
  ).path
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
  let elapsed = ContinuousClock.now - start
  return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

@Suite struct DockerHTTPTransportTests {
  // MARK: Requests and responses

  @Test func returnsStatusAndBodyOfASuccessfulRequest() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(method: "GET", path: "/v1.43/containers/json", .reply(json(#"[{"Id":"abc"}]"#)))

    let response = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(
        DockerRequest(.get, ["v1.43", "containers", "json"]), deadline: .read)
    }

    #expect(response.status == 200)
    #expect(String(decoding: response.body, as: UTF8.self) == #"[{"Id":"abc"}]"#)
    #expect(server.requests.count == 1)
  }

  @Test func percentEncodesPathSegmentsAndQueryItems() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    _ = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(
        DockerRequest(
          .post,
          ["v1.43", "containers", "a b/c?#é", "stop"],
          query: [
            URLQueryItem(name: "t", value: "5"),
            URLQueryItem(name: "filters", value: #"{"dangling":["true"]}"#),
          ]
        ),
        deadline: .mutate
      )
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1.43/containers/a%20b%2Fc%3F%23%C3%A9/stop")
    #expect(request.queryItems["t"] == "5")
    #expect(request.queryItems["filters"] == #"{"dangling":["true"]}"#)
  }

  @Test func sendsAJSONBodyWithItsContentType() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(json(#"{"Id":"net1"}"#)))
    let payload = Array(#"{"Name":"n"}"#.utf8)

    _ = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(
        DockerRequest(.post, ["networks", "create"], jsonBody: payload), deadline: .mutate)
    }

    let request = try #require(server.requests.first)
    #expect(request.body == payload)
    #expect(request.headers["content-type"] == "application/json")
  }

  @Test func sendsAHostHeaderBecauseHTTP11EnginesRejectRequestsWithoutOne() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    _ = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(DockerRequest(.get, ["_ping"]), deadline: .read)
    }

    #expect(server.requests.first?.headers["host"] == "docker")
  }

  @Test func sendsDeleteWithoutABody() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    let response = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(DockerRequest(.delete, ["containers", "abc"]), deadline: .mutate)
    }

    #expect(response.status == 204)
    #expect(response.body.isEmpty)
    #expect(server.requests.first?.method == "DELETE")
  }

  @Test func treatsNotModifiedAsAResponseRatherThanAnError() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 304)))

    let response = try await withTransport(socketPath: server.socketPath) { transport in
      try await transport.send(
        DockerRequest(.post, ["containers", "abc", "start"]), deadline: .mutate)
    }

    #expect(response.status == 304)
  }

  // MARK: Error bodies

  @Test func keepsTheEngineErrorMessageVerbatim() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let message =
      "Conflict. The container name \"/web\" is already in use by container \"ab12\".  Trailing 日本語 "
    let body = String(
      decoding: try JSONSerialization.data(withJSONObject: ["message": message]), as: UTF8.self)
    server.script(apiError(409, body))

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.post, ["containers", "create"]), deadline: .mutate)
    }

    #expect(result == .failure(.api(status: 409, message: message)))
  }

  @Test func fallsBackToTheTextBodyWhenTheErrorIsNotJSON() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 404, body: Array("page not found\n".utf8))))

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["nope"]), deadline: .read)
    }

    #expect(result == .failure(.api(status: 404, message: "page not found")))
  }

  @Test func namesTheStatusWhenTheErrorBodyIsEmpty() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 500)))

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["boom"]), deadline: .read)
    }

    #expect(result == .failure(.api(status: 500, message: "HTTP 500")))
  }

  // MARK: Deadlines

  @Test func readRequestsTimeOutWhenNoHeadArrives() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    server.script(.reply(ScriptedReply(gate: gate)))
    defer { gate.release() }

    let start = ContinuousClock.now
    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
    }

    #expect(result == .failure(.timedOut))
    #expect(seconds(since: start) < 2.5)
  }

  @Test func theDeadlineAlsoBoundsAStalledBody() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    stream.send("partial")
    server.script(.stream(stream))

    let start = ContinuousClock.now
    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
    }

    #expect(result == .failure(.timedOut))
    #expect(seconds(since: start) < 2.5)
  }

  @Test func mutatingRequestsGetTheLongerDeadline() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(method: "POST", .reply(ScriptedReply(status: 204, delay: .milliseconds(700))))
    server.script(method: "GET", .reply(ScriptedReply(status: 204, delay: .milliseconds(700))))

    let (mutate, read) = try await withTransport(socketPath: server.socketPath) { transport in
      let mutate = await outcome {
        try await transport.send(
          DockerRequest(.post, ["containers", "a", "stop"]), deadline: .mutate)
      }
      let read = await outcome {
        try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
      }
      return (mutate, read)
    }

    #expect(mutate == .success(DockerResponse(status: 204, body: [])))
    #expect(read == .failure(.timedOut))
  }

  @Test func defaultDeadlinesAreTenAndSixtySeconds() {
    #expect(DockerHTTPTransport.Timeouts.standard.read == .seconds(10))
    #expect(DockerHTTPTransport.Timeouts.standard.mutate == .seconds(60))
    #expect(DockerHTTPTransport.Timeouts.standard.logHead == .seconds(10))
    #expect(DockerHTTPTransport.maxBodyBytes == 16 * 1024 * 1024)
  }

  // MARK: Body limit

  @Test func rejectsABodyOverTheLimit() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(body: [UInt8](repeating: 0x61, count: 2048))))

    let result = await withTransportOutcome(server, maxBodyBytes: 1024) { transport in
      try await transport.send(DockerRequest(.get, ["big"]), deadline: .read)
    }

    guard case .failure(.unexpectedResponse) = result else {
      Issue.record("expected unexpectedResponse, got \(result)")
      return
    }
  }

  @Test func rejectsAChunkedBodyThatGrowsPastTheLimit() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))
    let feeder = feed(
      stream, [[UInt8](repeating: 0x61, count: 600), [UInt8](repeating: 0x62, count: 600)]
    ) { $0.finish() }

    let result = await withTransportOutcome(server, maxBodyBytes: 1024) { transport in
      try await transport.send(DockerRequest(.get, ["big"]), deadline: .mutate)
    }
    await feeder.value

    guard case .failure(.unexpectedResponse) = result else {
      Issue.record("expected unexpectedResponse, got \(result)")
      return
    }
  }

  @Test func acceptsABodyExactlyAtTheLimit() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(body: [UInt8](repeating: 0x61, count: 1024))))

    let result = await withTransportOutcome(server, maxBodyBytes: 1024) { transport in
      try await transport.send(DockerRequest(.get, ["edge"]), deadline: .read)
    }

    #expect(
      result == .success(DockerResponse(status: 200, body: [UInt8](repeating: 0x61, count: 1024))))
  }

  @Test func capsAnErrorBodyToo() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 500, body: [UInt8](repeating: 0x61, count: 2048))))

    let result = await withTransportOutcome(server, maxBodyBytes: 1024) { transport in
      try await transport.send(DockerRequest(.get, ["big"]), deadline: .read)
    }

    guard case .failure(.unexpectedResponse) = result else {
      Issue.record("expected unexpectedResponse, got \(result)")
      return
    }
  }

  // MARK: Connection failures

  @Test func reportsAMissingSocketAsUnreachableWithoutWaitingOutTheDeadline() async throws {
    let start = ContinuousClock.now
    let result = try await withTransport(
      socketPath: missingSocketPath(),
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      await outcome { try await transport.send(DockerRequest(.get, ["_ping"]), deadline: .read) }
    }

    guard case .failure(.engineUnreachable) = result else {
      Issue.record("expected engineUnreachable, got \(result)")
      return
    }
    #expect(seconds(since: start) < 4)
  }

  @Test func reportsARefusedConnectionAsUnreachable() async throws {
    let path = missingSocketPath()
    let listener = try bindListeningSocket(at: path)
    Darwin.close(listener)
    defer { unlink(path) }

    let start = ContinuousClock.now
    let result = try await withTransport(
      socketPath: path,
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      await outcome { try await transport.send(DockerRequest(.get, ["_ping"]), deadline: .read) }
    }

    guard case .failure(.engineUnreachable) = result else {
      Issue.record("expected engineUnreachable, got \(result)")
      return
    }
    #expect(seconds(since: start) < 4)
  }

  @Test func reportsAMissingSocketOnTheLogClientAsUnreachable() async throws {
    let start = ContinuousClock.now
    let error = try await withTransport(
      socketPath: missingSocketPath(),
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) { _ in }
      }
    }

    guard case .engineUnreachable = error else {
      Issue.record("expected engineUnreachable, got \(String(describing: error))")
      return
    }
    #expect(seconds(since: start) < 4)
  }

  @Test func reportsADroppedConnectionAsConnectionLost() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.dropConnection)

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(
        DockerRequest(.post, ["containers", "a", "stop"]), deadline: .mutate)
    }

    guard case .failure(.connectionLost) = result else {
      Issue.record("expected connectionLost, got \(result)")
      return
    }
  }

  @Test func reportsATruncatedBodyAsConnectionLost() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(body: Array("0123456789".utf8), truncatedBodyLength: 4)))

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
    }

    guard case .failure(.connectionLost) = result else {
      Issue.record("expected connectionLost, got \(result)")
      return
    }
  }

  @Test func reportsAnAbortedChunkedBodyAsConnectionLost() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))
    let feeder = feed(stream, [bytes("part")]) { $0.abort() }

    let result = await withTransportOutcome(server) { transport in
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .mutate)
    }
    await feeder.value

    guard case .failure(.connectionLost) = result else {
      Issue.record("expected connectionLost, got \(result)")
      return
    }
  }

  // MARK: Pool

  @Test func waitingForAFreeConnectionTimesOutRatherThanReportingUnreachable() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(method: "POST", .reply(ScriptedReply(status: 204, gate: gate)))
    server.script(method: "GET", .reply(ScriptedReply(status: 204)))

    let (queued, held) = try await withTransport(
      socketPath: server.socketPath, requestConnectionLimit: 1
    ) { transport in
      let holder = Task {
        await outcome {
          try await transport.send(DockerRequest(.post, ["slow"]), deadline: .mutate)
        }
      }
      #expect(await server.waitForRequests(count: 1))
      let queued = await outcome {
        try await transport.send(DockerRequest(.get, ["fast"]), deadline: .read)
      }
      gate.release()
      return (queued, await holder.value)
    }

    #expect(queued == .failure(.timedOut))
    #expect(held == .success(DockerResponse(status: 204, body: [])))
  }

  @Test func connectionLimitsAreEightForRequestsAndSixteenForLogs() {
    #expect(DockerHTTPTransport.requestConnectionLimit == 8)
    #expect(DockerHTTPTransport.logConnectionLimit == 16)
  }

  @Test func requestsAreServedConcurrentlyUpToTheLimit() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(.reply(ScriptedReply(status: 204, gate: gate)))

    let statuses = try await withTransport(
      socketPath: server.socketPath,
      timeouts: .init(read: .seconds(5), mutate: .seconds(5), logHead: .seconds(5))
    ) { transport in
      let tasks = (0..<4).map { index in
        Task {
          await outcome {
            try await transport.send(DockerRequest(.get, ["r\(index)"]), deadline: .read)
          }
        }
      }
      #expect(await server.waitForRequests(count: 4))
      gate.release()
      var results: [Result<DockerResponse, DockerError>] = []
      for task in tasks { results.append(await task.value) }
      return results
    }

    #expect(statuses.allSatisfy { $0 == .success(DockerResponse(status: 204, body: [])) })
  }

  // MARK: Logs

  @Test func streamsChunksInOrderAndReturnsAtTheEndOfTheStream() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: "/containers/a/logs", .stream(stream))
    let feeder = feed(stream, [bytes("one,"), bytes("two,"), bytes("three")]) { $0.finish() }
    let collector = ChunkCollector()

    let error = try await withTransport(socketPath: server.socketPath) { transport in
      await streamOutcome {
        try await transport.stream(
          DockerRequest(
            .get, ["containers", "a", "logs"], query: [URLQueryItem(name: "follow", value: "1")])
        ) { collector.append($0) }
      }
    }
    await feeder.value

    #expect(error == nil)
    #expect(collector.text == "one,two,three")
    #expect(server.requests.first?.queryItems["follow"] == "1")
  }

  @Test func theLogBodyHasNoDeadline() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))
    let collector = ChunkCollector()

    let error = try await withTransport(socketPath: server.socketPath) { transport in
      let feeder = Task {
        guard await stream.waitUntilOpened() else { return }
        try? await Task.sleep(for: .milliseconds(1000))
        stream.send("late")
        try? await Task.sleep(for: .milliseconds(100))
        stream.finish()
      }
      let error = await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) {
          collector.append($0)
        }
      }
      await feeder.value
      return error
    }

    #expect(error == nil)
    #expect(collector.text == "late")
  }

  @Test func logsTimeOutWhenTheHeadNeverArrives() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(.reply(ScriptedReply(gate: gate)))

    let start = ContinuousClock.now
    let error = try await withTransport(socketPath: server.socketPath) { transport in
      await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) { _ in }
      }
    }

    #expect(error == .timedOut)
    #expect(seconds(since: start) < 2.5)
  }

  @Test func logsExtractTheEngineMessageFromAnErrorStatus() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(apiError(404, #"{"message":"No such container: a"}"#))

    let error = try await withTransport(socketPath: server.socketPath) { transport in
      await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) { _ in }
      }
    }

    #expect(error == .api(status: 404, message: "No such container: a"))
  }

  @Test func aLogStreamCutOffMidwayIsAConnectionLoss() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))
    let feeder = feed(stream, [bytes("before")]) { $0.abort() }
    let collector = ChunkCollector()

    let error = try await withTransport(socketPath: server.socketPath) { transport in
      await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) {
          collector.append($0)
        }
      }
    }
    await feeder.value

    guard case .connectionLost = error else {
      Issue.record("expected connectionLost, got \(String(describing: error))")
      return
    }
    #expect(collector.text == "before")
  }

  @Test func cancellingALogStreamReturnsCancelledAndClosesTheConnection() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    stream.send("hello")
    server.script(.stream(stream))
    let collector = ChunkCollector()

    let error = try await withTransport(socketPath: server.socketPath) { transport in
      let task = Task {
        await streamOutcome {
          try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) {
            collector.append($0)
          }
        }
      }
      #expect(await pollUntil { collector.text == "hello" })
      task.cancel()
      let error = await task.value
      #expect(await stream.waitUntilClientDisconnected())
      return error
    }

    #expect(error == .cancelled)
  }

  @Test func logsAndRequestsUseSeparateConnectionPools() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let held = ScriptedStream()
    held.send("held")
    server.script(method: "GET", path: "/containers/a/logs", .stream(held))
    server.script(method: "GET", path: "/_ping", .reply(ScriptedReply(body: Array("OK".utf8))))
    let collector = ChunkCollector()

    let (blocked, ping) = try await withTransport(
      socketPath: server.socketPath, logConnectionLimit: 1
    ) { transport in
      let first = Task {
        await streamOutcome {
          try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) {
            collector.append($0)
          }
        }
      }
      #expect(await pollUntil { collector.text == "held" })

      let blocked = await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) { _ in }
      }
      let ping = await outcome {
        try await transport.send(DockerRequest(.get, ["_ping"]), deadline: .read)
      }
      held.finish()
      _ = await first.value
      return (blocked, ping)
    }

    #expect(blocked == .timedOut)
    #expect(ping == .success(DockerResponse(status: 200, body: Array("OK".utf8))))
  }

  // MARK: Cancellation

  @Test func cancellingWhileWaitingForTheHeadReturnsCancelledNotTimedOut() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    defer { gate.release() }
    server.script(.reply(ScriptedReply(gate: gate)))

    let result = try await withTransport(
      socketPath: server.socketPath,
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      let task = Task {
        await outcome {
          try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
        }
      }
      #expect(await server.waitForRequests(count: 1))
      task.cancel()
      return await task.value
    }

    #expect(result == .failure(.cancelled))
  }

  @Test func cancellingMidBodyNeverReturnsATruncatedSuccess() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    stream.send("partial")
    server.script(.stream(stream))

    let result = try await withTransport(
      socketPath: server.socketPath,
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      let task = Task {
        await outcome {
          try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
        }
      }
      #expect(await server.waitForRequests(count: 1))
      try await Task.sleep(for: .milliseconds(150))
      task.cancel()
      return await task.value
    }

    #expect(result == .failure(.cancelled))
  }

  @Test func aTaskCancelledBeforeTheCallNeverTouchesTheSocket() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(json("[]")))

    let result = try await withTransport(socketPath: server.socketPath) { transport in
      let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return await outcome {
          try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
        }
      }
      task.cancel()
      return await task.value
    }

    #expect(result == .failure(.cancelled))
    #expect(server.requests.isEmpty)
  }

  @Test func cancellationWinsOverAConnectionFailure() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    server.script(.reply(ScriptedReply(gate: gate)))

    let result = try await withTransport(
      socketPath: server.socketPath,
      timeouts: .init(read: .seconds(8), mutate: .seconds(8), logHead: .seconds(8))
    ) { transport in
      let task = Task {
        await outcome {
          try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
        }
      }
      #expect(await server.waitForRequests(count: 1))
      task.cancel()
      server.stop()
      return await task.value
    }

    #expect(result == .failure(.cancelled))
  }

  // MARK: Shutdown

  @Test func shutdownClosesBothClientsAndIsIdempotent() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(json("[]")))
    let transport = DockerHTTPTransport(socketPath: server.socketPath)

    let first = await outcome {
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
    }
    await transport.shutdown()
    await transport.shutdown()
    let afterSend = await outcome {
      try await transport.send(DockerRequest(.get, ["containers", "json"]), deadline: .read)
    }
    let afterStream = await streamOutcome {
      try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) { _ in }
    }

    #expect(first == .success(DockerResponse(status: 200, body: Array("[]".utf8))))
    guard case .failure(let sendError) = afterSend, case .engineUnreachable = sendError,
      case .engineUnreachable = afterStream
    else {
      Issue.record(
        "requests after shutdown must report unreachable, got \(afterSend) and \(String(describing: afterStream))"
      )
      return
    }
  }

  @Test func shutdownWithAFollowedLogStillOpenReturnsPromptlyAndEndsTheStream() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    stream.send("running")
    server.script(.stream(stream))
    let collector = ChunkCollector()
    let transport = DockerHTTPTransport(socketPath: server.socketPath)

    let follower = Task {
      await streamOutcome {
        try await transport.stream(DockerRequest(.get, ["containers", "a", "logs"])) {
          collector.append($0)
        }
      }
    }
    #expect(await pollUntil { collector.text == "running" })
    let start = ContinuousClock.now
    await transport.shutdown()
    let error = await follower.value

    #expect(seconds(since: start) < 5)
    guard case .connectionLost = error else {
      Issue.record("expected connectionLost, got \(String(describing: error))")
      return
    }
  }
}

private func withTransportOutcome(
  _ server: TestUnixHTTPServer,
  maxBodyBytes: Int = DockerHTTPTransport.maxBodyBytes,
  _ operation: (DockerHTTPTransport) async throws -> DockerResponse
) async -> Result<DockerResponse, DockerError> {
  let transport = DockerHTTPTransport(
    socketPath: server.socketPath,
    timeouts: shortTimeouts,
    maxBodyBytes: maxBodyBytes
  )
  let result = await outcome { try await operation(transport) }
  await transport.shutdown()
  return result
}
