import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters

private let shortTimeouts = DockerHTTPTransport.Timeouts(
  read: .seconds(5),
  mutate: .seconds(5),
  logHead: .seconds(5)
)

private let containerID = ContainerID(
  rawValue: "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74")
private let logsPath = "/v1.54/containers/\(containerID.rawValue)/logs"

private final class ChunkRecorder: Sendable {
  private let state = Mutex<[[UInt8]]>([])
  var chunks: [[UInt8]] { state.withLock { $0 } }
  var bytes: [UInt8] { chunks.flatMap { $0 } }
  func append(_ chunk: [UInt8]) { state.withLock { $0.append(chunk) } }
}

private func withClient<T: Sendable>(
  _ server: TestUnixHTTPServer,
  _ body: (DockerEngineClient) async -> T
) async -> T {
  let client = DockerEngineClient(socketPath: server.socketPath, timeouts: shortTimeouts)
  let value = await body(client)
  await client.shutdown()
  return value
}

private func consume(
  _ client: DockerEngineClient,
  tail: Int = 500,
  follow: Bool,
  into recorder: ChunkRecorder
) async -> DockerError? {
  do throws(DockerError) {
    try await client.consumeLogs(id: containerID, tail: tail, follow: follow) {
      recorder.append($0)
    }
    return nil
  } catch {
    return error
  }
}

/// Spaces the writes out so each chunk is read before the stream is ended; the shared server ends a stream with a
/// half-close and unread bytes queued back to back with the end can otherwise be lost on Darwin.
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

@Suite struct DockerEngineClientLogTests {
  @Test func requestsBothStreamsWithTheTailAndFollowFlags() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: logsPath, .stream(stream))
    let feeder = feed(stream, [Array("line\n".utf8)]) { $0.finish() }

    let error = await withClient(server) {
      await consume($0, tail: 500, follow: true, into: ChunkRecorder())
    }
    await feeder.value

    #expect(error == nil)
    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == logsPath)
    #expect(request.queryItems == ["stdout": "1", "stderr": "1", "tail": "500", "follow": "1"])
  }

  @Test func aStoppedContainerIsReadWithoutFollowing() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: logsPath, .stream(stream))
    let feeder = feed(stream, []) { $0.finish() }

    let error = await withClient(server) {
      await consume($0, tail: 20, follow: false, into: ChunkRecorder())
    }
    await feeder.value

    #expect(error == nil)
    #expect(server.requests.first?.queryItems["follow"] == "0")
    #expect(server.requests.first?.queryItems["tail"] == "20")
  }

  @Test func passesRawChunksInOrderWithoutDecodingTheFrames() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: logsPath, .stream(stream))
    // Multiplex frame headers: stream kind, three zero bytes, big-endian length.
    let frame1: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 3] + Array("one".utf8)
    let frame2: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 3] + Array("two".utf8)
    let feeder = feed(stream, [frame1, frame2]) { $0.finish() }
    let recorder = ChunkRecorder()

    let error = await withClient(server) { await consume($0, follow: true, into: recorder) }
    await feeder.value

    #expect(error == nil)
    #expect(recorder.bytes == frame1 + frame2)
  }

  @Test func returnsNormallyWhenTheStreamEndsCleanly() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: logsPath, .stream(stream))
    let feeder = feed(stream, [Array("a".utf8), Array("b".utf8)]) { $0.finish() }
    let recorder = ChunkRecorder()

    let error = await withClient(server) { await consume($0, follow: false, into: recorder) }
    await feeder.value

    #expect(error == nil)
    #expect(String(decoding: recorder.bytes, as: UTF8.self) == "ab")
  }

  @Test func aMissingContainerIsA404WithTheEngineMessageAndNoChunk() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: logsPath,
      .reply(
        ScriptedReply(
          status: 404,
          headers: ["Content-Type": "application/json"],
          body: Array(#"{"message":"No such container: 470c6b6fea50"}"#.utf8)
        )))
    let recorder = ChunkRecorder()

    let error = await withClient(server) { await consume($0, follow: true, into: recorder) }

    #expect(error == .api(status: 404, message: "No such container: 470c6b6fea50"))
    #expect(recorder.chunks.isEmpty)
  }

  @Test func aStreamCutOffMidwayIsAConnectionLoss() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    server.script(method: "GET", path: logsPath, .stream(stream))
    let feeder = feed(stream, [Array("before".utf8)]) { $0.abort() }
    let recorder = ChunkRecorder()

    let error = await withClient(server) { await consume($0, follow: true, into: recorder) }
    await feeder.value

    guard case .connectionLost = error else {
      Issue.record("expected connectionLost, got \(String(describing: error))")
      return
    }
    #expect(String(decoding: recorder.bytes, as: UTF8.self) == "before")
  }

  @Test func cancellingReturnsCancelledAndClosesTheConnection() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    let stream = ScriptedStream()
    stream.send("hello")
    server.script(method: "GET", path: logsPath, .stream(stream))
    let recorder = ChunkRecorder()

    let error = await withClient(server) { client in
      let task = Task { await consume(client, follow: true, into: recorder) }
      #expect(await pollUntil { String(decoding: recorder.bytes, as: UTF8.self) == "hello" })
      task.cancel()
      let error = await task.value
      #expect(await stream.waitUntilClientDisconnected())
      return error
    }

    #expect(error == .cancelled)
  }
}
