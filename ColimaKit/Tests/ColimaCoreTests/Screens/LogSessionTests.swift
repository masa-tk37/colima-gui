import Foundation
import Observation
import Testing

@testable import ColimaCore

private let web = ContainerID(rawValue: "web")

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func stdout(_ text: String) -> [UInt8] { LogFixture.frame(1, text) }
private func stderr(_ text: String) -> [UInt8] { LogFixture.frame(2, text) }

private func texts(_ lines: [LogLine]) -> [String] { lines.map(\.text) }

@MainActor
private struct Harness {
  let engine = FakeDockerEngine()
  let session: LogSession

  init(
    running: Bool = true, tty: Bool = false, lineLimit: Int = LogSession.defaultLineLimit,
    _ configure: (inout FakeDockerEngine.Config) -> Void = { _ in }
  ) {
    engine.configure {
      $0.containerDetails[web] = .success(
        ContainerDetail(id: web, hasTTY: tty, isRunning: running, networkNames: []))
      configure(&$0)
    }
    session = LogSession(engine: engine, container: web, lineLimit: lineLimit)
  }

  func start() -> Task<Void, Never> {
    let session = session
    return Task { await session.run() }
  }

  func wait(until condition: @escaping @MainActor @Sendable () -> Bool) async {
    for await holds in Observations({ condition() }) where holds { return }
  }

  var logCalls: [FakeDockerEngine.Call] {
    engine.calls.filter { if case .consumeLogs = $0 { true } else { false } }
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LogSessionTests {

  @Test func aRunningContainerIsFollowedWithTheLast500Lines() async {
    let harness = Harness { $0.logChunks[web] = [stdout("a\nb\n")] }
    await harness.session.run()
    #expect(
      harness.engine.calls == [
        .inspectContainer(web),
        .consumeLogs(id: web, tail: 500, follow: true),
      ])
  }

  @Test func aStoppedContainerIsNotFollowedAndStaysInHistory() async {
    let harness = Harness(running: false) { $0.logChunks[web] = [stdout("old\n")] }
    await harness.session.run()
    #expect(harness.logCalls == [.consumeLogs(id: web, tail: 500, follow: false)])
    #expect(harness.session.state == .history)
    #expect(texts(harness.session.lines) == ["old"])
  }

  @Test func theStateIsLoadingUntilInspectReturns() async {
    let gate = ArrivalGate()
    let harness = Harness { config in
      config.beforeReturn = { call in if call == .inspectContainer(web) { await gate.pass() } }
    }
    #expect(harness.session.state == .loading)
    let task = harness.start()
    await gate.waitForArrivals(1)
    #expect(harness.session.state == .loading)
    #expect(harness.logCalls.isEmpty)
    task.cancel()
    gate.open()
    await task.value
  }

  @Test func cancellingBeforeInspectReturnsLeavesTheStateAlone() async {
    let gate = ArrivalGate()
    let harness = Harness { config in
      config.beforeReturn = { call in if call == .inspectContainer(web) { await gate.pass() } }
    }
    let task = harness.start()
    await gate.waitForArrivals(1)
    task.cancel()
    gate.open()
    await task.value
    #expect(harness.session.state == .loading)
    #expect(harness.logCalls.isEmpty)
  }

  @Test func aStreamThatClosesKeepsItsLinesAndEnds() async {
    let harness = Harness { $0.logChunks[web] = [stdout("one\ntwo\n")] }
    await harness.session.run()
    #expect(harness.session.state == .ended(.streamClosed))
    #expect(texts(harness.session.lines) == ["one", "two"])
    #expect(harness.session.provisionalLines.isEmpty)
  }

  @Test func cancellingTheFollowedStreamIsNotAFailureAndKeepsTheState() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("one\n")]
      $0.logStreamStaysOpen = true
    }
    let task = harness.start()
    await harness.wait { !harness.session.lines.isEmpty }
    #expect(harness.session.state == .following)
    task.cancel()
    await task.value
    #expect(harness.session.state == .following)
    #expect(texts(harness.session.lines) == ["one"])
  }

  @Test func aRunningContainerThatIsGoneAtInspectEnds404AsContainerGone() async {
    let harness = Harness { $0.containerDetails[web] = nil }
    await harness.session.run()
    #expect(harness.session.state == .ended(.containerGone))
    #expect(harness.logCalls.isEmpty)
  }

  @Test func anInspectFailureEndsAsFailedWithTheDisplayMessage() async {
    let error = DockerError.engineUnreachable(detail: "no socket")
    let harness = Harness { $0.containerDetails[web] = .failure(error) }
    await harness.session.run()
    #expect(harness.session.state == .ended(.failed(error.displayMessage)))
  }

  @Test func aMidStream404EndsAsContainerGoneAndKeepsTheLinesIncludingThePendingTail() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("kept\ntail")]
      $0.logFailures[web] = .api(status: 404, message: "No such container: web")
    }
    await harness.session.run()
    #expect(harness.session.state == .ended(.containerGone))
    #expect(texts(harness.session.lines) == ["kept", "tail"])
    #expect(harness.session.provisionalLines.isEmpty)
  }

  @Test func aConnectionCutEndsAsFailedAndKeepsTheLines() async {
    let error = DockerError.connectionLost(detail: "reset")
    let harness = Harness {
      $0.logChunks[web] = [stdout("kept\n")]
      $0.logFailures[web] = error
    }
    await harness.session.run()
    #expect(harness.session.state == .ended(.failed(error.displayMessage)))
    #expect(texts(harness.session.lines) == ["kept"])
  }

  @Test func aNon404APIErrorEndsAsFailedWithTheEngineMessage() async {
    let harness = Harness { $0.logFailures[web] = .api(status: 500, message: "boom") }
    await harness.session.run()
    #expect(harness.session.state == .ended(.failed("boom")))
  }

  @Test func aCancelledErrorFromTheStreamLeavesTheStateAlone() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("a\n")]
      $0.logFailures[web] = .cancelled
    }
    await harness.session.run()
    #expect(harness.session.state == .following)
    #expect(texts(harness.session.lines) == ["a"])
  }

  // MARK: Provisional lines

  @Test func anUnterminatedChunkIsProvisionalAndMovesToLinesWithTheSameIDWhenTheNewlineArrives()
    async
  {
    let gates = [ArrivalGate(), ArrivalGate()]
    let harness = Harness {
      $0.logChunks[web] = [stdout("par"), stdout("tial\nrest")]
      $0.logStreamStaysOpen = true
      $0.afterLogChunk = { index in await gates[index].pass() }
    }
    let task = harness.start()
    await gates[0].waitForArrivals(1)
    let session = harness.session
    #expect(session.lines.isEmpty)
    #expect(texts(session.provisionalLines) == ["par"])
    let provisionalID = session.provisionalLines[0].id

    gates[0].open()
    await gates[1].waitForArrivals(1)
    #expect(texts(session.lines) == ["partial"])
    #expect(session.lines[0].id == provisionalID)
    #expect(texts(session.provisionalLines) == ["rest"])
    #expect(session.provisionalLines[0].id != provisionalID)

    gates[1].open()
    task.cancel()
    await task.value
  }

  @Test func aGrowingProvisionalLineKeepsItsID() async {
    let gates = [ArrivalGate(), ArrivalGate()]
    let harness = Harness {
      $0.logChunks[web] = [stdout("a"), stdout("b")]
      $0.logStreamStaysOpen = true
      $0.afterLogChunk = { index in await gates[index].pass() }
    }
    let task = harness.start()
    await gates[0].waitForArrivals(1)
    let first = harness.session.provisionalLines
    gates[0].open()
    await gates[1].waitForArrivals(1)
    #expect(texts(harness.session.provisionalLines) == ["ab"])
    #expect(harness.session.provisionalLines[0].id == first[0].id)
    gates[1].open()
    task.cancel()
    await task.value
  }

  @Test func stdoutAndStderrHaveOneProvisionalLineEach() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("out"), stderr("err"), stdout("put")]
      $0.logStreamStaysOpen = true
    }
    let task = harness.start()
    await harness.wait {
      harness.session.provisionalLines.count == 2
        && harness.session.provisionalLines[0].text == "output"
    }
    let provisional = harness.session.provisionalLines
    #expect(Set(provisional.map(\.stream)) == [.stdout, .stderr])
    #expect(texts(provisional) == ["output", "err"])
    #expect(Set(provisional.map(\.id)).count == 2)
    #expect(harness.session.lines.isEmpty)
    task.cancel()
    await task.value
  }

  @Test func provisionalLinesDoNotCountAgainstTheLineLimit() async {
    let harness = Harness(lineLimit: 3) {
      $0.logChunks[web] = [stdout("1\n2\n3\n"), stdout("out"), stderr("err")]
      $0.logStreamStaysOpen = true
    }
    let task = harness.start()
    await harness.wait { harness.session.provisionalLines.count == 2 }
    #expect(texts(harness.session.lines) == ["1", "2", "3"])
    task.cancel()
    await task.value
  }

  @Test func theOldestConfirmedLinesAreDroppedBeyondTheLimit() async {
    let harness = Harness(lineLimit: 3) {
      $0.logChunks[web] = [stdout("1\n2\n"), stdout("3\n4\n5\n")]
    }
    await harness.session.run()
    #expect(texts(harness.session.lines) == ["3", "4", "5"])
  }

  @Test func theDefaultLimitIs50000Lines() {
    #expect(LogSession.defaultLineLimit == 50_000)
  }

  @Test func linesWithinATenthOverTheLimitAreKeptUntilTheNextTrim() async {
    let body = String(repeating: "x\n", count: 55_000)
    let harness = Harness { $0.logChunks[web] = [stdout(body)] }
    await harness.session.run()
    #expect(harness.session.lines.count == 55_000)
  }

  @Test func passingATenthOverTheLimitTrimsBackToTheLimit() async {
    let body = String(repeating: "x\n", count: 55_001)
    let harness = Harness { $0.logChunks[web] = [stdout(body)] }
    await harness.session.run()
    #expect(harness.session.lines.count == 50_000)
  }

  @Test func endOfStreamConfirmsPendingTextKeepingTheProvisionalID() async {
    let gate = ArrivalGate()
    let harness = Harness {
      $0.logChunks[web] = [stdout("unfinished")]
      $0.afterLogChunk = { _ in await gate.pass() }
    }
    let task = harness.start()
    await gate.waitForArrivals(1)
    let provisionalID = harness.session.provisionalLines[0].id
    gate.open()
    await task.value
    #expect(harness.session.provisionalLines.isEmpty)
    #expect(
      harness.session.lines == [LogLine(id: provisionalID, stream: .stdout, text: "unfinished")])
    #expect(harness.session.state == .ended(.streamClosed))
  }

  @Test func endOfAHistoryFetchConfirmsPendingTextWithoutEverShowingItProvisionally() async {
    let gate = ArrivalGate()
    let harness = Harness(running: false) {
      $0.logChunks[web] = [stdout("done\nunfinished")]
      $0.afterLogChunk = { _ in await gate.pass() }
    }
    let task = harness.start()
    await gate.waitForArrivals(1)
    #expect(harness.session.provisionalLines.isEmpty)
    #expect(texts(harness.session.lines) == ["done"])
    gate.open()
    await task.value
    #expect(texts(harness.session.lines) == ["done", "unfinished"])
    #expect(harness.session.state == .history)
  }

  @Test func aMultibyteCharacterSplitAcrossChunksNeverShowsAReplacementCharacter() async {
    let whole = stdout("a円\n")
    let gate = ArrivalGate()
    let harness = Harness {
      // The first chunk ends after the first byte of the three-byte character.
      $0.logChunks[web] = [Array(whole[..<(whole.count - 3)]), Array(whole[(whole.count - 3)...])]
      $0.logStreamStaysOpen = true
      $0.afterLogChunk = { index in if index == 0 { await gate.pass() } }
    }
    let task = harness.start()
    await gate.waitForArrivals(1)
    #expect(texts(harness.session.provisionalLines) == ["a"])
    gate.open()
    await harness.wait { !harness.session.lines.isEmpty }
    #expect(texts(harness.session.lines) == ["a円"])
    task.cancel()
    await task.value
  }

  // MARK: Streams

  @Test func nonTTYFramesAreSplitIntoStdoutAndStderrLinesAcrossChunkBoundaries() async {
    let whole = stdout("out1\n") + stderr("err1\n") + stdout("out2\n")
    let harness = Harness {
      $0.logChunks[web] = [Array(whole[..<5]), Array(whole[5..<14]), Array(whole[14...])]
    }
    await harness.session.run()
    #expect(harness.session.mode == .separated)
    #expect(harness.session.lines.map(\.stream) == [.stdout, .stderr, .stdout])
    #expect(texts(harness.session.lines) == ["out1", "err1", "out2"])
    #expect(harness.session.state == .ended(.streamClosed))
  }

  @Test func aTTYContainerIsOneMergedStreamWithoutFrameDecoding() async {
    let harness = Harness(tty: true) {
      $0.logChunks[web] = [bytes("plain\r\nsecond\n"), bytes("tail")]
    }
    await harness.session.run()
    #expect(harness.session.mode == .singleStream)
    #expect(harness.session.lines.map(\.stream) == [.combined, .combined, .combined])
    #expect(texts(harness.session.lines) == ["plain", "second", "tail"])
  }

  @Test func aTTYContainerHasAtMostOneProvisionalLine() async {
    let harness = Harness(tty: true) {
      $0.logChunks[web] = [bytes("50%"), bytes(" 60%")]
      $0.logStreamStaysOpen = true
    }
    let task = harness.start()
    await harness.wait { harness.session.provisionalLines.first?.text == "50% 60%" }
    #expect(harness.session.provisionalLines.count == 1)
    #expect(harness.session.provisionalLines[0].stream == .combined)
    task.cancel()
    await task.value
  }

  @Test func aMalformedHeaderEndsAsFailedStopsTheStreamAndKeepsEarlierLines() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("good\n") + [9, 0, 0, 0, 0, 0, 0, 1, 0x41]]
      $0.logStreamStaysOpen = true
    }
    await harness.session.run()
    guard case .ended(.failed(let message)) = harness.session.state else {
      Issue.record("expected failed, got \(harness.session.state)")
      return
    }
    #expect(!message.isEmpty)
    #expect(texts(harness.session.lines) == ["good"])
  }

  @Test func lineIDsAreUniqueAndIncreasing() async {
    let harness = Harness {
      $0.logChunks[web] = [stdout("a\n") + stderr("b\n"), stdout("c"), stdout("d\ne")]
    }
    await harness.session.run()
    let ids = harness.session.lines.map(\.id)
    #expect(texts(harness.session.lines) == ["a", "b", "cd", "e"])
    #expect(Set(ids).count == 4)
    #expect(ids == ids.sorted())
  }

  @Test func runningTwiceDoesNotFetchTheLogsAgain() async {
    let harness = Harness { $0.logChunks[web] = [stdout("a\n")] }
    await harness.session.run()
    await harness.session.run()
    #expect(harness.logCalls.count == 1)
    #expect(texts(harness.session.lines) == ["a"])
  }
}
