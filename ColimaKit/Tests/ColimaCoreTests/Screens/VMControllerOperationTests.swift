import Foundation
import Observation
import Testing

@testable import ColimaCore

private let running = VMObservation.present(instance(running: true))
private let stopped = VMObservation.present(instance(running: false))

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let date = ManualDate()
  let controller: VMController

  /// Reads the first observation, so every list call made by an operation consumes the later entries.
  init(
    toolchain: ToolchainStatus = ToolchainStatus(
      colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:]),
    observations: [Result<VMObservation, ColimaCLIError>]
  ) async {
    let date = date
    controller = VMController(cli: cli, files: files, now: { date.now })
    cli.configure {
      $0.toolchain = toolchain
      $0.listDefault = observations
    }
    await controller.redetectToolchain()
  }

  var runs: [VMCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func finish() async {
    await controller.operationTask?.value
  }

  func wait(until predicate: @escaping @MainActor () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMControllerOperationTests {

  // MARK: start

  @Test func startTakesTheSlotBeforeAnyAwaitAndRunsColimaStart() async {
    let harness = await Harness(observations: [.success(stopped), .success(running)])

    harness.controller.start()

    #expect(harness.controller.activeOperation?.kind == .start)
    #expect(harness.controller.activeOperation?.stage == .starting)
    #expect(harness.controller.displayState == .starting)

    let process = await harness.cli.process(at: 0)
    process.send("starting colima")
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.start])
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.observation == running)
  }

  @Test func aSecondStartWhileStartingIsIgnored() async {
    let harness = await Harness(observations: [.success(stopped), .success(running)])

    harness.controller.start()
    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.start])
  }

  @Test func startIsIgnoredUnlessTheVMIsPresentAndStopped() async {
    for observation: VMObservation in [running, .unknown(reason: "x")] {
      let harness = await Harness(observations: [.success(observation)])
      harness.controller.start()
      #expect(harness.controller.activeOperation == nil)
      #expect(harness.runs.isEmpty)
    }
  }

  @Test func startIsIgnoredWhileColimaIsMissing() async {
    let harness = await Harness(
      toolchain: ToolchainStatus(
        colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:]),
      observations: [.success(stopped)]
    )
    harness.controller.start()
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.runs.isEmpty)
  }

  @Test func theRecordKeepsTheLatest2000OutputLines() async throws {
    let harness = await Harness(observations: [.success(stopped), .success(running)])
    harness.controller.start()
    let record = try #require(harness.controller.latestRecord)
    let process = await harness.cli.process(at: 0)

    for index in 0..<2_100 { process.send("line \(index)") }
    await harness.wait { record.lines.last?.text == "line 2099" }

    #expect(record.lines.count == 2_000)
    #expect(record.lines.first == .init(number: 100, text: "line 100"))
    #expect(record.outcome == nil)
    #expect(harness.controller.activeOperation?.lastOutputAt != nil)

    process.exit(code: 0)
    await harness.finish()
    #expect(record.outcome == .succeeded)
    #expect(record.endedAt != nil)
    #expect(harness.controller.latestRecord === record)
  }

  @Test func eachAcceptedOperationGetsANewRecordAndAFailureEndsIt() async throws {
    let harness = await Harness(observations: [.success(stopped), .success(stopped)])
    harness.cli.configure { $0.scriptedRuns = [[.output("boom"), .exited(code: 1)]] }
    #expect(harness.controller.latestRecord == nil)

    harness.controller.start()
    let record = try #require(harness.controller.latestRecord)
    #expect(record.kind == .start)
    await harness.finish()

    #expect(record.texts == ["boom"])
    #expect(record.outcome == harness.controller.lastFailure.map(VMOperationOutcome.failed))
    #expect(harness.controller.activeOperation == nil)
  }

  @Test func aFailedStartKeepsStageCauseAndOutputTailAndRereadsTheState() async {
    let harness = await Harness(observations: [.success(stopped), .success(stopped)])
    let lines = (0..<60).map { "line \($0)" }
    harness.cli.configure { $0.scriptedRuns = [lines.map { .output($0) } + [.exited(code: 1)]] }
    let readsBefore = harness.cli.calls.filter { $0 == .listDefault }.count

    harness.controller.start()
    await harness.finish()

    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .start, stage: .starting, cause: .exited(code: 1), outputLines: lines))
    #expect(harness.controller.lastFailure?.outputTail.count == 50)
    #expect(harness.controller.lastFailure?.outputTail.first == "line 10")
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.cli.calls.last == .listDefault)
    #expect(harness.cli.calls.filter { $0 == .listDefault }.count == readsBefore + 1)
  }

  @Test func aRepeatedIdenticalFailureIsANewFailureByIdentity() async {
    let harness = await Harness(observations: [
      .success(stopped), .success(stopped), .success(stopped),
    ])
    harness.cli.configure {
      $0.scriptedRuns = [
        [.output("boom"), .exited(code: 1)], [.output("boom"), .exited(code: 1)],
      ]
    }

    harness.controller.start()
    await harness.finish()
    let first = harness.controller.lastFailure

    harness.controller.start()
    await harness.finish()
    let second = harness.controller.lastFailure

    #expect(first != nil && first == second)
    #expect(first?.id != second?.id)
  }

  @Test func aLaunchFailureIsRecordedAsSuch() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.cli.configure { $0.scriptedRuns = [[.launchFailed(reason: "no such file")]] }

    harness.controller.start()
    await harness.finish()

    #expect(harness.controller.lastFailure?.cause == .launchFailed(reason: "no such file"))
  }

  @Test func theNextOperationClearsTheLastFailure() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)]] }
    harness.controller.start()
    await harness.finish()
    #expect(harness.controller.lastFailure != nil)

    harness.controller.start()
    #expect(harness.controller.lastFailure == nil)
    let process = await harness.cli.process(at: 1)
    process.exit(code: 0)
    await harness.finish()
  }

  @Test func readsThatBeganBeforeTheOperationDoNotLandDuringIt() async {
    let harness = await Harness(observations: [
      .success(stopped), .success(running), .success(stopped),
    ])
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListDefaultReturns = gate.pass }
    let staleRead = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)

    harness.controller.start()
    gate.open()
    await staleRead.value

    #expect(harness.controller.observation == stopped)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()
  }

  // MARK: stop

  @Test func stopIsNotRunUntilTheConfirmationIsApproved() async {
    let harness = await Harness(observations: [.success(running), .success(stopped)])

    harness.controller.requestStop(from: .window)

    let request = harness.controller.pendingConfirmation
    #expect(request?.intent == .stopVM)
    #expect(request?.origin == .window)
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.runs.isEmpty)

    let outcome = harness.controller.confirm(id: request!.id)
    #expect(outcome == .started)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.activeOperation?.kind == .stop)
    #expect(harness.controller.displayState == .stopping)

    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.stop])
    #expect(harness.controller.observation == stopped)
    #expect(harness.controller.lastFailure == nil)
  }

  @Test func aMenuBarStopRequestIsShownOnTheMenuBarOnly() async {
    let harness = await Harness(observations: [.success(running)])

    harness.controller.requestStop(from: .menuBar)

    let request = harness.controller.pendingConfirmation
    #expect(request?.origin == .menuBar)
    #expect(request?.isShown(on: .menuBar) == true)
    #expect(request?.isShown(on: .window) == false)
  }

  @Test func aNewRequestReplacesAnOlderOne() async {
    let harness = await Harness(observations: [.success(running)])

    harness.controller.requestStop(from: .menuBar)
    let first = harness.controller.pendingConfirmation
    harness.controller.requestRestart()
    let second = harness.controller.pendingConfirmation

    #expect(second?.id != first?.id)
    #expect(second?.intent == .restartVM)
    #expect(second?.origin == .window)
    #expect(harness.controller.confirm(id: first!.id) == .notPending)
    #expect(harness.controller.pendingConfirmation == second)
  }

  @Test func approvingTheSameConfirmationTwiceRunsOnce() async {
    let harness = await Harness(observations: [.success(running), .success(stopped)])
    harness.controller.requestStop(from: .window)
    let id = harness.controller.pendingConfirmation!.id

    #expect(harness.controller.confirm(id: id) == .started)
    #expect(harness.controller.confirm(id: id) == .notPending)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.stop])
  }

  @Test func anUnknownIdConsumesNothing() async {
    let harness = await Harness(observations: [.success(running)])
    harness.controller.requestStop(from: .window)
    let pending = harness.controller.pendingConfirmation

    #expect(harness.controller.confirm(id: UUID()) == .notPending)
    #expect(harness.controller.pendingConfirmation == pending)
    #expect(harness.runs.isEmpty)
  }

  @Test func dismissingDropsTheRequest() async {
    let harness = await Harness(observations: [.success(running)])
    harness.controller.requestStop(from: .menuBar)
    let id = harness.controller.pendingConfirmation!.id

    harness.controller.dismissConfirmation()

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.confirm(id: id) == .notPending)
    #expect(harness.runs.isEmpty)
  }

  @Test func approvingWhileAnotherOperationRunsIsRejectedAndTheRequestIsDiscarded() async {
    let harness = await Harness(observations: [.success(running), .success(stopped)])
    harness.controller.requestStop(from: .window)
    let id = harness.controller.pendingConfirmation!.id

    await harness.controller.refreshNow()
    harness.controller.start()
    let startProcess = await harness.cli.process(at: 0)

    let outcome = harness.controller.confirm(id: id)

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.activeOperation?.kind == .start)

    startProcess.exit(code: 0)
    await harness.finish()
    #expect(harness.runs == [.start])
  }

  @Test func stopAndRestartRequestsAreNotCreatedWhileBusyOrWhenNotRunning() async {
    let stoppedHarness = await Harness(observations: [.success(stopped)])
    stoppedHarness.controller.requestStop(from: .window)
    stoppedHarness.controller.requestRestart()
    #expect(stoppedHarness.controller.pendingConfirmation == nil)

    let busyHarness = await Harness(observations: [.success(stopped)])
    busyHarness.controller.start()
    busyHarness.controller.requestStop(from: .window)
    #expect(busyHarness.controller.pendingConfirmation == nil)
    let process = await busyHarness.cli.process(at: 0)
    process.exit(code: 0)
    await busyHarness.finish()
  }

  // MARK: restart

  @Test func restartStopsConfirmsTheStopAndThenStarts() async {
    let harness = await Harness(observations: [
      .success(running), .success(stopped), .success(running),
    ])
    harness.controller.requestRestart()
    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    #expect(harness.controller.activeOperation?.kind == .restart)
    #expect(harness.controller.activeOperation?.stage == .stopping)

    let stop = await harness.cli.process(at: 0)
    stop.send("stopping")
    stop.exit(code: 0)
    let start = await harness.cli.process(at: 1)
    #expect(harness.controller.activeOperation?.stage == .starting)
    #expect(harness.controller.displayState == .starting)
    start.send("starting")
    start.exit(code: 0)
    await harness.finish()

    let afterSetup = harness.cli.calls.drop { $0 != .run(.stop) }
    #expect(Array(afterSetup) == [.run(.stop), .listDefault, .run(.start), .listDefault])
    #expect(harness.controller.observation == running)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.activeOperation == nil)
  }

  @Test func restartDoesNotStartWhenTheStopFails() async {
    let harness = await Harness(observations: [.success(running), .success(running)])
    harness.cli.configure { $0.scriptedRuns = [[.output("boom"), .exited(code: 1)]] }
    harness.controller.requestRestart()
    _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
    await harness.finish()

    #expect(harness.runs == [.stop])
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .restart, stage: .stopping, cause: .exited(code: 1), outputLines: ["boom"]))
  }

  @Test func restartDoesNotStartWhenTheStopCannotBeConfirmed() async {
    for observation: Result<VMObservation, ColimaCLIError> in [
      .success(running), .success(.absent), .failure(.timedOut),
    ] {
      let harness = await Harness(observations: [.success(running), observation])
      harness.cli.configure { $0.scriptedRuns = [[.exited(code: 0)]] }
      harness.controller.requestRestart()
      _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
      await harness.finish()

      #expect(harness.runs == [.stop])
      #expect(harness.controller.lastFailure?.kind == .restart)
      #expect(harness.controller.lastFailure?.stage == .stopping)
      #expect(harness.controller.lastFailure?.cause == .stopNotConfirmed)
      #expect(harness.controller.activeOperation == nil)
    }
  }

  @Test func restartRecordsAStartFailureUnderTheStartingStage() async {
    let harness = await Harness(observations: [
      .success(running), .success(stopped), .success(stopped),
    ])
    harness.cli.configure {
      $0.scriptedRuns = [[.exited(code: 0)], [.output("no disk"), .exited(code: 2)]]
    }
    harness.controller.requestRestart()
    _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
    await harness.finish()

    #expect(harness.runs == [.stop, .start])
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .restart, stage: .starting, cause: .exited(code: 2), outputLines: ["no disk"]))
  }

  // MARK: abort

  @Test func abortIsRefusedBeforeThreeMinutes() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.controller.start()
    let process = await harness.cli.process(at: 0)

    harness.date.advance(by: 179)
    #expect(harness.controller.activeOperation?.isAbortAvailable(at: harness.date.now) == false)
    harness.controller.abortOperation()

    #expect(process.terminateCount == 0)
    process.exit(code: 0)
    await harness.finish()
    #expect(harness.controller.lastFailure == nil)
  }

  @Test func abortingTheStopStageOfARestartDoesNotStartAndRecordsAnAbort() async {
    let harness = await Harness(observations: [.success(running), .success(running)])
    harness.controller.requestRestart()
    _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
    let process = await harness.cli.process(at: 0)
    process.send("waiting for the guest")
    harness.date.advance(by: 180)
    let readsBefore = harness.cli.calls.filter { $0 == .listDefault }.count

    #expect(harness.controller.activeOperation?.isAbortAvailable(at: harness.date.now) == true)
    harness.controller.abortOperation()
    harness.controller.abortOperation()
    await harness.finish()

    #expect(process.terminateCount == 1)
    #expect(harness.runs == [.stop])
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .restart, stage: .stopping, cause: .aborted, outputLines: ["waiting for the guest"])
    )
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.cli.calls.filter { $0 == .listDefault }.count == readsBefore + 1)
    #expect(harness.cli.calls.last == .listDefault)
  }

  @Test func anAbortIsRecordedEvenWhenTheExitCodeIsZero() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.cli.configure { $0.exitCodeOnTerminate = 0 }
    harness.controller.start()
    _ = await harness.cli.process(at: 0)
    harness.date.advance(by: 200)

    harness.controller.abortOperation()
    await harness.finish()

    #expect(harness.controller.lastFailure?.cause == .aborted)
    #expect(harness.controller.lastFailure?.stage == .starting)
  }

  @Test func anAbortTheRunnerDidNotAcceptIsNotRecordedAsAnAbort() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.cli.configure { $0.acceptsTerminate = false }
    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    harness.date.advance(by: 200)

    harness.controller.abortOperation()
    process.failLaunch(reason: "helper stopped")
    await harness.finish()

    #expect(process.terminateCount == 1)
    #expect(harness.controller.lastFailure?.cause == .launchFailed(reason: "helper stopped"))
  }

  @Test func aRefusedAbortStillKeepsARestartFromStarting() async {
    let harness = await Harness(observations: [.success(running), .success(stopped)])
    harness.cli.configure { $0.acceptsTerminate = false }
    harness.controller.requestRestart()
    _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
    let process = await harness.cli.process(at: 0)
    harness.date.advance(by: 180)

    harness.controller.abortOperation()
    while process.terminateCount < 1 { await Task.yield() }
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.stop])
    #expect(harness.controller.lastFailure?.stage == .stopping)
    #expect(harness.controller.lastFailure?.cause == .aborted)
  }

  @Test func anAbortTheRunnerDidNotAcceptCanBeRetried() async {
    let harness = await Harness(observations: [.success(stopped)])
    harness.cli.configure { $0.acceptsTerminate = false }
    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    harness.date.advance(by: 200)

    harness.controller.abortOperation()
    while harness.controller.abortRequest != nil { await Task.yield() }
    harness.controller.abortOperation()
    while process.terminateCount < 2 { await Task.yield() }
    process.exit(code: 0)
    await harness.finish()

    #expect(process.terminateCount == 2)
  }

  @Test func theDeletingStageCannotBeAborted() async {
    let harness = await Harness(observations: [.success(stopped)])
    let run = await harness.cli.run(.delete)
    let process = await harness.cli.process(at: 0)
    harness.controller.currentRun = run
    harness.controller.activeOperation = VMOperationProgress(
      kind: .recreate, stage: .deleting, startedAt: harness.date.now,
      stageStartedAt: harness.date.now)
    harness.date.advance(by: 3_600)

    harness.controller.abortOperation()

    #expect(process.terminateCount == 0)
    #expect(harness.controller.activeOperation?.stage == .deleting)
  }
}
