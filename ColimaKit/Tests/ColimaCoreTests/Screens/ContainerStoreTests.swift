import Foundation
import Synchronization
import Testing

@testable import ColimaCore

private func cid(_ name: String) -> ContainerID { ContainerID(rawValue: "id-\(name)") }

private func container(_ name: String, running: Bool = true, project: String? = nil)
  -> ContainerSummary
{
  ContainerSummary(
    id: cid(name),
    name: name,
    image: "img",
    state: ContainerState(dockerState: running ? "running" : "exited"),
    ports: [],
    labels: project.map { [ComposeGrouping.projectLabel: $0] } ?? [:],
    networkNames: []
  )
}

private func detail(_ name: String, running: Bool) -> Result<ContainerDetail, DockerError> {
  .success(ContainerDetail(id: cid(name), hasTTY: false, isRunning: running, networkNames: []))
}

private func at(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let engine = FakeDockerEngine()
  let clock = ManualClock()
  let rounds = RoundCounter()
  let slots = ContainerOperationSlots()
  let controller: VMController
  let store: ContainerStore

  init(containers: [ContainerSummary] = []) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure { $0.listDefault = [.success(.present(instance(running: true)))] }
    engine.configure { $0.containers = .success(containers) }
    store = ContainerStore(engine: engine, controller: controller, slots: slots)
  }

  func startMonitor() -> Task<Void, Never> {
    let store = store
    let clock = clock
    let rounds = rounds
    return Task { await store.monitor(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  func makeReady() async {
    await controller.redetectToolchain()
    #expect(controller.dockerAvailability == .ready)
  }

  func stopVM() async {
    cli.configure { $0.listDefault = [.success(.present(instance(running: false)))] }
    await controller.refreshNow()
    #expect(controller.dockerAvailability == .vmStopped)
  }

  func holdActions(with gate: ArrivalGate) {
    engine.configure {
      $0.beforeReturn = { call in
        if case .perform = call { await gate.pass() }
      }
    }
  }

  func count(_ matches: (FakeDockerEngine.Call) -> Bool) -> Int {
    engine.calls.count(where: matches)
  }

  var listCalls: Int { count { $0 == .listContainers } }
  var performCalls: Int { count { if case .perform = $0 { true } else { false } } }
  var removeCalls: Int { count { if case .removeContainer = $0 { true } else { false } } }
  var inspectCalls: Int { count { if case .inspectContainer = $0 { true } else { false } } }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContainerStoreTests {

  // MARK: List

  @Test func refreshFillsTheListAndGroupsIt() async {
    let harness = Harness(containers: [
      container("web", project: "shop"), container("db", running: false, project: "shop"),
      container("solo"),
    ])
    await harness.makeReady()

    await harness.store.refresh()

    #expect(harness.store.containers.value?.count == 3)
    #expect(harness.store.groups.projects.map(\.name) == ["shop"])
    #expect(harness.store.groups.projects.first?.state == .partiallyRunning)
    #expect(harness.store.groups.ungrouped.map(\.name) == ["solo"])
  }

  @Test func nothingIsFetchedWhileDockerIsNotReady() async {
    let harness = Harness(containers: [container("web", project: "shop")])
    await harness.makeReady()
    await harness.store.refresh()
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    await harness.store.refresh()
    let accepted = harness.store.perform(.start, on: cid("web"))
    let projectAccepted = harness.store.performProject(.stop, on: "shop")
    await harness.store.awaitOperations()

    #expect(!accepted)
    #expect(!projectAccepted)
    #expect(harness.engine.calls == callsBefore)
    #expect(harness.slots.busyIDs.isEmpty)
  }

  @Test func monitorPollsEveryThreeSecondsAndStopsWhenCancelled() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    let clock = harness.clock
    let task = harness.startMonitor()

    await harness.rounds.waitForRounds(1)
    #expect(harness.listCalls == 1)
    await clock.waitForSleeper(until: at(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.listCalls == 2)
    task.cancel()
    await task.value
    clock.advance(by: .seconds(30))

    #expect(harness.listCalls == 2)
  }

  @Test func monitorFetchesNothingWhileDockerIsNotReady() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    await harness.stopVM()
    let clock = harness.clock
    let task = harness.startMonitor()

    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: at(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    task.cancel()
    await task.value

    #expect(harness.listCalls == 0)
  }

  @Test func aFailedRefreshKeepsThePreviousListAndShowsTheError() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    await harness.store.refresh()

    harness.engine.configure { $0.containers = .failure(.timedOut) }
    await harness.store.refresh()

    #expect(harness.store.containers.value?.map(\.name) == ["web"])
    #expect(harness.store.containers.error == .timedOut)
    #expect(!harness.store.containers.isRefreshing)
  }

  @Test func aSlowEarlierRefreshDoesNotOverwriteALaterOne() async {
    let harness = Harness()
    await harness.makeReady()
    let gate = ArrivalGate()
    let engine = harness.engine
    let older = [container("old")]
    let newer = [container("new")]
    let started = Mutex(0)
    engine.configure {
      $0.beforeReturn = { call in
        guard call == .listContainers else { return }
        let number = started.withLock {
          $0 += 1
          return $0
        }
        if number == 1 {
          await gate.pass()
          engine.configure { $0.containers = .success(older) }
        } else {
          engine.configure { $0.containers = .success(newer) }
        }
      }
    }
    let store = harness.store
    let slow = Task { await store.refresh() }
    await gate.waitForArrivals(1)

    await store.refresh()
    gate.open()
    await slow.value

    #expect(store.containers.value?.map(\.name) == ["new"])
  }

  // MARK: Single operations

  @Test func aStartRunsTheActionThenRefreshesAndReleasesTheSlot() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()

    let accepted = harness.store.perform(.start, on: cid("web"))
    #expect(harness.slots.isBusy(cid("web")))
    await harness.store.awaitOperations()

    #expect(accepted)
    #expect(
      harness.engine.calls == [.listContainers, .perform(.start, cid("web")), .listContainers])
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.store.operationFailures.isEmpty)
  }

  @Test func aSecondOperationOnABusyContainerIsRejected() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.holdActions(with: gate)

    #expect(harness.store.perform(.stop, on: cid("web")))
    await gate.waitForArrivals(1)
    let duplicate = harness.store.perform(.restart, on: cid("web"))
    gate.open()
    await harness.store.awaitOperations()

    #expect(!duplicate)
    #expect(harness.engine.calls.contains(.perform(.stop, cid("web"))))
    #expect(harness.performCalls == 1)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  @Test func anOperationHeldByAnotherScreenIsRejected() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    #expect(harness.slots.reserve(cid("web")))

    #expect(!harness.store.perform(.stop, on: cid("web")))

    #expect(harness.performCalls == 0)
    #expect(harness.slots.isBusy(cid("web")))
  }

  @Test func aFailedOperationShowsTheEngineMessageAndRefreshesTheList() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    harness.engine.configure {
      $0.containerActionFailures[cid("web")] = .api(
        status: 500, message: "port is already allocated")
    }

    harness.store.perform(.start, on: cid("web"))
    await harness.store.awaitOperations()

    #expect(harness.store.operationFailures[cid("web")]?.message == "port is already allocated")
    #expect(harness.store.operationFailures[cid("web")]?.operation == .action(.start))
    #expect(harness.listCalls == 1)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  @Test func aNewOperationClearsThePreviousFailureOfThatContainer() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    harness.engine.configure { $0.containerActionFailures[cid("web")] = .timedOut }
    harness.store.perform(.start, on: cid("web"))
    await harness.store.awaitOperations()
    #expect(harness.store.operationFailures[cid("web")] != nil)

    harness.engine.configure { $0.containerActionFailures = [:] }
    harness.store.perform(.start, on: cid("web"))
    await harness.store.awaitOperations()

    #expect(harness.store.operationFailures.isEmpty)
  }

  @Test func anOperationOutlivesTheMonitoringTask() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.holdActions(with: gate)
    let store = harness.store
    let monitoring = harness.startMonitor()
    await harness.rounds.waitForRounds(1)

    store.perform(.restart, on: cid("web"))
    await gate.waitForArrivals(1)
    monitoring.cancel()
    await monitoring.value
    let listsBefore = harness.listCalls
    gate.open()
    await store.awaitOperations()

    #expect(harness.listCalls == listsBefore + 1)
    #expect(harness.store.operationFailures.isEmpty)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  // MARK: Delete

  @Test func deletingARunningContainerGivesStopGuidanceAndNoConfirmation() async {
    let harness = Harness(containers: [container("web")])
    await harness.makeReady()
    await harness.store.refresh()

    let availability = harness.store.requestDelete(cid("web"))

    #expect(availability == .mustStopFirst)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls == 0)
  }

  @Test func deletingAStoppedContainerAsksForConfirmationWithoutDeleting() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()

    let availability = harness.store.requestDelete(cid("web"))

    #expect(availability == .confirmationRequested)
    let request = harness.store.pendingConfirmation
    #expect(request?.intent == .deleteContainer(cid("web")))
    #expect(request?.origin == .window)
    #expect(request?.itemGroups.flatMap(\.items) == ["web"])
    #expect(harness.removeCalls == 0)
    #expect(harness.inspectCalls == 0)
  }

  @Test func deleteIsNotOfferedForABusyContainerOrWhileDockerIsNotReady() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    #expect(harness.slots.reserve(cid("web")))

    #expect(harness.store.requestDelete(cid("web")) == .busy)
    #expect(harness.store.pendingConfirmation == nil)

    harness.slots.release(cid("web"))
    await harness.stopVM()
    #expect(harness.store.requestDelete(cid("web")) == .busy)
    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func approvingDeletesOnceWithoutForceAfterCheckingItIsStopped() async throws {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.engine.configure { $0.containerDetails[cid("web")] = detail("web", running: false) }
    harness.store.requestDelete(cid("web"))
    let id = try #require(harness.store.pendingConfirmation?.id)

    let outcome = harness.store.confirm(id: id)
    #expect(harness.slots.isBusy(cid("web")))
    let again = harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(again == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(
      harness.engine.calls == [
        .listContainers, .inspectContainer(cid("web")), .removeContainer(cid("web")),
        .listContainers,
      ])
    #expect(!harness.slots.isBusy(cid("web")))
  }

  @Test func approvingWhenTheContainerStartedMeanwhileDoesNotDelete() async throws {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.store.requestDelete(cid("web"))
    harness.engine.configure { $0.containerDetails[cid("web")] = detail("web", running: true) }
    let id = try #require(harness.store.pendingConfirmation?.id)

    #expect(harness.store.confirm(id: id) == .started)
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == 0)
    let failure = harness.store.operationFailures[cid("web")]
    #expect(failure?.operation == .delete)
    #expect(failure?.message.contains("Stop it first") == true)
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.listCalls == 2)
  }

  @Test func approvingForABusyContainerIsRejectedAndTheRequestIsDiscarded() async throws {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.store.requestDelete(cid("web"))
    let id = try #require(harness.store.pendingConfirmation?.id)
    #expect(harness.slots.reserve(cid("web")))
    let removalsBefore = harness.removeCalls
    let inspectsBefore = harness.inspectCalls

    let outcome = harness.store.confirm(id: id)

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls == removalsBefore)
    #expect(harness.inspectCalls == inspectsBefore)
    #expect(harness.slots.isBusy(cid("web")))
    #expect(harness.store.confirm(id: id) == .notPending)
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndNothingRuns() async throws {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.engine.configure { $0.containerDetails[cid("web")] = detail("web", running: false) }
    harness.store.requestDelete(cid("web"))
    let id = try #require(harness.store.pendingConfirmation?.id)
    await harness.stopVM()

    let outcome = harness.store.confirm(id: id)

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    await harness.store.awaitOperations()
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.inspectCalls == 0)
    #expect(harness.removeCalls == 0)
    #expect(harness.slots.busyIDs.isEmpty)
  }

  @Test func aMismatchedIDKeepsThePendingRequestAndAReplacedRequestCannotBeApproved() async throws {
    let harness = Harness(containers: [
      container("web", running: false), container("db", running: false),
    ])
    await harness.makeReady()
    await harness.store.refresh()

    harness.store.requestDelete(cid("web"))
    let first = try #require(harness.store.pendingConfirmation?.id)
    #expect(harness.store.confirm(id: UUID()) == .notPending)
    #expect(harness.store.pendingConfirmation?.id == first)

    harness.store.requestDelete(cid("db"))
    #expect(harness.store.confirm(id: first) == .notPending)
    #expect(harness.store.pendingConfirmation?.intent == .deleteContainer(cid("db")))
    #expect(harness.removeCalls == 0)
  }

  @Test func dismissingDropsThePendingRequest() async {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.store.requestDelete(cid("web"))

    harness.store.dismissConfirmation()

    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func aFailedDeleteShowsTheEngineMessage() async throws {
    let harness = Harness(containers: [container("web", running: false)])
    await harness.makeReady()
    await harness.store.refresh()
    harness.engine.configure {
      $0.containerDetails[cid("web")] = detail("web", running: false)
      $0.containerRemovalFailures[cid("web")] = .api(
        status: 409, message: "removal already in progress")
    }
    harness.store.requestDelete(cid("web"))
    let id = try #require(harness.store.pendingConfirmation?.id)

    harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    #expect(harness.store.operationFailures[cid("web")]?.message == "removal already in progress")
    #expect(harness.store.operationFailures[cid("web")]?.operation == .delete)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  // MARK: Compose projects

  private func shopHarness(members: Int) async -> Harness {
    let harness = Harness(
      containers: (0..<members).map { container("m\($0)", running: false, project: "shop") })
    await harness.makeReady()
    await harness.store.refresh()
    return harness
  }

  @Test func aProjectOperationRunsAtMostFourMembersAtOnce() async throws {
    let harness = await shopHarness(members: 6)
    let gate = ArrivalGate(blocking: 4)
    let inFlight = Mutex((now: 0, peak: 0))
    harness.engine.configure {
      $0.beforeReturn = { call in
        guard case .perform = call else { return }
        inFlight.withLock {
          $0.now += 1
          $0.peak = max($0.peak, $0.now)
        }
        await gate.pass()
        inFlight.withLock { $0.now -= 1 }
      }
    }

    #expect(harness.store.performProject(.start, on: "shop"))
    await gate.waitForArrivals(4)
    #expect(harness.performCalls == 4)
    #expect(harness.slots.busyIDs.count == 6)
    gate.open()
    await harness.store.awaitOperations()

    #expect(harness.performCalls == 6)
    #expect(inFlight.withLock { $0.peak } == 4)
    let outcome = try #require(harness.store.projectOutcomes["shop"])
    #expect(outcome.succeeded == (0..<6).map { cid("m\($0)") })
    #expect(outcome.failed.isEmpty)
    #expect(harness.slots.busyIDs.isEmpty)
    #expect(harness.listCalls == 2)
  }

  @Test func aPartialFailureKeepsTheSuccessesAndRecordsBusyAndFailedMembers() async throws {
    let harness = await shopHarness(members: 4)
    #expect(harness.slots.reserve(cid("m1")))
    harness.engine.configure {
      $0.containerActionFailures[cid("m2")] = .api(status: 500, message: "cannot stop container")
    }

    #expect(harness.store.performProject(.stop, on: "shop"))
    await harness.store.awaitOperations()

    let outcome = try #require(harness.store.projectOutcomes["shop"])
    #expect(outcome.succeeded == [cid("m0"), cid("m3")])
    #expect(outcome.failed[cid("m2")] == "cannot stop container")
    #expect(outcome.failed[cid("m1")]?.contains("busy with another operation") == true)
    #expect(outcome.failed.count == 2)
    #expect(!harness.engine.calls.contains(.perform(.stop, cid("m1"))))
    #expect(harness.slots.busyIDs == [cid("m1")])
    #expect(harness.listCalls == 2)
  }

  @Test func projectMembersAreFixedWhenTheOperationStarts() async throws {
    let harness = await shopHarness(members: 6)
    let gate = ArrivalGate(blocking: 4)
    harness.holdActions(with: gate)
    harness.store.performProject(.restart, on: "shop")
    await gate.waitForArrivals(4)

    harness.engine.configure {
      $0.containers = .success([
        container("m0", project: "shop"), container("late", project: "shop"),
      ])
    }
    await harness.store.refresh()
    gate.open()
    await harness.store.awaitOperations()

    let performed = harness.engine.calls.compactMap { call -> ContainerID? in
      if case .perform(_, let id) = call { id } else { nil }
    }
    #expect(Set(performed) == Set((0..<6).map { cid("m\($0)") }))
    #expect(!performed.contains(cid("late")))
    #expect(try #require(harness.store.projectOutcomes["shop"]).succeeded.count == 6)
  }

  @Test func aProjectThatIsNotListedIsNotAccepted() async {
    let harness = await shopHarness(members: 2)
    let callsBefore = harness.engine.calls

    #expect(!harness.store.performProject(.start, on: "other"))

    #expect(harness.engine.calls == callsBefore)
    #expect(harness.store.projectOutcomes.isEmpty)
  }

  @Test func aNewProjectOperationReplacesThePreviousOutcome() async throws {
    let harness = await shopHarness(members: 2)
    harness.engine.configure { $0.containerActionFailures[cid("m0")] = .timedOut }
    harness.store.performProject(.start, on: "shop")
    await harness.store.awaitOperations()
    #expect(try #require(harness.store.projectOutcomes["shop"]).failed.count == 1)

    harness.engine.configure { $0.containerActionFailures = [:] }
    harness.store.performProject(.start, on: "shop")
    await harness.store.awaitOperations()

    #expect(try #require(harness.store.projectOutcomes["shop"]).failed.isEmpty)
  }
}
