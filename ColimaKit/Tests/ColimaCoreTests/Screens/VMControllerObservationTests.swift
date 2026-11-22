import Observation
import Testing

@testable import ColimaCore

private func instance(cpus: Int, running: Bool = true) -> VMInstance {
  VMInstance(
    runState: running ? .running : .stopped(rawStatus: "Stopped"),
    arch: "aarch64",
    cpus: cpus,
    memoryBytes: 2 << 30,
    diskBytes: 100 << 30,
    runtime: "docker"
  )
}

private let foundColima = ToolchainStatus(
  colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:])
private let missingColima = ToolchainStatus(
  colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:])

private func sleeper(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let rounds = RoundCounter()
  let controller: VMController

  init(
    toolchain: ToolchainStatus = foundColima, observations: [Result<VMObservation, ColimaCLIError>]
  ) {
    controller = VMController(cli: cli, files: files)
    cli.configure {
      $0.toolchain = toolchain
      $0.listDefault = observations
    }
  }

  func wait(until predicate: @escaping @MainActor () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
  }

  func startMonitor(clock: ManualClock) -> Task<Void, Never> {
    let controller = controller
    let rounds = rounds
    return Task { await controller.monitor(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  func waitForObservation(_ expected: VMObservation) async {
    await wait { [controller] in controller.observation == expected }
  }

  var listCalls: Int { cli.calls.filter { $0 == .listDefault }.count }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMControllerObservationTests {

  @Test func nothingIsObservedWhileColimaIsMissing() async {
    let harness = Harness(toolchain: missingColima, observations: [.success(.absent)])
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.controller.refreshNow()
    monitor.cancel()
    await monitor.value

    #expect(harness.cli.calls == [.preflight])
    #expect(
      harness.controller.dockerAvailability == .colimaMissing(searched: ["/opt/homebrew/bin"]))
    #expect(harness.controller.toolchain == missingColima)
  }

  @Test func redetectingFindsColimaInstalledLaterAndObserves() async {
    let harness = Harness(
      toolchain: missingColima, observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    #expect(harness.cli.calls == [.preflight])

    harness.cli.configure { $0.toolchain = foundColima }
    await harness.controller.redetectToolchain()

    #expect(harness.cli.calls == [.preflight, .preflight, .listDefault])
    #expect(harness.controller.toolchain == foundColima)
    #expect(harness.controller.dockerAvailability == .ready)
  }

  @Test func availabilityIsUnknownWithoutAReasonBeforeTheToolchainIsDetected() {
    let harness = Harness(observations: [.success(.absent)])
    #expect(harness.controller.toolchain == nil)
    #expect(harness.controller.dockerAvailability == .vmUnknown(reason: nil))
  }

  @Test func colimaDisappearingDropsAnInFlightObservationAndForgetsTheOldOne() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    #expect(harness.controller.dockerAvailability == .ready)

    let gate = ArrivalGate()
    harness.cli.configure {
      $0.listDefault = [.success(.present(instance(cpus: 9)))]
      $0.beforeListDefaultReturns = gate.pass
    }
    let refresh = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)
    harness.cli.configure { $0.toolchain = missingColima }
    await harness.controller.redetectToolchain()
    gate.open()
    await refresh.value

    guard case .unknown = harness.controller.observation else {
      Issue.record("expected an unknown observation, got \(harness.controller.observation)")
      return
    }
    #expect(
      harness.controller.dockerAvailability == .colimaMissing(searched: ["/opt/homebrew/bin"]))
  }

  @Test func colimaVanishingAfterTheLookupIsRelookedUpAndStopsFurtherReads() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    harness.cli.configure { $0.listDefault = [.failure(.colimaMissing)] }
    harness.cli.configure { $0.toolchain = missingColima }
    let callsBefore = harness.cli.calls.count

    await harness.controller.refreshNow()
    #expect(harness.cli.calls.dropFirst(callsBefore) == [.listDefault, .preflight])
    #expect(
      harness.controller.dockerAvailability == .colimaMissing(searched: ["/opt/homebrew/bin"]))

    await harness.controller.refreshNow()
    #expect(harness.cli.calls.count == callsBefore + 2)
  }

  @Test func anObservationStartedBeforeTheGenerationAdvancedIsDiscarded() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 1)))])
    await harness.controller.redetectToolchain()
    harness.cli.configure { $0.listDefault = [.success(.absent)] }
    let before = harness.controller.observation

    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListDefaultReturns = gate.pass }
    let refresh = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)
    harness.controller.advanceObservationGeneration()
    gate.open()
    await refresh.value

    #expect(harness.controller.observation == before)
  }

  @Test func anObservationStartedAfterTheGenerationAdvancedIsApplied() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 1)))])
    await harness.controller.redetectToolchain()
    harness.controller.advanceObservationGeneration()
    harness.cli.configure { $0.listDefault = [.success(.absent)] }

    await harness.controller.refreshNow()

    #expect(harness.controller.observation == .absent)
  }

  @Test func aSlowerEarlierReadDoesNotOverwriteALaterReadThatFinishedFirst() async {
    let slow = VMObservation.present(instance(cpus: 1))
    let fast = VMObservation.present(instance(cpus: 2))
    // The first entry is consumed by the detection round below.
    let harness = Harness(observations: [.success(.absent), .success(slow), .success(fast)])
    await harness.controller.redetectToolchain()
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListDefaultReturns = gate.pass }

    let first = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)
    await harness.controller.refreshNow()
    #expect(harness.controller.observation == fast)
    gate.open()
    await first.value

    #expect(harness.controller.observation == fast)
  }

  @Test func aFailedReadMakesTheObservationUnknownAndTheNextCycleRetries() async {
    let running = VMObservation.present(instance(cpus: 2))
    let recovered = VMObservation.present(instance(cpus: 3))
    let harness = Harness(observations: [
      .success(running), .failure(.timedOut), .success(recovered),
    ])
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await harness.rounds.waitForRounds(1)
    #expect(harness.controller.observation == running)
    #expect(harness.controller.dockerAvailability == .ready)

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.wait { [controller = harness.controller] in
      if case .unknown = controller.observation { true } else { false }
    }
    guard case .vmUnknown(let reason?) = harness.controller.dockerAvailability else {
      Issue.record("expected vmUnknown with a reason, got \(harness.controller.dockerAvailability)")
      return
    }
    #expect(!reason.isEmpty)

    await harness.rounds.waitForRounds(2)
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.waitForObservation(recovered)
    #expect(harness.controller.dockerAvailability == .ready)

    monitor.cancel()
    await monitor.value
    #expect(harness.listCalls == 3)
  }

  @Test(arguments: [
    ColimaCLIError.timedOut,
    .launchFailed(reason: "spawn failed"),
    .nonZeroExit(code: 1, output: ["boom"]),
    .undecodable(detail: "bad json"),
    .colimaMissing,
  ])
  func everyReadFailureExceptCancellationBecomesUnknownWithAReason(error: ColimaCLIError) async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    harness.cli.configure { $0.listDefault = [.failure(error)] }

    await harness.controller.refreshNow()

    guard case .unknown(let reason) = harness.controller.observation else {
      Issue.record("expected unknown, got \(harness.controller.observation)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func aCancelledReadChangesNothing() async {
    let running = VMObservation.present(instance(cpus: 2))
    let harness = Harness(observations: [.success(running)])
    await harness.controller.redetectToolchain()
    harness.cli.configure { $0.listDefault = [.failure(.cancelled)] }

    await harness.controller.refreshNow()

    #expect(harness.controller.observation == running)
  }

  @Test(arguments: [
    (VMObservation.present(instance(cpus: 2)), DockerAvailability.ready),
    (.present(instance(cpus: 2, running: false)), .vmStopped),
    (.absent, .vmAbsent),
  ])
  func availabilityFollowsTheObservationWhenIdle(
    observation: VMObservation, expected: DockerAvailability
  ) async {
    let harness = Harness(observations: [.success(observation)])
    await harness.controller.redetectToolchain()
    #expect(harness.controller.dockerAvailability == expected)
  }

  @Test func availabilityCarriesTheReasonOfAnUnknownObservation() async {
    let harness = Harness(observations: [.failure(.undecodable(detail: "bad json"))])
    await harness.controller.redetectToolchain()
    #expect(harness.controller.dockerAvailability == .vmUnknown(reason: "bad json"))
  }

  @Test func availabilityIsBusyWhileAnOperationIsActiveWhateverTheObservationSays() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    #expect(harness.controller.dockerAvailability == .ready)

    harness.controller.activeOperation = VMOperationProgress(
      kind: .restart, stage: .stopping, startedAt: .now, stageStartedAt: .now
    )

    #expect(harness.controller.dockerAvailability == .vmBusy(.stopping))
    #expect(harness.controller.displayState == .stopping)
  }

  @Test func observationContinuesDuringAnOperationButAvailabilityStaysBusy() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    await harness.controller.redetectToolchain()
    harness.controller.activeOperation = VMOperationProgress(
      kind: .start, stage: .starting, startedAt: .now, stageStartedAt: .now
    )
    harness.cli.configure { $0.listDefault = [.success(.present(instance(cpus: 4)))] }

    await harness.controller.refreshNow()

    #expect(harness.controller.observation == .present(instance(cpus: 4)))
    #expect(harness.controller.dockerAvailability == .vmBusy(.starting))
  }

  @Test func displayStateIsDerivedFromObservationAndOperation() async {
    let harness = Harness(observations: [.success(.present(instance(cpus: 2)))])
    #expect(harness.controller.displayState == .stopped)
    await harness.controller.redetectToolchain()
    #expect(harness.controller.displayState == .running)
  }

  @Test func monitorObservesImmediatelyThenEveryThreeSecondsInTheForeground() async {
    let harness = Harness(observations: (1...3).map { .success(.present(instance(cpus: $0))) })
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await harness.rounds.waitForRounds(1)
    #expect(harness.controller.observation == .present(instance(cpus: 1)))
    #expect(harness.cli.calls == [.preflight, .listDefault])
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.observation == .present(instance(cpus: 2)))
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)
    #expect(harness.controller.observation == .present(instance(cpus: 3)))

    monitor.cancel()
    await monitor.value
    #expect(harness.cli.calls == [.preflight, .listDefault, .listDefault, .listDefault])
  }

  @Test func switchingToBackgroundStretchesTheWaitAndBackToForegroundShortensIt() async {
    let harness = Harness(observations: (1...3).map { .success(.present(instance(cpus: $0))) })
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: sleeper(3))

    harness.controller.setCadence(.background)
    await clock.waitForSleeper(until: sleeper(15))
    clock.advance(by: .seconds(3))
    #expect(harness.listCalls == 1)

    harness.controller.setCadence(.foreground)
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.observation == .present(instance(cpus: 2)))
    #expect(harness.listCalls == 2)

    monitor.cancel()
    await monitor.value
  }

  @Test func cadenceIntervalsAreThreeAndFifteenSeconds() {
    #expect(PollingCadence.foreground.interval == .seconds(3))
    #expect(PollingCadence.background.interval == .seconds(15))
  }

  @Test func aNewControllerStartsWithNothingKnown() {
    let harness = Harness(observations: [.success(.absent)])
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.cli.calls.isEmpty)
  }
}
