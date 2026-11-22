import Foundation
import Observation
import Testing

@testable import ColimaCore

private func runningInstance(running: Bool = true) -> VMInstance {
  VMInstance(
    runState: running ? .running : .stopped(rawStatus: "Stopped"),
    arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30, runtime: "docker"
  )
}

private func snapshot(busy: UInt64, idle: UInt64, usedMiB: UInt64 = 512) -> ProcSnapshot {
  ProcSnapshot(
    busyTicks: busy, idleTicks: idle,
    memoryTotalBytes: 1024 << 20, memoryAvailableBytes: (1024 - usedMiB) << 20
  )
}

private func at(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let date = ManualDate()
  let clock = ManualClock()
  let rounds = RoundCounter()
  let controller: VMController
  let monitor: VMUsageMonitor

  init(
    observation: VMObservation = .present(runningInstance()),
    samples: [Result<ProcSnapshot, ColimaCLIError>]
  ) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure {
      $0.listDefault = [.success(observation)]
      $0.sampleUsage = samples
    }
    let date = date
    monitor = VMUsageMonitor(controller: controller, cli: cli, now: { date.now })
  }

  func observe() async { await controller.redetectToolchain() }

  func start() -> Task<Void, Never> {
    let monitor = monitor
    let clock = clock
    let rounds = rounds
    return Task { await monitor.run(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  func waitForRounds(_ count: Int) async {
    await rounds.waitForRounds(count)
  }

  func tick(to seconds: Int, completingRound round: Int) async {
    await clock.waitForSleeper(until: at(seconds))
    date.advance(by: 3)
    clock.advance(by: .seconds(3))
    await rounds.waitForRounds(round)
  }

  var sampleCalls: Int { cli.calls.filter { $0 == .sampleUsage }.count }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMUsageMonitorTests {

  @Test func keepsTenMinutesOfHistoryAtThreeSecondIntervals() {
    let harness = Harness(samples: [])
    #expect(VMUsageMonitor.pollInterval == .seconds(3))
    #expect(harness.monitor.cpu.capacity == 200)
    #expect(harness.monitor.memory.capacity == 200)
  }

  @Test func aStoppedVMIsNeverSampledAndTheReasonIsShown() async {
    let harness = Harness(
      observation: .present(runningInstance(running: false)),
      samples: [.success(snapshot(busy: 1, idle: 1))]
    )
    await harness.observe()
    let task = harness.start()

    await harness.waitForRounds(1)
    await harness.tick(to: 3, completingRound: 2)
    task.cancel()
    await task.value

    #expect(harness.sampleCalls == 0)
    guard case .unavailable(let reason) = harness.monitor.state else {
      Issue.record("expected unavailable, got \(harness.monitor.state)")
      return
    }
    #expect(reason.contains("stopped"))
    #expect(harness.monitor.cpu.points.isEmpty)
    #expect(harness.monitor.memory.points.isEmpty)
  }

  @Test(arguments: [
    (VMObservation.absent, "created"),
    (VMObservation.unknown(reason: "list に失敗しました"), "list に失敗しました"),
  ])
  func theReasonNamesWhyTheVMCannotBeSampled(observation: VMObservation, fragment: String) async {
    let harness = Harness(observation: observation, samples: [])
    await harness.observe()

    guard case .unavailable(let reason) = harness.monitor.state else {
      Issue.record("expected unavailable, got \(harness.monitor.state)")
      return
    }
    #expect(reason.contains(fragment))
  }

  @Test func aMissingColimaIsReportedAsUnavailable() async {
    let harness = Harness(samples: [])
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:])
    }
    await harness.observe()

    guard case .unavailable(let reason) = harness.monitor.state else {
      Issue.record("expected unavailable, got \(harness.monitor.state)")
      return
    }
    #expect(reason.contains("Colima"))
  }

  @Test func aRunningVMIsSampled() async {
    let harness = Harness(samples: [.success(snapshot(busy: 0, idle: 0))])
    await harness.observe()

    #expect(harness.monitor.state == .sampling)
  }

  @Test func theFirstSampleIsAGapAndLaterSamplesCarryTheDifference() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 100, idle: 100, usedMiB: 256)),
      .success(snapshot(busy: 130, idle: 190, usedMiB: 300)),
    ])
    await harness.observe()
    let start = harness.date.now
    let task = harness.start()

    await harness.waitForRounds(1)
    await harness.tick(to: 3, completingRound: 2)
    task.cancel()
    await task.value

    #expect(
      harness.monitor.cpu.points == [
        UsagePoint(time: start, value: nil),
        UsagePoint(time: start.addingTimeInterval(3), value: 25),
      ])
    #expect(
      harness.monitor.memory.points == [
        UsagePoint(time: start, value: nil),
        UsagePoint(time: start.addingTimeInterval(3), value: Double(300 << 20)),
      ])
  }

  @Test func aFailureAddsAGapAndTheNextPeriodRetries() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 100, idle: 100)),
      .failure(.timedOut),
      .success(snapshot(busy: 150, idle: 250)),
    ])
    await harness.observe()
    let task = harness.start()

    await harness.waitForRounds(1)
    await harness.tick(to: 3, completingRound: 2)
    #expect(harness.monitor.cpu.points.last?.value == nil)
    #expect(harness.monitor.memory.points.last?.value == nil)

    await harness.tick(to: 6, completingRound: 3)
    task.cancel()
    await task.value

    #expect(harness.sampleCalls == 3)
    #expect(harness.monitor.cpu.points.map(\.value) == [nil, nil, 25])
    #expect(harness.monitor.memory.points.map(\.value) == [nil, nil, Double(512 << 20)])
  }

  @Test func aCounterThatWentBackwardsIsAGap() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 5000, idle: 5000)),
      .success(snapshot(busy: 10, idle: 10)),
      .success(snapshot(busy: 20, idle: 20)),
    ])
    await harness.observe()
    let task = harness.start()

    await harness.waitForRounds(1)
    await harness.tick(to: 3, completingRound: 2)
    await harness.tick(to: 6, completingRound: 3)
    task.cancel()
    await task.value

    #expect(harness.monitor.cpu.points.map(\.value) == [nil, nil, 50])
  }

  @Test func cancellingWhileASampleIsInFlightAddsNoGap() async {
    let harness = Harness(samples: [.failure(.timedOut)])
    await harness.observe()
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeSampleUsageReturns = gate.pass }
    let task = harness.start()

    await gate.waitForArrivals(1)
    task.cancel()
    await task.value

    #expect(harness.sampleCalls == 1)
    #expect(harness.monitor.cpu.points.isEmpty)
    #expect(harness.monitor.memory.points.isEmpty)
  }

  @Test func aSampleThatFailsBecauseOfCancellationAddsNoGap() async {
    let harness = Harness(samples: [.failure(.cancelled)])
    await harness.observe()
    let task = harness.start()

    await harness.waitForRounds(1)
    task.cancel()
    await task.value

    #expect(harness.sampleCalls == 1)
    #expect(harness.monitor.cpu.points.isEmpty)
    #expect(harness.monitor.memory.points.isEmpty)
  }

  @Test func aRestartedVMStartsANewDifferenceWithAGap() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 100, idle: 100)),
      .success(snapshot(busy: 200, idle: 200)),
      .success(snapshot(busy: 300, idle: 300)),
    ])
    await harness.observe()
    let task = harness.start()
    await harness.waitForRounds(1)

    harness.cli.configure { $0.listDefault = [.success(.present(runningInstance(running: false)))] }
    await harness.controller.refreshNow()
    await harness.tick(to: 3, completingRound: 2)
    #expect(harness.sampleCalls == 1)

    harness.cli.configure { $0.listDefault = [.success(.present(runningInstance()))] }
    await harness.controller.refreshNow()
    await harness.tick(to: 6, completingRound: 3)
    await harness.tick(to: 9, completingRound: 4)
    task.cancel()
    await task.value

    #expect(harness.monitor.cpu.points.map(\.value) == [nil, nil, 50])
  }

  @Test func aRunCancelledWhileSamplingDoesNotPublishTheLateSample() async {
    let harness = Harness(samples: [.success(snapshot(busy: 100, idle: 100))])
    let gate = ArrivalGate()
    harness.cli.configure {
      $0.beforeSampleUsageReturns = gate.pass
      $0.sampleUsageHonorsCancellation = false
    }
    await harness.observe()
    let task = harness.start()
    await gate.waitForArrivals(1)

    task.cancel()
    gate.open()
    await task.value

    #expect(harness.monitor.cpu.points.isEmpty)
    #expect(harness.monitor.memory.points.isEmpty)
  }

  @Test func reopeningAfterALongPauseStartsWithAGapInsteadOfAnAverageOverThePause() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 100, idle: 100)),
      .success(snapshot(busy: 200, idle: 200)),
      .success(snapshot(busy: 6000, idle: 60_000)),
      .success(snapshot(busy: 6030, idle: 60_090)),
    ])
    await harness.observe()
    let first = harness.start()
    await harness.waitForRounds(1)
    await harness.tick(to: 3, completingRound: 2)
    first.cancel()
    await first.value

    harness.date.advance(by: 600)
    let reopenedAt = harness.date.now
    let second = harness.start()
    await harness.waitForRounds(3)
    await harness.tick(to: 6, completingRound: 4)
    second.cancel()
    await second.value

    #expect(harness.monitor.cpu.points.map(\.value) == [nil, 50, nil, 25])
    #expect(harness.monitor.cpu.points[2].time == reopenedAt)
    #expect(
      harness.monitor.memory.points.map(\.value) == [
        nil, Double(512 << 20), nil, Double(512 << 20),
      ])
  }

  @Test func reopeningWithinTheCutoffContinuesTheLine() async {
    let harness = Harness(samples: [
      .success(snapshot(busy: 100, idle: 100)),
      .success(snapshot(busy: 130, idle: 190)),
    ])
    await harness.observe()
    let first = harness.start()
    await harness.waitForRounds(1)
    first.cancel()
    await first.value

    harness.date.advance(by: 3)
    let second = harness.start()
    await harness.waitForRounds(2)
    second.cancel()
    await second.value

    #expect(harness.monitor.cpu.points.map(\.value) == [nil, 25])
  }

  @Test func theViewStopsPollingWhenItsTaskIsCancelled() async {
    let harness = Harness(samples: [.success(snapshot(busy: 1, idle: 1))])
    await harness.observe()
    let task = harness.start()
    await harness.waitForRounds(1)

    task.cancel()
    await task.value
    harness.clock.advance(by: .seconds(30))

    #expect(harness.sampleCalls == 1)
    #expect(harness.clock.sleeperCount == 0)
  }
}
