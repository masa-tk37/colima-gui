import Foundation
import Observation
import Testing

@testable import ColimaCore

private let web = ContainerID(rawValue: "web")

private func detail(running: Bool) -> ContainerDetail {
  ContainerDetail(id: web, hasTTY: false, isRunning: running, networkNames: [])
}

/// With two online CPUs, a CPU delta of half the system delta is 100%.
private func sample(
  cpu: UInt64 = 0, previousCPU: UInt64 = 0,
  system: UInt64 = 0, previousSystem: UInt64 = 0,
  memoryMiB: UInt64 = 100
) -> ContainerStatsSample {
  ContainerStatsSample(
    cpuTotalUsage: cpu, previousCPUTotalUsage: previousCPU,
    systemCPUUsage: system, previousSystemCPUUsage: previousSystem,
    onlineCPUs: 2, memoryUsage: memoryMiB << 20, memoryInactiveFile: nil
  )
}

private let firstSample = sample(cpu: 100, system: 1000, memoryMiB: 100)
private let secondSample = sample(
  cpu: 150, previousCPU: 100, system: 1100, previousSystem: 1000, memoryMiB: 120)

private func at(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let engine = FakeDockerEngine()
  let date = ManualDate()
  let clock = ManualClock()
  let rounds = RoundCounter()
  let session: StatsSession

  init(
    running: Bool = true, stats: Result<ContainerStatsSample, DockerError> = .success(firstSample)
  ) {
    engine.configure {
      $0.containerDetails[web] = .success(detail(running: running))
      $0.containerStats[web] = stats
    }
    let date = date
    session = StatsSession(engine: engine, container: web, now: { date.now })
  }

  func start() -> Task<Void, Never> {
    let session = session
    let clock = clock
    let rounds = rounds
    return Task { await session.run(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  func wait(until condition: @escaping @MainActor @Sendable () -> Bool) async {
    for await holds in Observations({ condition() }) where holds { return }
  }

  func waitForPoints(_ count: Int) async {
    let session = session
    await wait { session.cpu.points.count >= count }
  }

  /// Waits for the previous round to finish so the next period is not skipped as overlapping.
  func tick(to seconds: Int) async {
    await rounds.waitForRounds(seconds / 3)
    await clock.waitForSleeper(until: at(seconds))
    date.advance(by: 3)
    clock.advance(by: .seconds(3))
  }

  var statsCalls: Int { engine.calls.filter { $0 == .containerStats(web) }.count }
  var inspectCalls: Int { engine.calls.filter { $0 == .inspectContainer(web) }.count }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StatsSessionTests {

  @Test func keepsFiveMinutesOfHistoryAtThreeSecondIntervals() {
    let harness = Harness()
    #expect(StatsSession.pollInterval == .seconds(3))
    #expect(harness.session.cpu.capacity == 100)
    #expect(harness.session.memory.capacity == 100)
  }

  @Test func theSessionStartsBeforeAnythingIsKnown() {
    let harness = Harness()
    #expect(harness.session.state == .starting)
    #expect(harness.session.state.message == nil)
  }

  @Test func aStoppedContainerIsNeverQueriedForStatsAndTheReasonIsShown() async {
    let harness = Harness(running: false)
    let gate = ArrivalGate(blocking: 0)
    harness.engine.configure { config in
      config.beforeReturn = { call in if call == .inspectContainer(web) { await gate.pass() } }
    }
    let task = harness.start()
    let session = harness.session

    await harness.wait { session.state == .notRunning }
    await harness.tick(to: 3)
    await gate.waitForArrivals(2)
    task.cancel()
    await task.value

    #expect(harness.statsCalls == 0)
    #expect(harness.session.state == .notRunning)
    #expect(harness.session.state.message?.contains("is not running") == true)
    #expect(harness.session.cpu.points.isEmpty)
    #expect(harness.session.memory.points.isEmpty)
  }

  @Test func aMissingContainerAtStartIsNotRunning() async {
    let harness = Harness()
    harness.engine.configure { $0.containerDetails[web] = nil }
    let task = harness.start()
    let session = harness.session

    await harness.wait { session.state == .notRunning }
    task.cancel()
    await task.value

    #expect(harness.statsCalls == 0)
  }

  @Test func eachRoundChecksRunningBeforeFetchingStats() async {
    let harness = Harness()
    let task = harness.start()

    await harness.waitForPoints(1)
    await harness.tick(to: 3)
    await harness.waitForPoints(2)
    task.cancel()
    await task.value

    #expect(
      harness.engine.calls == [
        .inspectContainer(web), .containerStats(web),
        .inspectContainer(web), .containerStats(web),
      ])
    #expect(harness.session.state == .running)
    #expect(harness.session.state.message == nil)
  }

  @Test func theFirstSampleWithoutPreviousCountersHasNoCPUValueAndLaterOnesCarryTheDifference()
    async
  {
    let harness = Harness()
    let start = harness.date.now
    let task = harness.start()

    await harness.waitForPoints(1)
    harness.engine.configure { $0.containerStats[web] = .success(secondSample) }
    await harness.tick(to: 3)
    await harness.waitForPoints(2)
    task.cancel()
    await task.value

    #expect(
      harness.session.cpu.points == [
        UsagePoint(time: start, value: nil),
        UsagePoint(time: start.addingTimeInterval(3), value: 100),
      ])
    #expect(
      harness.session.memory.points == [
        UsagePoint(time: start, value: Double(100 << 20)),
        UsagePoint(time: start.addingTimeInterval(3), value: Double(120 << 20)),
      ])
  }

  @Test func aContainerThatStopsBetweenRoundsEndsTheRunAndKeepsTheHistory() async {
    let harness = Harness(stats: .success(secondSample))
    let task = harness.start()
    let session = harness.session

    await harness.waitForPoints(1)
    harness.engine.configure { $0.containerDetails[web] = .success(detail(running: false)) }
    await harness.tick(to: 3)
    await task.value

    #expect(session.state == .containerStopped)
    #expect(session.state.message?.contains("stopped") == true)
    #expect(session.cpu.points.count == 1)
    #expect(harness.statsCalls == 1)
    #expect(harness.clock.sleeperCount == 0)
  }

  @Test func aContainerRemovedBetweenRoundsIsTreatedAsStopped() async {
    let harness = Harness()
    let task = harness.start()

    await harness.waitForPoints(1)
    harness.engine.configure { $0.containerDetails[web] = nil }
    await harness.tick(to: 3)
    await task.value

    #expect(harness.session.state == .containerStopped)
    #expect(harness.statsCalls == 1)
  }

  @Test func aStatsNotFoundWhileFetchingStopsUpdates() async {
    let harness = Harness()
    let task = harness.start()

    await harness.waitForPoints(1)
    harness.engine.configure { $0.containerStats[web] = nil }
    await harness.tick(to: 3)
    await task.value

    #expect(harness.session.state == .containerStopped)
    #expect(harness.session.cpu.points.count == 1)
    #expect(harness.session.memory.points.count == 1)

    harness.clock.advance(by: .seconds(30))
    #expect(harness.statsCalls == 2)
    #expect(harness.inspectCalls == 2)
  }

  @Test func aContainerThatStopsWhileStatsAreInFlightStopsUpdates() async {
    let harness = Harness()
    let gate = ArrivalGate()
    harness.engine.configure { config in
      config.beforeReturn = { call in if call == .containerStats(web) { await gate.pass() } }
    }
    let task = harness.start()

    await gate.waitForArrivals(1)
    harness.engine.configure { $0.containerStats[web] = nil }
    gate.open()
    await task.value

    #expect(harness.session.state == .containerStopped)
    #expect(harness.session.cpu.points.isEmpty)
  }

  @Test func aContainerThatStartsLaterIsPickedUp() async {
    let harness = Harness(running: false)
    let task = harness.start()
    let session = harness.session

    await harness.wait { session.state == .notRunning }
    harness.engine.configure { $0.containerDetails[web] = .success(detail(running: true)) }
    await harness.tick(to: 3)
    await harness.waitForPoints(1)
    task.cancel()
    await task.value

    #expect(session.state == .running)
    #expect(harness.statsCalls == 1)
  }

  @Test func aFailureAddsAGapToBothSeriesAndTheNextRoundRetries() async {
    let harness = Harness(stats: .failure(.timedOut))
    let task = harness.start()
    let session = harness.session

    await harness.waitForPoints(1)
    #expect(session.cpu.points.map(\.value) == [nil])
    #expect(session.memory.points.map(\.value) == [nil])
    #expect(session.state == .running)

    harness.engine.configure { $0.containerStats[web] = .success(secondSample) }
    await harness.tick(to: 3)
    await harness.waitForPoints(2)
    task.cancel()
    await task.value

    #expect(session.cpu.points.map(\.value) == [nil, 100])
    #expect(session.memory.points.map(\.value) == [nil, Double(120 << 20)])
  }

  @Test func anInspectFailureAddsAGapAndKeepsRunning() async {
    let harness = Harness()
    let task = harness.start()
    let session = harness.session

    await harness.waitForPoints(1)
    harness.engine.configure {
      $0.containerDetails[web] = .failure(.engineUnreachable(detail: "socket missing"))
    }
    await harness.tick(to: 3)
    await harness.waitForPoints(2)
    task.cancel()
    await task.value

    #expect(session.cpu.points.map(\.value) == [nil, nil])
    #expect(session.memory.points.last?.value == nil)
    #expect(session.state == .running)
    #expect(harness.statsCalls == 1)
  }

  @Test func aMissingMemoryReadingIsAGapInTheMemorySeriesOnly() async {
    let noMemory = ContainerStatsSample(
      cpuTotalUsage: 150, previousCPUTotalUsage: 100,
      systemCPUUsage: 1100, previousSystemCPUUsage: 1000,
      onlineCPUs: 2, memoryUsage: nil, memoryInactiveFile: nil
    )
    let harness = Harness(stats: .success(noMemory))
    let task = harness.start()

    await harness.waitForPoints(1)
    task.cancel()
    await task.value

    #expect(harness.session.cpu.points.map(\.value) == [100])
    #expect(harness.session.memory.points.map(\.value) == [nil])
  }

  @Test func cancellingWhileStatsAreInFlightAddsNoGapAndKeepsTheState() async {
    let harness = Harness(stats: .failure(.timedOut))
    let gate = ArrivalGate()
    harness.engine.configure { config in
      config.beforeReturn = { call in if call == .containerStats(web) { await gate.pass() } }
    }
    let task = harness.start()

    await gate.waitForArrivals(1)
    task.cancel()
    await task.value

    #expect(harness.statsCalls == 1)
    #expect(harness.session.state == .running)
    #expect(harness.session.cpu.points.isEmpty)
    #expect(harness.session.memory.points.isEmpty)
  }

  @Test func aCancelledInspectChangesNothing() async {
    let harness = Harness()
    let gate = ArrivalGate()
    harness.engine.configure { config in
      config.beforeReturn = { call in if call == .inspectContainer(web) { await gate.pass() } }
    }
    let task = harness.start()

    await gate.waitForArrivals(1)
    task.cancel()
    await task.value

    #expect(harness.statsCalls == 0)
    #expect(harness.session.state == .starting)
    #expect(harness.session.cpu.points.isEmpty)
  }

  @Test func aCancelledResultFromTheEngineAddsNoGap() async {
    let harness = Harness(stats: .failure(.cancelled))
    let gate = ArrivalGate(blocking: 0)
    harness.engine.configure { config in
      config.beforeReturn = { call in if call == .containerStats(web) { await gate.pass() } }
    }
    let task = harness.start()

    await gate.waitForArrivals(1)
    task.cancel()
    await task.value

    #expect(harness.session.cpu.points.isEmpty)
    #expect(harness.session.state == .running)
  }

  @Test func theViewStopsPollingWhenItsTaskIsCancelled() async {
    let harness = Harness()
    let task = harness.start()
    await harness.waitForPoints(1)

    task.cancel()
    await task.value
    harness.clock.advance(by: .seconds(30))

    #expect(harness.statsCalls == 1)
    #expect(harness.inspectCalls == 1)
    #expect(harness.clock.sleeperCount == 0)
  }

  @Test func aSessionRunsOnce() async {
    let harness = Harness(running: false)
    let task = harness.start()
    let session = harness.session
    await harness.wait { session.state == .notRunning }
    task.cancel()
    await task.value
    let before = harness.engine.calls.count

    await harness.session.run(clock: harness.clock)

    #expect(harness.engine.calls.count == before)
  }
}
