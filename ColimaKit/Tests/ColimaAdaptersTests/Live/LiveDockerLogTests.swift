import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters

private final class ChunkCollector: Sendable {
  private let state = Mutex<[UInt8]>([])
  var bytes: [UInt8] { state.withLock { $0 } }
  func append(_ chunk: [UInt8]) { state.withLock { $0.append(contentsOf: chunk) } }
}

private func startedAndFinished(_ scope: LiveScope, _ id: ContainerID) async throws {
  try await scope.client.perform(.start, on: id)
  let finished = await waitUntil {
    (try? await scope.client.inspectContainer(id: id).isRunning) == false
  }
  #expect(finished, "the throwaway container should exit on its own")
}

private func readLog(_ client: DockerEngineClient, _ id: ContainerID, follow: Bool) async -> (
  bytes: [UInt8], error: DockerError?
) {
  let collector = ChunkCollector()
  let error = await failure { () async throws(DockerError) in
    try await client.consumeLogs(id: id, tail: 100, follow: follow) { collector.append($0) }
  }
  return (collector.bytes, error)
}

extension Live {
  @Suite struct EngineLogs {
    @Test @MainActor func nonTTYLogIsFramedAndLogSessionSplitsTheStreams() async throws {
      try await withLiveScope { scope in
        let container = try scope.createContainer(
          "log", script: "echo out-1; echo err-1 >&2; printf partial")
        let id = try scope.owned(container.id)
        try await startedAndFinished(scope, id)

        let (bytes, error) = await readLog(scope.client, id, follow: false)
        #expect(error == nil)
        #expect(bytes.first == 1 || bytes.first == 2, "the first byte is a stream type, not text")
        var decoder = LogFrameDecoder()
        let chunks = try decoder.append(Data(bytes))
        func text(_ stream: LogStreamKind) -> String {
          String(
            decoding: chunks.filter { $0.stream == stream }.flatMap { $0.payload }, as: UTF8.self)
        }
        #expect(text(.stdout) == "out-1\npartial")
        #expect(text(.stderr) == "err-1\n")

        let session = LogSession(engine: scope.client, container: id)
        await session.run()
        #expect(session.mode == .separated)
        #expect(session.state == .history)
        #expect(session.lines.filter { $0.stream == .stdout }.map(\.text) == ["out-1", "partial"])
        #expect(session.lines.filter { $0.stream == .stderr }.map(\.text) == ["err-1"])
        recordFinding(
          "(7) non-TTY log: \(bytes.count) bytes, 8-byte framed; LogFrameDecoder and LogSession produced stdout=[out-1, partial] stderr=[err-1] with state .history"
        )
      }
    }

    @Test @MainActor func ttyLogIsRawWithCarriageReturns() async throws {
      try await withLiveScope { scope in
        let container = try scope.createContainer(
          "tty", script: "echo tty-1; echo tty-2", extraArguments: ["-t"])
        let id = try scope.owned(container.id)
        #expect(try await scope.client.inspectContainer(id: id).hasTTY)
        try await startedAndFinished(scope, id)

        let (bytes, error) = await readLog(scope.client, id, follow: false)
        #expect(error == nil)
        #expect(String(decoding: bytes, as: UTF8.self) == "tty-1\r\ntty-2\r\n")

        let session = LogSession(engine: scope.client, container: id)
        await session.run()
        #expect(session.mode == .singleStream)
        #expect(session.state == .history)
        #expect(session.lines.map(\.text) == ["tty-1", "tty-2"])
        #expect(session.lines.allSatisfy { $0.stream == .combined })
        recordFinding(
          "(7) TTY log: raw \(bytes) (no frame header, CRLF line ends); LogSession mode .singleStream lines=[tty-1, tty-2]"
        )
      }
    }

    @Test @MainActor func followedLogEndsWhenTheContainerExits() async throws {
      try await withLiveScope { scope in
        let container = try scope.createContainer("follow", script: "echo f-1; sleep 2; echo f-2")
        let id = try scope.owned(container.id)
        try await scope.client.perform(.start, on: id)

        let session = LogSession(engine: scope.client, container: id)
        await bounded(.seconds(30)) { await session.run() }
        #expect(session.state == .ended(.streamClosed))
        #expect(session.lines.map(\.text) == ["f-1", "f-2"])
        recordFinding(
          "(7) followed non-TTY log of a container that exits: LogSession ended .streamClosed with lines [f-1, f-2]"
        )
      }
    }

    @Test @MainActor func cancellingAFollowedLogLeavesTheClientUsable() async throws {
      try await withLiveScope { scope in
        let container = try scope.createContainer(
          "tick", script: "while :; do echo tick; sleep 0.2; done")
        let id = try scope.owned(container.id)
        try await scope.client.perform(.start, on: id)

        let session = LogSession(engine: scope.client, container: id)
        let running = Task { @MainActor in await session.run() }
        let gotLines = await waitUntil { await MainActor.run { session.lines.count >= 3 } }
        #expect(gotLines)
        #expect(session.state == .following)

        running.cancel()
        await running.value
        #expect(session.state == .following, "a cancelled run changes no state")
        #expect(session.lines.allSatisfy { $0.text == "tick" })
        #expect(try await scope.client.listContainers().contains { $0.id == id })
        recordFinding(
          "(7) cancelling a followed log: run() returned, state stayed .following, the client served the next request"
        )
      }
    }
  }
}
