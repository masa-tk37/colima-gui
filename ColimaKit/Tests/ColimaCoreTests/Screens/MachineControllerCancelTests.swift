import Foundation
import Observation
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(_ name: String, _ runState: MachineRunState = .stopped) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30,
    mounts: [], templateID: "ubuntu")
}

private func listing(_ instances: MachineInstance...) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: [])
}

private let host = HostResources(cpus: 8, memoryGiB: 32, diskGiB: 500)
private let ubuntu = MachineTemplate(id: "ubuntu")!
private let dev = machineName("dev")

private func form(_ name: String = "dev") -> MachineFormInput {
  MachineFormInput(name: name, templateID: "ubuntu", cpus: "2", memoryGiB: "4", diskGiB: "100")
}

private func operation(_ name: String, _ kind: MachineOperationKind, runID: UUID) -> ActiveMachineOperation {
  ActiveMachineOperation(runID: runID, name: machineName(name), kind: kind)
}

private func sleeper(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let rounds = RoundCounter()
  let controller: MachineController

  /// Listings are scripted in the order described on `MachineControllerCreateTests`' `Harness`.
  init(_ listings: [LimaListing] = [listing(), listing()]) async {
    controller = MachineController(cli: cli, host: host, homeDirectory: "/Users/me")
    cli.configure { $0.listInstances = listings.map { .success($0) } }
    await controller.refreshNow()
  }

  var key: MachineKey { dev.key }
  var progress: MachineOperationProgress? { controller.operations[key] }

  func task() -> Task<Void, Never>? { controller.operationTasks[key] }

  func wait(until predicate: @escaping @MainActor () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
  }

  func startCreate() async -> FakeMachineProcess {
    let outcome = await controller.create(form(), templates: [ubuntu])
    #expect(outcome == .started)
    let process = await cli.process(at: 0)
    await wait { controller.activeRuns[key] != nil }
    return process
  }

  func startMonitor(clock: ManualClock) -> Task<Void, Never> {
    let controller = controller
    let rounds = rounds
    return Task { await controller.monitor(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  @discardableResult
  func reply() async -> Bool? { await controller.cancelReplies[key]?.value }

  var terminateCalls: Int { cli.calls.filter { if case .terminateEarlierRun = $0 { true } else { false } }.count }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerCancelTests {

  // MARK: Whether a create can be cancelled

  @Test func cancellingIsRefusedUntilTheRunHandleArrivesAndForMachinesThatAreNotCreating() async {
    let harness = await Harness([listing(instance("old")), listing(instance("old"))])
    let old = machineName("old")
    #expect(!harness.controller.canCancelCreate(old))
    #expect(!harness.controller.canCancelCreate(dev))

    #expect(await harness.controller.create(form(), templates: [ubuntu]) == .started)
    #expect(!harness.controller.canCancelCreate(dev))
    harness.controller.cancelCreate(dev)
    #expect(harness.progress?.cancelRequested == false)

    let process = await harness.cli.process(at: 0)
    await harness.wait { harness.controller.activeRuns[harness.key] != nil }
    #expect(harness.controller.canCancelCreate(dev))
    #expect(!harness.controller.canCancelCreate(old))
    #expect(!harness.controller.canDelete(dev))
    #expect(!harness.controller.canStart(dev))
    #expect(!harness.controller.canEdit(dev))
    #expect(
      harness.controller.saveEdit(dev, MachineEditInput(cpus: "2", memoryGiB: "4", diskGiB: "100", mounts: []))
        == .busy)
    #expect(process.terminateCount == 0)

    process.exit(code: 0)
    await harness.task()?.value
    #expect(!harness.controller.canCancelCreate(dev))
  }

  @Test func theRequestIsRecordedAtOnceAndASecondRequestIsNotSent() async {
    let harness = await Harness([listing(), listing()])
    harness.cli.configure { $0.terminateEndsProcess = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)

    #expect(harness.progress?.cancelRequested == true)
    #expect(!harness.controller.canCancelCreate(dev))
    #expect(harness.controller.rows().map(\.cancelRequested) == [true])
    harness.controller.cancelCreate(dev)
    await harness.reply()
    harness.controller.cancelCreate(dev)
    #expect(process.terminateCount == 1)

    process.exit(code: 143)
    await harness.task()?.value
  }

  @Test func aRefusedRequestWhileTheCreateKeepsRunningMakesCancellingAvailableAgain() async {
    let harness = await Harness([listing(), listing()])
    harness.cli.configure { $0.acceptsTerminate = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    #expect(harness.progress?.cancelRequested == true)
    #expect(await harness.reply() == false)

    #expect(harness.progress?.cancelRequested == false)
    #expect(harness.controller.canCancelCreate(dev))
    #expect(harness.controller.rows().map(\.cancelRequested) == [false])
    #expect(harness.controller.rows().map(\.display) == [.creating])

    harness.controller.cancelCreate(dev)
    await harness.reply()
    #expect(process.terminateCount == 2)

    process.exit(code: 1)
    await harness.task()?.value
  }

  // MARK: How the end of a cancelled create is classified

  @Test func anAcceptedCancelWithAFailedExitAndNoRowIsACancellationNotAFailure() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.exitCodeOnTerminate = 143 }
    let process = await harness.startCreate()
    process.send("downloading")

    harness.controller.cancelCreate(dev)
    await harness.task()?.value

    #expect(harness.controller.notice == .createCancelled(dev))
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.records[harness.key]?.outcome == .cancelled)
    #expect(harness.controller.records[harness.key]?.texts == ["downloading"])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().isEmpty)
    #expect(process.terminateCount == 1)
  }

  @Test func anExitEventThatArrivesBeforeTheReplyStillWaitsForTheReply() async {
    let harness = await Harness([listing(), listing(), listing()])
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeTerminateReturns = { await gate.pass() } }
    _ = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    await gate.waitForArrivals(1)
    await harness.wait { harness.controller.activeRuns[harness.key] == nil }

    #expect(harness.progress != nil)
    #expect(harness.controller.notice == nil)
    #expect(harness.controller.failures.isEmpty)
    #expect(!harness.controller.canCancelCreate(dev))

    gate.open()
    await harness.task()?.value

    #expect(harness.controller.notice == .createCancelled(dev))
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.records[harness.key]?.outcome == .cancelled)
  }

  @Test func aReplyThatArrivesBeforeTheExitEventIsKept() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.terminateEndsProcess = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == true)
    #expect(harness.progress?.cancelRequested == true)
    process.exit(code: 143)
    await harness.task()?.value

    #expect(harness.controller.notice == .createCancelled(dev))
    #expect(harness.controller.failures.isEmpty)
  }

  @Test func aCreateThatFailedByItselfWhileTheStopWasAcceptedStaysAFailure() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.terminateEndsProcess = false }
    let process = await harness.startCreate()
    process.send("FATA[0001] unsupported template")

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == true)
    process.exit(code: 1)
    await harness.task()?.value

    #expect(harness.controller.failures[harness.key]?.cause == .exited(code: 1))
    #expect(harness.controller.notice == nil)
  }

  @Test func aRowThatRemainsAfterTheCleanupMakesItAFailureWithTheOutputKept() async {
    let broken = instance("dev", .broken(errors: ["cleanup failed"]))
    let harness = await Harness([listing(), listing(), listing(broken)])
    let process = await harness.startCreate()
    process.send("FATA[0003] could not remove the instance")

    harness.controller.cancelCreate(dev)
    await harness.task()?.value

    let failure = harness.controller.failures[harness.key]
    #expect(failure?.kind == .create)
    #expect(failure?.cause == .exited(code: 143))
    #expect(failure?.outputTail == ["FATA[0003] could not remove the instance"])
    #expect(harness.controller.notice == nil)
    #expect(harness.controller.records[harness.key]?.outcome == failure.map(MachineOperationOutcome.failed))
    #expect(harness.controller.rows().map(\.display) == [.broken(errors: ["cleanup failed"])])
  }

  @Test func aRefusedRequestFollowedByAFailedExitIsAnOrdinaryFailure() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.acceptsTerminate = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == false)
    #expect(process.terminateCount == 1)
    process.exit(code: 1)
    await harness.task()?.value

    #expect(harness.controller.failures[harness.key]?.cause == .exited(code: 1))
    #expect(harness.controller.notice == nil)
    guard case .failed? = harness.controller.records[harness.key]?.outcome else {
      Issue.record("expected a failed record")
      return
    }
  }

  @Test func aCreateThatCompletesDespiteAnAcceptedCancelIsASuccess() async {
    let harness = await Harness([listing(), listing(), listing(instance("dev", .stopped))])
    harness.cli.configure { $0.terminateEndsProcess = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == true)
    #expect(process.terminateCount == 1)
    process.exit(code: 0)
    await harness.task()?.value

    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.notice == nil)
    #expect(harness.controller.records[harness.key]?.outcome == .succeeded)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
  }

  @Test func aLaunchFailureAfterAnAcceptedCancelIsAFailure() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.terminateEndsProcess = false }
    let process = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == true)
    process.failLaunch(reason: "agent unreachable")
    await harness.task()?.value

    #expect(harness.controller.failures[harness.key]?.cause == .launchFailed(reason: "agent unreachable"))
    #expect(harness.controller.notice == nil)
  }

  @Test func aFinalReadThatFailedCannotConfirmTheCleanupSoItIsAFailure() async {
    let harness = await Harness([listing(), listing()])
    harness.cli.configure {
      $0.listInstances = [
        .success(listing()), .success(listing()), .failure(.launchFailed(reason: "list failed")),
      ]
    }
    _ = await harness.startCreate()

    harness.controller.cancelCreate(dev)
    await harness.task()?.value

    #expect(harness.controller.failures[harness.key]?.cause == .exited(code: 143))
    #expect(harness.controller.notice == nil)
  }

  // MARK: Creates of an earlier session

  @Test func anEarlierSessionCreateIsCancelledByItsRunIDAndNotifiedOnceItLeavesTheAgentsList() async {
    let harness = await Harness([listing()])
    let runID = UUID()
    let running = [operation("dev", .create, runID: runID)]
    harness.cli.configure {
      $0.activeOperations = [running, running, []]
      $0.terminateEarlierRun = [true]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    #expect(harness.controller.canCancelCreate(dev))

    harness.controller.cancelCreate(dev)

    #expect(harness.progress?.cancelRequested == true)
    #expect(!harness.controller.canCancelCreate(dev))
    #expect(harness.controller.rows().map(\.cancelRequested) == [true])
    await harness.reply()
    #expect(harness.cli.calls.contains(.terminateEarlierRun(runID)))

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.progress?.cancelRequested == true)
    #expect(harness.controller.notice == nil)

    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)

    #expect(harness.controller.notice == .createCancelled(dev))
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.terminateCalls == 1)
    monitor.cancel()
    await monitor.value
  }

  @Test func anEarlierSessionCreateThatLeavesARowIsNotNotified() async {
    let harness = await Harness([listing()])
    let runID = UUID()
    let running = [operation("dev", .create, runID: runID)]
    harness.cli.configure {
      $0.listInstances = [
        .success(listing()), .success(listing()), .success(listing(instance("dev", .stopped))),
      ]
      $0.activeOperations = [running, []]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == true)
    #expect(harness.cli.calls.contains(.terminateEarlierRun(runID)))

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.notice == nil)
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
    monitor.cancel()
    await monitor.value
  }

  @Test func aRefusedEarlierSessionRequestMakesCancellingAvailableAgainAndNothingIsNotified() async {
    let harness = await Harness([listing()])
    let runID = UUID()
    let running = [operation("dev", .create, runID: runID)]
    harness.cli.configure {
      $0.activeOperations = [running, running, []]
      $0.terminateEarlierRun = [false, true]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)

    harness.controller.cancelCreate(dev)
    #expect(await harness.reply() == false)
    #expect(harness.progress?.cancelRequested == false)
    #expect(harness.controller.canCancelCreate(dev))

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.canCancelCreate(dev))

    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)

    #expect(harness.controller.notice == nil)
    #expect(harness.controller.operations.isEmpty)
    monitor.cancel()
    await monitor.value
  }

  @Test func anUnreachableAgentDoesNotResolveAnAcceptedEarlierSessionCancel() async {
    let harness = await Harness([listing()])
    let running = [operation("dev", .create, runID: UUID())]
    harness.cli.configure { $0.activeOperations = [running, nil, running, []] }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    harness.controller.cancelCreate(dev)
    await harness.reply()

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.notice == nil)

    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)
    #expect(harness.controller.notice == nil)
    #expect(harness.progress?.cancelRequested == true)
    #expect(!harness.controller.canCancelCreate(dev))

    await clock.waitForSleeper(until: sleeper(9))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(4)
    #expect(harness.controller.notice == .createCancelled(dev))
    monitor.cancel()
    await monitor.value
  }

  @Test func anAcceptanceThatArrivesAfterTheRunLeftTheAgentsListIsStillResolved() async {
    let harness = await Harness([listing()])
    let running = [operation("dev", .create, runID: UUID())]
    harness.cli.configure { $0.activeOperations = [running, [], []] }
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeTerminateReturns = { await gate.pass() } }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    harness.controller.cancelCreate(dev)
    await gate.waitForArrivals(1)

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.notice == nil)

    gate.open()
    await harness.reply()
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)

    #expect(harness.controller.notice == .createCancelled(dev))
    monitor.cancel()
    await monitor.value
  }
}
