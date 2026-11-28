import Foundation
import Observation
import Synchronization
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(_ name: String, _ runState: MachineRunState = .running) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30,
    mounts: [], templateID: "ubuntu")
}

private func listing(_ instances: MachineInstance...) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: [])
}

private func earlier(_ name: String, _ kind: MachineOperationKind, runID: UUID = UUID())
  -> ActiveMachineOperation
{
  ActiveMachineOperation(runID: runID, name: machineName(name), kind: kind)
}

private let missingLimactl = LimaToolchain.missing(searched: ["/opt/homebrew/bin/limactl"])

private final class OrderedGates: Sendable {
  private let gates: [ArrivalGate]
  private let next = Mutex(0)

  init(_ count: Int) {
    gates = (0..<count).map { _ in ArrivalGate() }
  }

  func gate(_ index: Int) -> ArrivalGate { gates[index] }

  @Sendable func pass() async {
    let index = next.withLock { value in
      defer { value += 1 }
      return value
    }
    guard index < gates.count else { return }
    await gates[index].pass()
  }
}

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let controller: MachineController

  init(_ initial: LimaListing? = nil, listings: [LimaListing] = []) async {
    controller = MachineController(cli: cli)
    if let initial {
      cli.configure { $0.listInstances = ([initial] + listings).map { .success($0) } }
      await controller.refreshNow()
    }
  }

  var runs: [MachineCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func key(_ name: String) -> MachineKey { machineName(name).key }

  func task(for name: String) -> Task<Void, Never>? { controller.operationTasks[key(name)] }

  func process(running command: MachineCommand) -> FakeMachineProcess? {
    cli.processes.first { $0.command == command }
  }

  func waitForProcesses(_ count: Int) async {
    _ = await cli.process(at: count - 1)
  }

  func wait(until predicate: @escaping @MainActor () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerOperationTests {

  // MARK: Whether an operation can start

  @Test func startNeedsAStoppedMachineStopNeedsARunningOneAndDeleteNeedsAnyListedOne() async {
    let harness = await Harness(
      listing(
        instance("on", .running), instance("off", .stopped), instance("odd", .other(rawStatus: "Paused")),
        instance("bad", .broken(errors: ["no config"]))))
    let controller = harness.controller
    func flags(_ name: String) -> [Bool] {
      let name = machineName(name)
      return [controller.canStart(name), controller.canStop(name), controller.canDelete(name)]
    }

    #expect(flags("on") == [false, true, true])
    #expect(flags("off") == [true, false, true])
    #expect(flags("odd") == [false, false, true])
    #expect(flags("bad") == [false, false, true])
    #expect(flags("ghost") == [false, false, false])
  }

  @Test func nothingIsPossibleBeforeTheFirstListOrWhileLimactlIsMissing() async {
    let unread = await Harness()
    #expect(!unread.controller.canStart(machineName("a")))
    #expect(!unread.controller.canDelete(machineName("a")))

    let harness = await Harness(listing(instance("off", .stopped), instance("on")))
    harness.cli.configure { $0.toolchain = missingLimactl }
    harness.cli.configure { $0.listInstances = [.failure(.limactlMissing)] }
    await harness.controller.refreshNow()

    let off = machineName("off")
    #expect(!harness.controller.canStart(off))
    #expect(!harness.controller.canStop(machineName("on")))
    #expect(!harness.controller.canDelete(off))
    #expect(harness.controller.performStart(off) == .notApplicable)
    #expect(harness.runs.isEmpty)
  }

  @Test func theKeyIsCaseFoldedSoAnotherSpellingFindsTheSameMachine() async {
    let harness = await Harness(listing(instance("Web", .stopped)))
    #expect(harness.controller.canStart(machineName("web")))
    #expect(harness.controller.performStart(machineName("WEB")) == .started)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value
  }

  @Test func aRequestThatDoesNotApplyTakesNoSlotAndRunsNothing() async {
    let harness = await Harness(listing(instance("on", .running), instance("off", .stopped)))

    #expect(harness.controller.performStart(machineName("on")) == .notApplicable)
    #expect(harness.controller.stop(machineName("off")) == .notApplicable)
    #expect(harness.controller.performStart(machineName("ghost")) == .notApplicable)

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.runs.isEmpty)
  }

  // MARK: Start and stop

  @Test func startTakesTheSlotBeforeAnyAwaitAndShowsStarting() async {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web"))])
    let web = machineName("web")

    let outcome = harness.controller.performStart(web)

    #expect(outcome == .started)
    #expect(harness.controller.operations[web.key]?.kind == .start)
    if case .thisSession? = harness.controller.operations[web.key]?.origin {} else {
      Issue.record("the slot must belong to this session")
    }
    #expect(harness.controller.rows().map(\.display) == [.starting])
    #expect(!harness.controller.canStart(web))
    #expect(!harness.controller.canStop(web))
    #expect(!harness.controller.canDelete(web))

    let process = await harness.cli.process(at: 0)
    process.send("booting")
    process.exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.runs == [.start(web)])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.running])
    #expect(harness.controller.failures.isEmpty)
  }

  @Test func stopShowsStoppingAndRunsLimactlStop() async {
    let harness = await Harness(listing(instance("web")), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")

    #expect(harness.controller.stop(web) == .started)
    #expect(harness.controller.rows().map(\.display) == [.stopping])

    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.runs == [.stop(web)])
    #expect(harness.controller.rows().map(\.display) == [.stopped])
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func outputIsRecordedLineByLineWhileTheOperationRuns() async throws {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web"))])
    let web = machineName("web")
    harness.controller.performStart(web)
    let record = try #require(harness.controller.records[web.key])

    let process = await harness.cli.process(at: 0)
    process.send("first")
    process.send("second")
    await harness.wait { record.lines.count == 2 }

    #expect(record.kind == .start)
    #expect(record.texts == ["first", "second"])
    #expect(record.outcome == nil)

    process.exit(code: 0)
    await harness.task(for: "web")?.value
    #expect(record.outcome == .succeeded)
    #expect(record.endedAt != nil)
    #expect(harness.controller.records[web.key] === record)
  }

  // MARK: One operation per machine

  @Test func aSecondRequestOnTheSameMachineIsRefusedWhileTheFirstRuns() async {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web"))])
    let web = machineName("web")

    #expect(harness.controller.performStart(web) == .started)
    #expect(harness.controller.performStart(web) == .busy)
    #expect(harness.controller.stop(web) == .busy)
    #expect(harness.controller.stop(machineName("WEB")) == .busy)

    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value
    #expect(harness.runs == [.start(web)])
  }

  @Test func twoDifferentMachinesRunAtTheSameTime() async throws {
    let harness = await Harness(
      listing(instance("a", .stopped), instance("b")),
      listings: [listing(instance("a"), instance("b"))])
    let a = machineName("a")
    let b = machineName("b")

    #expect(harness.controller.performStart(a) == .started)
    #expect(harness.controller.stop(b) == .started)
    await harness.waitForProcesses(2)

    #expect(harness.controller.rows().map(\.display) == [.starting, .stopping])
    let startA = try #require(harness.process(running: .start(a)))
    let stopB = try #require(harness.process(running: .stop(b)))
    let taskA = harness.task(for: "a")
    let taskB = harness.task(for: "b")

    stopB.exit(code: 0)
    await taskB?.value
    #expect(harness.controller.operations.keys.contains(a.key))
    #expect(!harness.controller.operations.keys.contains(b.key))

    startA.exit(code: 0)
    await taskA?.value
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func aRunningDefaultVMOperationDoesNotBlockMachineOperations() async {
    let vmCLI = FakeColimaCLI()
    vmCLI.configure { $0.listDefault = [.success(.present(instance(running: false)))] }
    let vm = VMController(cli: vmCLI, files: InMemoryColimaFileStore())
    await vm.redetectToolchain()
    vm.start()
    #expect(vm.activeOperation != nil)

    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web"))])
    #expect(harness.controller.performStart(machineName("web")) == .started)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.controller.rows().map(\.display) == [.running])
    #expect(vm.activeOperation != nil)
    let vmProcess = await vmCLI.process(at: 0)
    vmProcess.exit(code: 0)
    await vm.operationTask?.value
  }

  @Test func anEarlierSessionOperationHoldsTheSlot() async {
    let harness = await Harness(listing(instance("web", .stopped)))
    harness.cli.configure { $0.activeOperations = [[earlier("web", .start)]] }
    let rounds = RoundCounter()
    let controller = harness.controller
    let monitor = Task { await controller.monitor(clock: ManualClock(), didCompleteRound: rounds.roundCompleted) }
    await rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    let web = machineName("web")
    #expect(controller.performStart(web) == .busy)
    #expect(controller.stop(web) == .busy)
    #expect(!controller.canDelete(web))
    #expect(harness.runs.isEmpty)
  }

  // MARK: Failures

  @Test func aFailureKeepsTheCauseAndTheLast50LinesVerbatim() async throws {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")
    let lines = (1...80).map { "  line \($0) \u{3042}  " }
    harness.cli.configure { $0.scriptedRuns = [lines.map { .output($0) } + [.exited(code: 1)]] }

    harness.controller.performStart(web)
    await harness.task(for: "web")?.value

    let failure = try #require(harness.controller.failures[web.key])
    #expect(failure.name == web)
    #expect(failure.kind == .start)
    #expect(failure.cause == .exited(code: 1))
    #expect(failure.outputTail == Array(lines.suffix(50)))
    #expect(harness.controller.records[web.key]?.outcome == .failed(failure))
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
  }

  @Test func aLaunchFailureIsAFailureWithItsReason() async throws {
    let harness = await Harness(listing(instance("web")), listings: [listing(instance("web"))])
    let web = machineName("web")
    harness.cli.configure { $0.scriptedRuns = [[.launchFailed(reason: "no such file")]] }

    harness.controller.stop(web)
    await harness.task(for: "web")?.value

    let failure = try #require(harness.controller.failures[web.key])
    #expect(failure.cause == .launchFailed(reason: "no such file"))
    #expect(failure.outputTail.isEmpty)
    #expect(failure.kind == .stop)
  }

  @Test func anOutputStreamThatEndsWithoutAnExitIsAFailure() async throws {
    let harness = await Harness(listing(instance("web")), listings: [listing(instance("web"))])
    let web = machineName("web")

    harness.controller.stop(web)
    let process = await harness.cli.process(at: 0)
    process.send("partial")
    process.endWithoutExit()
    await harness.task(for: "web")?.value

    let failure = try #require(harness.controller.failures[web.key])
    if case .launchFailed = failure.cause {} else { Issue.record("expected a launch failure, got \(failure.cause)") }
    #expect(failure.outputTail == ["partial"])
  }

  @Test func dismissingAFailureClearsOnlyThatMachinesFailure() async throws {
    let harness = await Harness(
      listing(instance("a", .stopped), instance("b", .stopped)),
      listings: [listing(instance("a", .stopped), instance("b", .stopped))])
    harness.cli.configure {
      $0.scriptedRuns = [[.exited(code: 1)], [.exited(code: 2)]]
    }
    harness.controller.performStart(machineName("a"))
    await harness.task(for: "a")?.value
    harness.controller.performStart(machineName("b"))
    await harness.task(for: "b")?.value
    #expect(harness.controller.failures.count == 2)

    harness.controller.dismissFailure(for: machineName("A"))

    #expect(harness.controller.failures[harness.key("a")] == nil)
    #expect(harness.controller.failures[harness.key("b")]?.cause == .exited(code: 2))
    harness.controller.dismissFailure(for: machineName("a"))
    #expect(harness.controller.failures.count == 1)
  }

  @Test func theNextOperationReplacesThePreviousRecordAndFailure() async throws {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")
    harness.cli.configure { $0.scriptedRuns = [[.output("boom"), .exited(code: 1)]] }
    harness.controller.performStart(web)
    await harness.task(for: "web")?.value
    let firstRecord = try #require(harness.controller.records[web.key])
    #expect(harness.controller.failures[web.key] != nil)

    #expect(harness.controller.performStart(web) == .started)

    #expect(harness.controller.failures[web.key] == nil)
    #expect(harness.controller.records[web.key] !== firstRecord)
    #expect(harness.controller.records[web.key]?.lines.isEmpty == true)
    let process = await harness.cli.process(at: 1)
    process.exit(code: 0)
    await harness.task(for: "web")?.value
    #expect(harness.controller.failures[web.key] == nil)
  }

  // MARK: The list is read again before the slot is released

  @Test func theSlotStaysHeldAndTheFailureHiddenUntilTheFinalReadLands() async throws {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")
    let gate = ArrivalGate()
    harness.cli.configure {
      $0.scriptedRuns = [[.exited(code: 1)]]
      $0.beforeListInstancesReturns = gate.pass
    }

    harness.controller.performStart(web)
    await gate.waitForArrivals(1)

    #expect(harness.controller.operations[web.key]?.kind == .start)
    #expect(harness.controller.rows().map(\.display) == [.starting])
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.records[web.key]?.outcome == nil)
    #expect(harness.controller.performStart(web) == .busy)

    gate.open()
    await harness.task(for: "web")?.value

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.failures[web.key] != nil)
    #expect(harness.cli.calls.filter { $0 == .listInstances }.count == 2)
  }

  @Test func aSlowReadFromBeforeTheOperationEndedDoesNotOverwriteTheFinalRead() async throws {
    let harness = await Harness(
      listing(instance("web", .stopped)),
      listings: [listing(instance("stale")), listing(instance("web"))])
    let web = machineName("web")
    let gates = OrderedGates(2)
    harness.cli.configure { $0.beforeListInstancesReturns = gates.pass }

    harness.controller.performStart(web)
    let staleRead = Task { await harness.controller.refreshNow() }
    await gates.gate(0).waitForArrivals(1)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await gates.gate(1).waitForArrivals(1)

    gates.gate(0).open()
    await staleRead.value
    #expect(harness.controller.machines == [instance("web", .stopped)])
    #expect(harness.controller.operations[web.key] != nil)

    gates.gate(1).open()
    await harness.task(for: "web")?.value
    #expect(harness.controller.machines == [instance("web")])
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func aReadThatBeganBeforeAnOperationStartedIsDroppedWhenItLandsDuringTheOperation() async throws {
    let harness = await Harness(
      listing(instance("web", .stopped)),
      listings: [listing(instance("stale")), listing(instance("web"))])
    let web = machineName("web")
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListInstancesReturns = gate.pass }

    let staleRead = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)
    harness.controller.performStart(web)
    gate.open()
    await staleRead.value

    #expect(harness.controller.machines == [instance("web", .stopped)])
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value
    #expect(harness.controller.machines == [instance("web")])
  }

  @Test func anOperationOnAnotherMachineDuringTheFinalReadDoesNotLeaveTheStateStale() async throws {
    let harness = await Harness(
      listing(instance("a", .stopped), instance("b", .stopped)),
      listings: [
        listing(instance("a", .stopped), instance("b", .stopped)),
        listing(instance("a"), instance("b", .stopped)),
      ])
    let a = machineName("a")
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListInstancesReturns = gate.pass }

    harness.controller.performStart(a)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await gate.waitForArrivals(1)
    #expect(harness.controller.performStart(machineName("b")) == .started)
    gate.open()
    await harness.task(for: "a")?.value

    #expect(harness.controller.operations[a.key] == nil)
    #expect(harness.controller.machines?.first == instance("a"))
    let processB = await harness.cli.process(at: 1)
    processB.exit(code: 0)
    await harness.task(for: "b")?.value
  }

  // MARK: Operations of an earlier session meet this session's slots

  @Test func anEarlierSessionAnswerIgnoresTheMachinesThisSessionHolds() async throws {
    let harness = await Harness(listing(instance("web", .stopped), instance("db")))
    let web = machineName("web")
    harness.controller.performStart(web)
    let thisRun = await harness.cli.process(at: 0)
    let runID = UUID()
    harness.cli.configure {
      $0.activeOperations = [[earlier("WEB", .stop), earlier("db", .stop, runID: runID)]]
    }
    let rounds = RoundCounter()
    let controller = harness.controller
    let monitor = Task { await controller.monitor(clock: ManualClock(), didCompleteRound: rounds.roundCompleted) }
    await rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    if case .thisSession? = controller.operations[web.key]?.origin {} else {
      Issue.record("the earlier session's answer replaced this session's slot")
    }
    #expect(controller.operations[web.key]?.kind == .start)
    #expect(
      controller.operations[harness.key("db")]
        == MachineOperationProgress(kind: .stop, origin: .earlierSession(runID: runID)))
    #expect(controller.rows().map(\.display) == [.starting, .stopping])

    thisRun.exit(code: 0)
    await harness.task(for: "web")?.value
  }

  @Test func anEarlierSessionAnswerThatArrivesAfterThisSessionsOperationEndedIsDropped() async throws {
    let harness = await Harness()
    harness.cli.configure {
      $0.listInstances = [
        .success(listing(instance("web", .stopped))), .success(listing(instance("web"))),
      ]
      $0.activeOperations = [[earlier("web", .start)], []]
    }
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeActiveOperationsReturns = gate.pass }
    let clock = ManualClock()
    let rounds = RoundCounter()
    let controller = harness.controller
    let monitor = Task { await controller.monitor(clock: clock, didCompleteRound: rounds.roundCompleted) }
    await gate.waitForArrivals(1)

    let web = machineName("web")
    #expect(controller.performStart(web) == .started)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value
    #expect(controller.operations.isEmpty)

    gate.open()
    await rounds.waitForRounds(1)

    #expect(controller.operations.isEmpty)
    #expect(controller.rows().map(\.display) == [.running])

    await clock.waitForSleeper(until: .init(offset: .seconds(3)))
    clock.advance(by: .seconds(3))
    await rounds.waitForRounds(2)
    #expect(harness.cli.calls.filter { $0 == .activeOperations }.count == 2)
    #expect(controller.operations.isEmpty)
    monitor.cancel()
    await monitor.value
  }
}
