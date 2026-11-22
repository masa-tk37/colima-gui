import Foundation
import Testing

@testable import ColimaCore

private func nid(_ name: String) -> NetworkID { NetworkID(rawValue: "id-\(name)") }
private func cid(_ name: String) -> ContainerID { ContainerID(rawValue: "c-\(name)") }

private func network(_ name: String, id: NetworkID? = nil) -> NetworkSummary {
  NetworkSummary(id: id ?? nid(name), name: name, driver: "bridge", scope: "local", ipam: [])
}

private func builtIn(_ name: String) -> NetworkSummary {
  network(name, id: NetworkID(rawValue: "hash-\(name)"))
}

private func detail(of name: String, containers: [String]) -> Result<NetworkDetail, DockerError> {
  .success(
    NetworkDetail(
      id: nid(name), name: name,
      containers: containers.map {
        NetworkContainer(id: cid($0), name: $0, ipv4Address: "172.18.0.2/16", ipv6Address: nil)
      }
    ))
}

@MainActor
private final class ListNotices {
  private(set) var count = 0
  func record() { count += 1 }
}

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let engine = FakeDockerEngine()
  let slots = ContainerOperationSlots()
  let notices = ListNotices()
  let controller: VMController
  let store: NetworkStore

  init(networks: [NetworkSummary] = [], dangling: [NetworkSummary] = []) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure { $0.listDefault = [.success(.present(instance(running: true)))] }
    engine.configure {
      $0.networks = .success(networks)
      $0.danglingNetworks = .success(dangling)
    }
    let notices = notices
    store = NetworkStore(
      engine: engine, controller: controller, slots: slots,
      containerListDidChange: { notices.record() }
    )
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

  var removeCalls: [NetworkID] {
    engine.calls.compactMap { if case .removeNetwork(let id) = $0 { id.id } else { nil } }
  }
  var connectCalls: [NetworkMembership] {
    engine.calls.compactMap {
      if case .connect(let container, let network) = $0 {
        .init(container: container, network: network)
      } else {
        nil
      }
    }
  }
  var disconnectCalls: [NetworkMembership] {
    engine.calls.compactMap {
      if case .disconnect(let container, let network) = $0 {
        .init(container: container, network: network)
      } else {
        nil
      }
    }
  }
  var inspectCalls: Int {
    engine.calls.count { if case .inspectNetwork = $0 { true } else { false } }
  }
  var listCalls: Int { engine.calls.count { $0 == .listNetworks(danglingOnly: false) } }

  func pruneRequest() async throws -> ConfirmationRequest {
    let result = await store.requestPrune()
    #expect(result == .confirmationRequested)
    return try #require(store.pendingConfirmation)
  }

  func disconnectRequest(_ container: String, from name: String) throws -> ConfirmationRequest {
    #expect(store.requestDisconnect(container: cid(container), from: nid(name)))
    return try #require(store.pendingConfirmation)
  }
}

private func expectRejected(
  _ outcome: ConfirmationOutcome, sourceLocation: SourceLocation = #_sourceLocation
) {
  guard case .rejectedBusy = outcome else {
    Issue.record("expected .rejectedBusy, got \(outcome)", sourceLocation: sourceLocation)
    return
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NetworkStorePruneTests {

  // MARK: Prune request

  @Test func noCandidatesCreatesNoConfirmationAndDeletesNothing() async {
    let harness = Harness(networks: [network("app")], dangling: [])
    await harness.makeReady()

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == [.listNetworks(danglingOnly: true)])
    #expect(harness.store.pruneRequestError == nil)
  }

  @Test func onlyBuiltInCandidatesCountAsNone() async {
    let harness = Harness(dangling: [builtIn("bridge"), builtIn("host"), builtIn("none")])
    await harness.makeReady()

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func builtInCandidatesAreLeftOutOfTheRequest() async throws {
    let harness = Harness(dangling: [builtIn("bridge"), network("app"), network("db")])
    await harness.makeReady()

    let request = try await harness.pruneRequest()

    #expect(
      request.intent
        == .pruneNetworks(ids: [network("app").deletableID!, network("db").deletableID!]))
    #expect(request.itemGroups.flatMap(\.items) == ["app", "db"])
    #expect(request.origin == .window)
    #expect(request.title.contains("2"))
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func theBodyStatesThatStoppedContainersReferencesAreDeletedToo() async throws {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()

    let request = try await harness.pruneRequest()

    #expect(request.message.contains("stopped containers"))
    #expect(request.message.contains("no running container is connected to"))
  }

  @Test func nothingIsRequestedWhileDockerIsNotReady() async {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    await harness.stopVM()

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls.isEmpty)
  }

  @Test func anUnreadableCandidateListIsReportedAndRequestsNothing() async {
    let harness = Harness()
    harness.engine.configure { $0.danglingNetworks = .failure(.api(status: 500, message: "boom")) }
    await harness.makeReady()

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.pruneRequestError == "boom")
  }

  @Test func dockerStoppingWhileTheCandidatesAreReadMakesNoRequest() async {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.engine.configure { $0.beforeReturn = { _ in await gate.pass() } }

    async let result = harness.store.requestPrune()
    await gate.waitForArrivals(1)
    await harness.stopVM()
    gate.open()

    #expect(await result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
  }

  // MARK: Prune approval

  @Test func approvingDeletesExactlyTheConfirmedCandidatesOneByOne() async throws {
    let harness = Harness(
      networks: [network("app"), network("db")], dangling: [network("app"), network("db")])
    await harness.makeReady()
    let request = try await harness.pruneRequest()
    harness.engine.configure {
      $0.danglingNetworks = .success([network("app"), network("db"), network("late")])
    }

    let outcome = harness.store.confirm(id: request.id)
    #expect(harness.store.isPruning)
    #expect(harness.store.removing == [nid("app"), nid("db")])
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(harness.removeCalls == [nid("app"), nid("db")])
    #expect(
      harness.store.lastPruneOutcome
        == BatchOutcome(succeeded: [nid("app"), nid("db")], failed: [:]))
    #expect(!harness.store.isPruning)
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.listCalls == 1)
  }

  @Test func aFailingItemIsReportedAndTheRestIsStillDeleted() async throws {
    let harness = Harness(dangling: [network("a"), network("b"), network("c")])
    harness.engine.configure {
      $0.networkRemovalFailures[nid("b")] = .api(status: 403, message: "has active endpoints")
    }
    await harness.makeReady()
    let request = try await harness.pruneRequest()

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == [nid("a"), nid("b"), nid("c")])
    #expect(
      harness.store.lastPruneOutcome
        == BatchOutcome(
          succeeded: [nid("a"), nid("c")], failed: [nid("b"): "has active endpoints"]
        ))
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndDeletesNothing() async throws {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    let request = try await harness.pruneRequest()
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    let outcome = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    expectRejected(outcome)
    #expect(harness.store.confirm(id: request.id) == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.lastPruneOutcome == nil)
    #expect(!harness.store.isPruning)
    #expect(harness.engine.calls == callsBefore)
  }

  @Test func aSecondApprovalOfTheSamePruneDeletesOnce() async throws {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    let request = try await harness.pruneRequest()

    let first = harness.store.confirm(id: request.id)
    let second = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(first == .started)
    #expect(second == .notPending)
    #expect(harness.removeCalls == [nid("app")])
  }

  @Test func noPruneIsRequestedWhileOneRuns() async throws {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    let request = try await harness.pruneRequest()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in if case .removeNetwork = call { await gate.pass() } }
    }

    #expect(harness.store.confirm(id: request.id) == .started)
    await gate.waitForArrivals(1)
    let result = await harness.store.requestPrune()
    gate.open()
    await harness.store.awaitOperations()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls == [nid("app")])
  }

  @Test func aPruneOverlappingARunningDeletionIsRejected() async throws {
    let harness = Harness(networks: [network("app")], dangling: [network("app")])
    await harness.makeReady()
    #expect(harness.store.requestDelete(network("app")))
    let deletion = try #require(harness.store.pendingConfirmation)
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in if case .removeNetwork = call { await gate.pass() } }
    }
    #expect(harness.store.confirm(id: deletion.id) == .started)
    await gate.waitForArrivals(1)
    let prune = try await harness.pruneRequest()

    expectRejected(harness.store.confirm(id: prune.id))
    gate.open()
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == [nid("app")])
    #expect(harness.store.lastPruneOutcome == nil)
    #expect(!harness.store.isPruning)
  }

  @Test func aPrunedSelectedNetworkIsDeselected() async throws {
    let harness = Harness(networks: [network("app")], dangling: [network("app")])
    harness.engine.configure { $0.networkDetails[nid("app")] = detail(of: "app", containers: []) }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let request = try await harness.pruneRequest()

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.store.selectedID == nil)
  }

  @Test func aNewPruneRequestClearsThePreviousOutcome() async throws {
    let harness = Harness(dangling: [network("app")])
    await harness.makeReady()
    let request = try await harness.pruneRequest()
    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()
    #expect(harness.store.lastPruneOutcome != nil)

    harness.engine.configure { $0.danglingNetworks = .success([]) }
    _ = await harness.store.requestPrune()

    #expect(harness.store.lastPruneOutcome == nil)
  }

  // MARK: Connect

  @Test func connectingHoldsTheContainerSlotThenFetchesTheDetailAndNotifies() async {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure { $0.networkDetails[nid("app")] = detail(of: "app", containers: []) }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let inspectsBefore = harness.inspectCalls
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in if case .connect = call { await gate.pass() } }
    }

    let accepted = harness.store.connect(container: cid("web"), to: nid("app"))
    #expect(accepted)
    #expect(harness.slots.isBusy(cid("web")))
    await gate.waitForArrivals(1)
    #expect(harness.notices.count == 0)
    gate.open()
    await harness.store.awaitOperations()

    #expect(harness.connectCalls == [.init(container: cid("web"), network: nid("app"))])
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.inspectCalls == inspectsBefore + 1)
    #expect(harness.notices.count == 1)
    #expect(harness.store.connectionFailures.isEmpty)
  }

  @Test func connectingABusyContainerIsRefusedAndTouchesNothing() async {
    let harness = Harness()
    await harness.makeReady()
    #expect(harness.slots.reserve(cid("web")))

    let accepted = harness.store.connect(container: cid("web"), to: nid("app"))
    await harness.store.awaitOperations()

    #expect(!accepted)
    #expect(harness.slots.isBusy(cid("web")))
    #expect(harness.engine.calls.isEmpty)
    #expect(harness.notices.count == 0)
  }

  @Test func connectingWhileDockerIsNotReadyIsRefused() async {
    let harness = Harness()
    await harness.makeReady()
    await harness.stopVM()

    let accepted = harness.store.connect(container: cid("web"), to: nid("app"))

    #expect(!accepted)
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.engine.calls.isEmpty)
  }

  @Test func aFailedConnectShowsTheEngineMessageOnThatPairAndStillRefreshes() async {
    let message = "container web is already attached"
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.connectFailures[.init(container: cid("web"), network: nid("app"))] = .api(
        status: 403, message: message)
    }
    await harness.makeReady()

    harness.store.connect(container: cid("web"), to: nid("app"))
    await harness.store.awaitOperations()

    #expect(
      harness.store.connectionFailures == [
        NetworkMembership(container: cid("web"), network: nid("app")): message
      ])
    #expect(
      harness.store.connectionFailures[
        NetworkMembership(container: cid("web"), network: nid("other"))] == nil)
    #expect(harness.listCalls == 1)
    #expect(harness.notices.count == 1)
    #expect(!harness.slots.isBusy(cid("web")))

    harness.engine.configure { $0.connectFailures = [:] }
    harness.store.connect(container: cid("web"), to: nid("app"))
    await harness.store.awaitOperations()
    #expect(harness.store.connectionFailures.isEmpty)
  }

  // MARK: Disconnect

  @Test func requestingADisconnectAsksFirstAndCallsNothing() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkDetails[nid("app")] = detail(of: "app", containers: ["web"])
    }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let callsBefore = harness.engine.calls

    let request = try harness.disconnectRequest("web", from: "app")

    #expect(request.intent == .disconnect(container: cid("web"), network: nid("app")))
    #expect(request.origin == .window)
    #expect(request.title.contains("web"))
    #expect(request.title.contains("app"))
    #expect(harness.engine.calls == callsBefore)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  @Test func noDisconnectIsRequestedForABusyContainerOrWhileDockerIsNotReady() async {
    let harness = Harness()
    await harness.makeReady()
    #expect(harness.slots.reserve(cid("web")))

    #expect(!harness.store.requestDisconnect(container: cid("web"), from: nid("app")))
    harness.slots.release(cid("web"))
    await harness.stopVM()
    #expect(!harness.store.requestDisconnect(container: cid("web"), from: nid("app")))
    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func approvingADisconnectHoldsTheSlotThenFetchesTheDetailAndNotifies() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkDetails[nid("app")] = detail(of: "app", containers: ["web"])
    }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let request = try harness.disconnectRequest("web", from: "app")
    let inspectsBefore = harness.inspectCalls
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in if case .disconnect = call { await gate.pass() } }
    }

    let outcome = harness.store.confirm(id: request.id)
    #expect(harness.slots.isBusy(cid("web")))
    await gate.waitForArrivals(1)
    #expect(!harness.store.requestDisconnect(container: cid("web"), from: nid("app")))
    gate.open()
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(harness.disconnectCalls == [.init(container: cid("web"), network: nid("app"))])
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.inspectCalls == inspectsBefore + 1)
    #expect(harness.notices.count == 1)
    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func approvingADisconnectOfABusyContainerIsRejectedAndLeavesTheSlotAlone() async throws {
    let harness = Harness()
    await harness.makeReady()
    let request = try harness.disconnectRequest("web", from: "app")
    #expect(harness.slots.reserve(cid("web")))

    let outcome = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    expectRejected(outcome)
    #expect(harness.store.confirm(id: request.id) == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.slots.isBusy(cid("web")))
    #expect(harness.engine.calls.isEmpty)
    #expect(harness.notices.count == 0)
  }

  @Test func approvingADisconnectAfterDockerStoppedBeingReadyIsRejected() async throws {
    let harness = Harness()
    await harness.makeReady()
    let request = try harness.disconnectRequest("web", from: "app")
    await harness.stopVM()

    let outcome = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    expectRejected(outcome)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(!harness.slots.isBusy(cid("web")))
    #expect(harness.engine.calls.isEmpty)
    #expect(harness.notices.count == 0)
  }

  @Test func aFailedDisconnectShowsTheEngineMessageAndStillRefreshes() async throws {
    let message = "endpoint not found"
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.disconnectFailures[.init(container: cid("web"), network: nid("app"))] = .api(
        status: 404, message: message)
    }
    await harness.makeReady()
    let request = try harness.disconnectRequest("web", from: "app")

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(
      harness.store.connectionFailures == [
        NetworkMembership(container: cid("web"), network: nid("app")): message
      ])
    #expect(harness.listCalls == 1)
    #expect(harness.notices.count == 1)
    #expect(!harness.slots.isBusy(cid("web")))
  }

  @Test func aDeleteRequestIsStillHandledByTheSameConfirm() async throws {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    #expect(harness.store.requestDelete(network("app")))
    let request = try #require(harness.store.pendingConfirmation)

    #expect(harness.store.confirm(id: request.id) == .started)
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == [nid("app")])
  }
}
