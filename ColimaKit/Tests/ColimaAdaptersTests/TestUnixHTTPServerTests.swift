import Darwin
import Foundation
import Testing

private func get(_ target: String) -> String {
  "GET \(target) HTTP/1.1\r\nHost: docker\r\n\r\n"
}

private func text(_ bytes: [UInt8]) -> String {
  String(decoding: bytes, as: UTF8.self)
}

@Suite struct TestUnixHTTPServerTests {
  @Test func servesTheScriptedStatusHeadersAndBody() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.43/containers/json",
      .reply(
        ScriptedReply(
          status: 409,
          headers: ["Content-Type": "application/json"],
          body: Array(#"{"message":"conflict"}"#.utf8)
        )))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/v1.43/containers/json"))
    let received = client.readToEOF()

    let response = try #require(ParsedHTTPResponse(received.bytes))
    #expect(received.reachedEOF)
    #expect(text(received.bytes).hasPrefix("HTTP/1.1 409 Conflict\r\n"))
    #expect(response.status == 409)
    #expect(response.headers["content-type"] == "application/json")
    #expect(response.headers["content-length"] == "22")
    #expect(text(response.body) == #"{"message":"conflict"}"#)
  }

  @Test func recordsMethodPathQueryHeadersAndContentLengthBody() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204)))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(
      "POST /v1.43/containers/abc/stop?t=5&name=a%20b HTTP/1.1\r\nHost: docker\r\nContent-Length: 4\r\n\r\nping"
    )
    _ = client.readToEOF()

    #expect(await server.waitForRequests(count: 1))
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1.43/containers/abc/stop")
    #expect(request.query == "t=5&name=a%20b")
    #expect(request.queryItems["name"] == "a b")
    #expect(request.queryItems["t"] == "5")
    #expect(request.headers["host"] == "docker")
    #expect(text(request.body) == "ping")
  }

  @Test func recordsRequestWithoutQueryAndDecodesChunkedBodies() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply()))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n")
    try client.send("2;ext=1\r\nde\r\n0\r\nTrailer: v\r\n\r\n")
    _ = client.readToEOF()

    #expect(await server.waitForRequests(count: 1))
    let request = try #require(server.requests.first)
    #expect(request.query == nil)
    #expect(text(request.body) == "abcde")
  }

  @Test func assemblesARequestThatArrivesInManySmallWrites() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(body: Array("ok".utf8))))

    let client = try RawSocketClient(path: server.socketPath)
    for piece in ["GET /sl", "ow?a=1 HTT", "P/1.1\r\nHo", "st: d\r\n", "\r\n"] {
      try client.send(piece)
    }
    let response = try #require(ParsedHTTPResponse(client.readToEOF().bytes))

    #expect(text(response.body) == "ok")
    #expect(await server.waitForRequests(count: 1))
    #expect(server.requests.first?.path == "/slow")
  }

  @Test func consumesBehaviorsInOrderAndRepeatsTheLastOne() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/a",
      .reply(ScriptedReply(body: Array("one".utf8))),
      .reply(ScriptedReply(body: Array("two".utf8))))

    var bodies: [String] = []
    for _ in 0..<3 {
      let client = try RawSocketClient(path: server.socketPath)
      try client.send(get("/a"))
      bodies.append(text(try #require(ParsedHTTPResponse(client.readToEOF().bytes)).body))
    }
    #expect(bodies == ["one", "two", "two"])
  }

  @Test func answers404ForUnmatchedMethodOrPathAndStillRecordsTheRequest() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(method: "POST", path: "/a", .reply(ScriptedReply(status: 201)))

    for request in [get("/a"), get("/b")] {
      let client = try RawSocketClient(path: server.socketPath)
      try client.send(request)
      #expect(try #require(ParsedHTTPResponse(client.readToEOF().bytes)).status == 404)
    }
    #expect(await server.waitForRequests(count: 2))
    #expect(server.requests.map(\.path) == ["/a", "/b"])
  }

  @Test func routesByPredicateOverTheRecordedRequest() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(matching: { $0.queryItems["follow"] == "1" }, .reply(ScriptedReply(status: 200)))

    let followed = try RawSocketClient(path: server.socketPath)
    try followed.send(get("/logs?follow=1"))
    let plain = try RawSocketClient(path: server.socketPath)
    try plain.send(get("/logs?follow=0"))

    #expect(try #require(ParsedHTTPResponse(followed.readToEOF().bytes)).status == 200)
    #expect(try #require(ParsedHTTPResponse(plain.readToEOF().bytes)).status == 404)
  }

  @Test func omitsTheBodyForNoContentStatuses() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(status: 204, body: Array("ignored".utf8))))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    let response = try #require(ParsedHTTPResponse(client.readToEOF().bytes))

    #expect(response.status == 204)
    #expect(response.body.isEmpty)
    #expect(response.headers["content-length"] == nil)
  }

  @Test func delaysTheReplyByAtLeastTheConfiguredDuration() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.reply(ScriptedReply(body: Array("late".utf8), delay: .milliseconds(400))))

    let client = try RawSocketClient(path: server.socketPath)
    let clock = ContinuousClock()
    let start = clock.now
    try client.send(get("/x"))
    let response = try #require(ParsedHTTPResponse(client.readToEOF().bytes))

    #expect(clock.now - start >= .milliseconds(380))
    #expect(text(response.body) == "late")
  }

  @Test func holdsTheReplyUntilTheGateIsReleased() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let gate = ResponseGate()
    server.script(.reply(ScriptedReply(body: Array("go".utf8), gate: gate)))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    #expect(await server.waitForRequests(count: 1))
    #expect(client.read(timeout: .milliseconds(200)) == .timedOut)

    gate.release()
    let response = try #require(ParsedHTTPResponse(client.readToEOF().bytes))
    #expect(text(response.body) == "go")
  }

  @Test func dropsTheConnectionWithoutAnyResponse() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(.dropConnection)

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    let received = client.readToEOF()

    #expect(received.reachedEOF)
    #expect(received.bytes.isEmpty)
    #expect(await server.waitForRequests(count: 1))
  }

  @Test func truncatesTheBodyAndClosesWhenAskedTo() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      .reply(ScriptedReply(body: [UInt8](repeating: 0x61, count: 100), truncatedBodyLength: 10)))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    let received = client.readToEOF()
    let response = try #require(ParsedHTTPResponse(received.bytes))

    #expect(received.reachedEOF)
    #expect(response.headers["content-length"] == "100")
    #expect(response.body.count == 10)
  }

  @Test func servesALargeBodyIntact() throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let body = (0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) }
    server.script(.reply(ScriptedReply(body: body)))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    let received = client.readToEOF()
    let response = try #require(ParsedHTTPResponse(received.bytes))

    #expect(received.reachedEOF)
    #expect(response.headers["content-length"] == String(body.count))
    #expect(response.body == body)
  }

  @Test func emitsStreamChunksWithChunkedFramingAndEndsWithTheTerminalChunk() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream(headers: ["Content-Type": "application/vnd.docker.raw-stream"])
    server.script(path: "/logs", .stream(stream))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/logs"))
    #expect(await stream.waitUntilOpened())

    stream.send("hello")
    let first = try #require(client.read(untilContains: "5\r\nhello\r\n"))
    let head = try #require(ParsedHTTPResponse(first))
    #expect(head.status == 200)
    #expect(head.headers["transfer-encoding"] == "chunked")
    #expect(head.headers["content-type"] == "application/vnd.docker.raw-stream")
    #expect(head.headers["content-length"] == nil)

    stream.send("wor")
    _ = try #require(client.read(untilContains: "3\r\nwor\r\n"))

    stream.finish()
    let rest = client.readToEOF()
    #expect(rest.reachedEOF)
    #expect(text(rest.bytes) == "0\r\n\r\n")
  }

  @Test func deliversChunksQueuedBeforeTheClientConnects() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))
    stream.send("early")
    stream.finish()

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    let received = client.readToEOF()

    #expect(received.reachedEOF)
    #expect(text(received.bytes).hasSuffix("5\r\nearly\r\n0\r\n\r\n"))
  }

  @Test func abortEndsTheStreamWithoutTheTerminalChunk() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    #expect(await stream.waitUntilOpened())
    stream.send("partial")
    stream.abort()
    let received = client.readToEOF()

    #expect(received.reachedEOF)
    #expect(text(received.bytes).hasSuffix("7\r\npartial\r\n"))
    #expect(!text(received.bytes).contains("0\r\n\r\n"))
  }

  @Test func notesWhenTheClientHangsUpOnAStream() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(.stream(stream))

    let client = try RawSocketClient(path: server.socketPath)
    try client.send(get("/x"))
    #expect(await stream.waitUntilOpened())
    #expect(!stream.clientDisconnected)

    client.close()
    #expect(await stream.waitUntilClientDisconnected())
  }

  @Test func holdsManyStreamsOpenAtTheSameTime() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let streams = (0..<16).map { _ in ScriptedStream() }
    for (index, stream) in streams.enumerated() {
      server.script(path: "/s\(index)", .stream(stream))
    }

    var clients: [RawSocketClient] = []
    for index in streams.indices {
      let client = try RawSocketClient(path: server.socketPath)
      try client.send(get("/s\(index)"))
      clients.append(client)
      #expect(await server.waitForRequests(count: clients.count))
    }
    for stream in streams {
      #expect(await stream.waitUntilOpened())
      stream.finish()
    }
    for client in clients {
      #expect(client.readToEOF().reachedEOF)
    }
  }

  @Test func stopClosesHeldConnectionsAndRemovesTheSocketFile() async throws {
    let server = try TestUnixHTTPServer.start()
    let gate = ResponseGate()
    server.script(path: "/held", .reply(ScriptedReply(gate: gate)))
    let stream = ScriptedStream()
    server.script(path: "/stream", .stream(stream))

    #expect(server.socketPath.utf8.count < 104)
    #expect(FileManager.default.fileExists(atPath: server.socketPath))

    let held = try RawSocketClient(path: server.socketPath)
    try held.send(get("/held"))
    let streaming = try RawSocketClient(path: server.socketPath)
    try streaming.send(get("/stream"))
    #expect(await server.waitForRequests(count: 2))
    #expect(await stream.waitUntilOpened())

    server.stop()

    #expect(held.readToEOF(timeout: .seconds(5)).reachedEOF)
    #expect(streaming.readToEOF(timeout: .seconds(5)).reachedEOF)
    #expect(!FileManager.default.fileExists(atPath: server.socketPath))
    #expect(throws: RawSocketError.self) { _ = try RawSocketClient(path: server.socketPath) }
    server.stop()
  }
}
