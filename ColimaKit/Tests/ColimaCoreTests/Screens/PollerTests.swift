import Testing

@testable import ColimaCore

@Suite(.timeLimit(.minutes(1)))
struct PollerTests {
  private func start(_ poller: Poller, clock: ManualClock, _ probe: PollProbe) -> Task<Void, Never>
  {
    Task {
      await poller.run(clock: clock, didCompleteRound: probe.rounds.roundCompleted, probe.operation)
    }
  }

  @Test func firstRoundStartsImmediatelyAndLaterRoundsFollowTheInterval() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)

    await probe.waitForStarts(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))
    #expect(probe.starts == 1)

    await probe.rounds.waitForRounds(1)
    clock.advance(by: .seconds(3))
    await probe.waitForStarts(2)
    await clock.waitForSleeper(until: .init(offset: .seconds(6)))
    #expect(probe.starts == 2)

    task.cancel()
    await task.value
  }

  @Test func nextRoundIsAnchoredToTheStartOfThePreviousOne() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))

    await probe.rounds.waitForRounds(1)
    clock.advance(by: .seconds(4))
    await probe.waitForStarts(2)
    await clock.waitForSleeper(until: .init(offset: .seconds(6)))
    #expect(probe.starts == 2)

    task.cancel()
    await task.value
  }

  @Test func roundsNeverOverlapAndAnUnfinishedRoundSkipsTheNextOnes() async {
    let clock = ManualClock()
    let probe = PollProbe(.blockedOnGate)
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)
    await probe.waitForStarts(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))

    clock.advance(by: .seconds(3))
    await clock.waitForSleeper(until: .init(offset: .seconds(6)))
    clock.advance(by: .seconds(3))
    await clock.waitForSleeper(until: .init(offset: .seconds(9)))
    #expect(probe.starts == 1)
    #expect(probe.maxConcurrent == 1)

    probe.openGate()
    await probe.rounds.waitForRounds(1)
    clock.advance(by: .seconds(3))
    await probe.waitForStarts(2)
    await clock.waitForSleeper(until: .init(offset: .seconds(12)))
    #expect(probe.starts == 2)
    #expect(probe.maxConcurrent == 1)

    task.cancel()
    await task.value
  }

  @Test func aWakeUpMoreThanOneIntervalLateRunsOneRoundNotACatchUpBurst() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))

    await probe.rounds.waitForRounds(1)
    clock.advance(by: .seconds(100))
    await probe.waitForStarts(2)
    await clock.waitForSleeper(until: .init(offset: .seconds(103)))
    #expect(probe.starts == 2)

    task.cancel()
    await task.value
  }

  @Test func cancellationWhileWaitingStopsWithoutAnotherRound() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)
    await probe.waitForStarts(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))

    task.cancel()
    await task.value

    clock.advance(by: .seconds(30))
    #expect(probe.starts == 1)
    #expect(clock.sleeperCount == 0)
  }

  @Test func cancellationReachesTheInFlightRoundAndRunReturnsAfterItEnds() async {
    let clock = ManualClock()
    let probe = PollProbe(.untilCancelled)
    let task = start(Poller(interval: .seconds(3)), clock: clock, probe)
    await probe.waitForStarts(1)

    task.cancel()
    await task.value

    #expect(probe.cancelledRuns == 1)
    #expect(probe.finishes == 1)
  }

  @Test func cancelledBeforeStartRunsNothing() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let poller = Poller(interval: .seconds(3))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await poller.run(clock: clock, probe.operation)
    }
    await task.value
    #expect(probe.starts == 0)
  }

  @Test func shorteningTheIntervalDuringAWaitRearmsFromTheLastStart() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let poller = Poller(interval: .seconds(15))
    let task = start(poller, clock: clock, probe)
    await probe.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(15)))

    clock.advance(by: .seconds(1))
    poller.setInterval(.seconds(3))
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))
    #expect(probe.starts == 1)

    clock.advance(by: .seconds(2))
    await probe.waitForStarts(2)
    await clock.waitForSleeper(until: .init(offset: .seconds(6)))
    #expect(probe.starts == 2)

    task.cancel()
    await task.value
  }

  @Test func shorteningTheIntervalPastTheElapsedTimeStartsARoundAtOnce() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let poller = Poller(interval: .seconds(15))
    let task = start(poller, clock: clock, probe)
    await probe.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(15)))

    clock.advance(by: .seconds(10))
    poller.setInterval(.seconds(3))
    await probe.waitForStarts(2)
    #expect(poller.interval == .seconds(3))

    task.cancel()
    await task.value
  }

  @Test func lengtheningTheIntervalDuringAWaitDelaysTheNextRound() async {
    let clock = ManualClock()
    let probe = PollProbe()
    let poller = Poller(interval: .seconds(3))
    let task = start(poller, clock: clock, probe)
    await probe.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: .init(offset: .seconds(3)))

    clock.advance(by: .seconds(1))
    poller.setInterval(.seconds(15))
    await clock.waitForSleeper(until: .init(offset: .seconds(15)))
    clock.advance(by: .seconds(5))
    #expect(probe.starts == 1)

    clock.advance(by: .seconds(9))
    await probe.waitForStarts(2)

    task.cancel()
    await task.value
  }

  @Test(.timeLimit(.minutes(1)))
  func realClockRoundsDoNotOverlapAndCancellationStopsTheLoop() async {
    let probe = PollProbe(.instant)
    let poller = Poller(interval: .milliseconds(20))
    let task = Task { await poller.run(clock: ContinuousClock(), probe.operation) }

    await probe.waitForStarts(3)
    task.cancel()
    await task.value

    let startsAfterStop = probe.starts
    try? await Task.sleep(for: .milliseconds(100))
    #expect(probe.starts == startsAfterStop)
    #expect(probe.maxConcurrent == 1)
  }

  @Test func realClockSlowRoundIsSkippedNotOverlapped() async {
    let probe = PollProbe(.blockedOnGate)
    let poller = Poller(interval: .milliseconds(10))
    let task = Task { await poller.run(clock: ContinuousClock(), probe.operation) }

    await probe.waitForStarts(1)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(probe.starts == 1)
    #expect(probe.maxConcurrent == 1)

    probe.openGate()
    await probe.waitForStarts(2)
    task.cancel()
    await task.value
    #expect(probe.maxConcurrent == 1)
  }
}
