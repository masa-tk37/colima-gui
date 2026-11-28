import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineOperationPresentationTests {
  private typealias Data = PreviewMachineData

  private func presentation(
    _ scenario: MachineControllerPreviews.Scenario, _ name: MachineName
  ) async -> MachineOperationPresentation {
    let controller = await MachineControllerPreviews.make(scenario).controller
    return MachineOperationPresentation(
      progress: controller.operations[name.key], record: controller.records[name.key],
      failure: controller.failures[name.key], canCancel: controller.canCancelCreate(name))
  }

  @Test func nothingRecordedShowsAnEmptyPanel() async {
    let shown = await presentation(.mixed, Data.running)
    #expect(shown.status == .idle)
    #expect(shown.kind == nil)
    #expect(!shown.showsOutput && !shown.showsFailure && !shown.showsEarlierSessionNotice)
    #expect(shown.cancel == .hidden)
  }

  @Test func aRunningStartShowsItsOutputWithoutCancel() async {
    let shown = await presentation(.starting, Data.stopped)
    #expect(shown.status == .running)
    #expect(shown.kind == .start)
    #expect(shown.showsOutput)
    #expect(shown.cancel == .hidden)
    #expect(shown.startedAt != nil)
  }

  @Test func aRunningCreateOffersCancel() async {
    let shown = await presentation(.creating, Data.creating)
    #expect(shown.status == .running)
    #expect(shown.kind == .create)
    #expect(shown.cancel == .enabled)
  }

  @Test func afterTheRequestCancelIsDisabledAndSaysSo() async {
    let shown = await presentation(.createCancelRequested, Data.creating)
    #expect(shown.status == .running)
    #expect(shown.cancel == .requested)
  }

  @Test func aCreateThatCannotBeStoppedYetDisablesCancel() {
    let progress = MachineOperationProgress(kind: .create, origin: .thisSession(startedAt: Date()))
    let shown = MachineOperationPresentation(progress: progress, record: nil, failure: nil, canCancel: false)
    #expect(shown.cancel == .disabled)
  }

  @Test func aFailureShowsItsCauseAndKeepsTheOutput() async throws {
    let shown = await presentation(.startFailed, Data.stopped)
    #expect(shown.status == .failed)
    #expect(shown.showsFailure)
    #expect(shown.showsOutput)
    #expect(shown.failure?.outputTail == Data.startFailureOutput)
    #expect(shown.cancel == .hidden)
    #expect(shown.endedAt != nil)
  }

  @Test func aDismissedFailureLeavesTheOutputAndTheFailedStatus() async {
    let controller = await MachineControllerPreviews.make(.startFailed).controller
    controller.dismissFailure(for: Data.stopped)
    let shown = MachineOperationPresentation(
      progress: controller.operations[Data.stopped.key], record: controller.records[Data.stopped.key],
      failure: controller.failures[Data.stopped.key], canCancel: false)
    #expect(shown.status == .failed)
    #expect(!shown.showsFailure)
    #expect(shown.showsOutput)
  }

  @Test func aFinishedOperationsElapsedTimeStopsAtItsEnd() async throws {
    let shown = await presentation(.startFailed, Data.stopped)
    let start = try #require(shown.startedAt)
    let end = try #require(shown.endedAt)
    #expect(shown.elapsedSeconds(at: end.addingTimeInterval(600)) == max(0, Int(end.timeIntervalSince(start))))
  }

  @Test func anEarlierSessionOperationHasNoOutputAndExplainsWhy() async {
    let shown = await presentation(.earlierSession, Data.stopped)
    #expect(shown.status == .earlierSession)
    #expect(shown.kind == .start)
    #expect(shown.showsEarlierSessionNotice)
    #expect(!shown.showsOutput)
    #expect(shown.startedAt == nil)
    #expect(shown.elapsedSeconds(at: Date()) == nil)
    #expect(shown.cancel == .hidden)
  }

  @Test func anEarlierSessionCreateCanBeCancelled() async {
    let shown = await presentation(.earlierSession, Data.creating)
    #expect(shown.kind == .create)
    #expect(shown.cancel == .enabled)
    #expect(!shown.showsOutput)
  }

  @Test func aCancelledCreateEndsWithCancelledStatus() async {
    let shown = await presentation(.createCancelled, Data.creating)
    #expect(shown.status == .cancelled)
    #expect(shown.cancel == .hidden)
    #expect(shown.showsOutput)
  }

  @Test func aRunningOperationCountsFromItsStartAndAFinishedOneStopsAtItsEnd() {
    let start = Date(timeIntervalSince1970: 1_000)
    let running = MachineOperationPresentation(
      progress: MachineOperationProgress(kind: .start, origin: .thisSession(startedAt: start)),
      record: nil, failure: nil, canCancel: false)
    #expect(running.elapsedSeconds(at: start.addingTimeInterval(75)) == 75)
    #expect(running.elapsedSeconds(at: start.addingTimeInterval(-5)) == 0)
  }

  @Test(arguments: [(0, "0:00"), (75, "1:15"), (3_599, "59:59"), (3_600, "1:00:00"), (3_725, "1:02:05")])
  func theClockShowsMinutesAndAddsHoursFromOneHour(seconds: Int, text: String) {
    #expect(OperationClock.text(seconds: seconds) == text)
  }
}
