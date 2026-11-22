import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LogAndStatsPreviewScenarioTests {
  @Test func aFollowedLogMixesBothStreamsAndStaysOpen() async {
    let scene = await LogSessionPreviews.make(.following)
    defer { scene.runTask.cancel() }
    #expect(scene.session.state == .following)
    #expect(scene.session.mode == .separated)
    #expect(scene.session.lines.count == 24)
    #expect(scene.session.lines.contains { $0.stream == .stderr })
    #expect(scene.session.lines.contains { $0.stream == .stdout })
    #expect(scene.session.provisionalLines.isEmpty)
  }

  @Test func anUnterminatedLastLineIsProvisional() async {
    let scene = await LogSessionPreviews.make(.followingWithUnterminatedLine)
    defer { scene.runTask.cancel() }
    #expect(scene.session.lines.count == 12)
    #expect(scene.session.provisionalLines.count == 1)
    #expect(scene.session.provisionalLines[0].text.hasSuffix("20"))
  }

  @Test func aLongLogHasEnoughLinesToScrollAway() async {
    let scene = await LogSessionPreviews.make(.followingLong)
    defer { scene.runTask.cancel() }
    #expect(scene.session.lines.count == 400)
  }

  @Test func aTTYLogIsASingleStream() async {
    let scene = await LogSessionPreviews.make(.tty)
    defer { scene.runTask.cancel() }
    #expect(scene.session.mode == .singleStream)
    #expect(scene.session.lines.allSatisfy { $0.stream == .combined })
  }

  @Test func aStoppedContainerShowsHistoryWithoutEnding() async {
    let scene = await LogSessionPreviews.make(.history)
    #expect(scene.session.state == .history)
    #expect(scene.session.lines.count == 16)
  }

  @Test func eachEndingHasItsReason() async {
    #expect(
      await LogSessionPreviews.make(.endedStreamClosed).session.state == .ended(.streamClosed))
    #expect(
      await LogSessionPreviews.make(.endedContainerGone).session.state == .ended(.containerGone))
    #expect(
      await LogSessionPreviews.make(.endedConnectionLost).session.state
        == .ended(.failed(DockerError.connectionLost(detail: "").displayMessage)))

    let malformed = await LogSessionPreviews.make(.endedMalformedFrame)
    #expect(malformed.session.state == .ended(.failed("Could not interpret the log format.")))
    #expect(malformed.session.lines.count == 6)
  }

  @Test func statsStatesAndHistories() async {
    let running = await StatsSessionPreviews.make(.running)
    #expect(running.session.state == .running)
    #expect(running.session.cpu.points.count == 40)
    #expect(running.session.cpu.points[0].value == nil)
    #expect(running.session.memory.points.allSatisfy { $0.value != nil })

    let gaps = await StatsSessionPreviews.make(.runningWithGaps)
    #expect(gaps.session.cpu.points.filter { $0.value == nil }.count == 4)

    let notRunning = await StatsSessionPreviews.make(.notRunning)
    #expect(notRunning.session.state == .notRunning)
    #expect(notRunning.session.state.message != nil)
    #expect(notRunning.session.cpu.points.isEmpty)

    let stopped = await StatsSessionPreviews.make(.containerStopped)
    #expect(stopped.session.state == .containerStopped)
    #expect(stopped.session.cpu.points.count == 40)
  }

  @Test func aSeededStatsSessionIsNotRewrittenByTheScreensTask() async {
    let stopped = await StatsSessionPreviews.make(.containerStopped)
    await stopped.session.run()
    #expect(stopped.session.state == .containerStopped)
  }
}
