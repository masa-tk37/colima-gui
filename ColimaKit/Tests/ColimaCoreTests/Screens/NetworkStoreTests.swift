import Foundation
import Testing

@testable import ColimaCore

private func nid(_ name: String) -> NetworkID { NetworkID(rawValue: "id-\(name)") }

private func network(_ name: String, id: NetworkID? = nil, subnet: String? = nil) -> NetworkSummary
{
  NetworkSummary(
    id: id ?? nid(name), name: name, driver: "bridge", scope: "local",
    ipam: subnet.map { [IPAMConfig(subnet: $0, gateway: nil)] } ?? []
  )
}

private func builtIns() -> [NetworkSummary] {
  ["bridge", "host", "none"].map { network($0, id: NetworkID(rawValue: "hash-\($0)")) }
}

private func detail(of name: String, containers: [String] = []) -> Result<
  NetworkDetail, DockerError
> {
  .success(
    NetworkDetail(
      id: nid(name), name: name,
      containers: containers.map {
        NetworkContainer(
          id: ContainerID(rawValue: "c-\($0)"), name: $0, ipv4Address: "172.18.0.2/16",
          ipv6Address: nil)
      }
    ))
}

private func at(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

private let listNetworksCall = FakeDockerEngine.Call.listNetworks(danglingOnly: false)

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let engine = FakeDockerEngine()
  let clock = ManualClock()
  let rounds = RoundCounter()
  let slots = ContainerOperationSlots()
  let controller: VMController
  let store: NetworkStore

  init(networks: [NetworkSummary] = []) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure { $0.listDefault = [.success(.present(instance(running: true)))] }
    engine.configure { $0.networks = .success(networks) }
    store = NetworkStore(
      engine: engine, controller: controller, slots: slots, containerListDidChange: {}
    )
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

  func count(_ matches: (FakeDockerEngine.Call) -> Bool) -> Int {
    engine.calls.count(where: matches)
  }

  var listCalls: Int { count { $0 == listNetworksCall } }
  var inspectCalls: Int { count { if case .inspectNetwork = $0 { true } else { false } } }
  var removeCalls: [DeletableNetworkID] {
    engine.calls.compactMap { if case .removeNetwork(let id) = $0 { id } else { nil } }
  }
  var createCalls: [ValidatedNetworkCreate] {
    engine.calls.compactMap { if case .createNetwork(let request) = $0 { request } else { nil } }
  }

  func requestDeleteConfirmation(_ summary: NetworkSummary) throws -> ConfirmationRequest {
    #expect(store.requestDelete(summary))
    return try #require(store.pendingConfirmation)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NetworkStoreTests {

  // MARK: List and detail

  @Test func refreshShowsTheListWithItsFetchTime() async {
    let harness = Harness(networks: [network("app", subnet: "172.20.0.0/16"), network("db")])
    await harness.makeReady()

    await harness.store.refresh()

    #expect(harness.store.networks.value?.map(\.name) == ["app", "db"])
    #expect(harness.store.networks.value?.first?.ipam.first?.subnet == "172.20.0.0/16")
    #expect(harness.engine.calls == [listNetworksCall])
  }

  @Test func aFailedRefreshKeepsThePreviousListAndShowsTheError() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.store.refresh()

    harness.engine.configure { $0.networks = .failure(.timedOut) }
    await harness.store.refresh()

    #expect(harness.store.networks.value?.count == 1)
    #expect(harness.store.networks.error == .timedOut)
  }

  @Test func monitorFetchesTheListAndTheSelectedDetailEveryThreeSeconds() async {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkDetails[nid("app")] = detail(of: "app", containers: ["web"])
    }
    await harness.makeReady()
    let store = harness.store
    let clock = harness.clock
    store.select(nid("app"))
    await store.awaitOperations()
    let inspectsBefore = harness.inspectCalls
    let task = harness.startMonitor()

    await harness.rounds.waitForRounds(1)
    #expect(harness.listCalls == 1)
    #expect(harness.inspectCalls == inspectsBefore + 1)
    await clock.waitForSleeper(until: at(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.listCalls == 2)
    #expect(harness.inspectCalls == inspectsBefore + 2)
    task.cancel()
    await task.value
    clock.advance(by: .seconds(30))

    #expect(harness.listCalls == 2)
    #expect(store.detail.value?.containers.map(\.name) == ["web"])
  }

  @Test func monitorFetchesNothingWhileDockerIsNotReady() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.stopVM()
    let store = harness.store
    let clock = harness.clock
    store.select(nid("app"))
    await store.awaitOperations()
    let task = harness.startMonitor()

    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: at(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    task.cancel()
    await task.value

    #expect(harness.engine.calls.isEmpty)
  }

  @Test func monitorFetchesNoDetailWithoutASelection() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    let task = harness.startMonitor()

    await harness.rounds.waitForRounds(1)
    task.cancel()
    await task.value

    #expect(harness.listCalls == 1)
    #expect(harness.inspectCalls == 0)
  }

  @Test func selectingANetworkFetchesItsDetailAtOnce() async {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkDetails[nid("app")] = detail(of: "app", containers: ["web", "worker"])
    }
    await harness.makeReady()

    harness.store.select(nid("app"))
    await harness.store.awaitOperations()

    #expect(harness.store.selectedID == nid("app"))
    #expect(harness.store.detail.value?.containers.map(\.name) == ["web", "worker"])
    #expect(harness.store.detail.value?.containers.first?.ipv4Address == "172.18.0.2/16")
    #expect(harness.engine.calls == [.inspectNetwork(nid("app"))])
  }

  @Test func selectingNothingClearsTheDetail() async {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure { $0.networkDetails[nid("app")] = detail(of: "app") }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()

    harness.store.select(nil)
    await harness.store.refresh()

    #expect(harness.store.selectedID == nil)
    #expect(harness.store.detail.value == nil)
    #expect(harness.inspectCalls == 1)
  }

  @Test func aDetailArrivingAfterTheSelectionChangedIsNotShown() async {
    let harness = Harness(networks: [network("a"), network("b")])
    harness.engine.configure {
      $0.networkDetails[nid("a")] = detail(of: "a", containers: ["from-a"])
      $0.networkDetails[nid("b")] = detail(of: "b", containers: ["from-b"])
    }
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if call == .inspectNetwork(nid("a")) { await gate.pass() }
      }
    }
    await harness.makeReady()

    harness.store.select(nid("a"))
    await gate.waitForArrivals(1)
    harness.store.select(nid("b"))
    #expect(harness.store.detail.value == nil)
    gate.open()
    await harness.store.awaitOperations()

    #expect(harness.store.detail.value?.name == "b")
  }

  @Test func aFailedDetailKeepsTheErrorOnTheDetailOnly() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()

    #expect(harness.store.detail.error == .api(status: 404, message: "No such network: id-app"))
    #expect(harness.store.networks.error == nil)
  }

  // MARK: Create

  @Test func anInvalidFormIsRejectedPerFieldAndNeverReachesTheEngine() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.store.refresh()
    let callsBefore = harness.engine.calls

    let duplicate = await harness.store.createNetwork(NetworkCreateForm(name: "app", subnet: ""))
    let badSubnet = await harness.store.createNetwork(
      NetworkCreateForm(name: "new", subnet: "10.0.0.0/33"))
    let empty = await harness.store.createNetwork(NetworkCreateForm(name: "  ", subnet: ""))

    guard case .invalid(let duplicateFailure) = duplicate,
      case .invalid(let subnetFailure) = badSubnet,
      case .invalid(let emptyFailure) = empty
    else {
      Issue.record("expected .invalid, got \(duplicate) \(badSubnet) \(empty)")
      return
    }
    #expect(duplicateFailure.fields.map(\.field) == [.name])
    #expect(subnetFailure.fields.map(\.field) == [.subnet])
    #expect(emptyFailure.fields.map(\.field) == [.name])
    #expect(harness.store.createFieldErrors == emptyFailure.fields)
    #expect(harness.engine.calls == callsBefore)
  }

  @Test func aValidFormIsPassedOnValidatedAndTheListIsFetchedAgain() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure { $0.createdNetworkID = .success(nid("new")) }
    await harness.makeReady()
    await harness.store.refresh()
    harness.engine.configure {
      $0.networks = .success([network("app"), network("new", subnet: "172.30.0.0/16")])
    }

    let result = await harness.store.createNetwork(
      NetworkCreateForm(name: " new ", subnet: "172.30.0.0/16"))

    #expect(result == .created(nid("new")))
    let request = try #require(harness.createCalls.first)
    #expect(harness.createCalls.count == 1)
    #expect(request.name == "new")
    #expect(request.subnet?.cidr == "172.30.0.0/16")
    #expect(request.driver == "bridge")
    #expect(harness.listCalls == 2)
    #expect(harness.store.networks.value?.map(\.name) == ["app", "new"])
    #expect(harness.store.createFieldErrors.isEmpty)
    #expect(harness.store.createFailure == nil)
    #expect(!harness.store.isCreating)
  }

  @Test func aCreateWithoutASubnetPassesNone() async throws {
    let harness = Harness()
    await harness.makeReady()

    _ = await harness.store.createNetwork(NetworkCreateForm(name: "plain", subnet: ""))

    #expect(try #require(harness.createCalls.first).subnet == nil)
  }

  @Test func anEngineFailureOnCreateIsShownAndTheListIsFetchedAgain() async {
    let harness = Harness()
    harness.engine.configure {
      $0.createdNetworkID = .failure(
        .api(status: 403, message: "Pool overlaps with other one on this address space"))
    }
    await harness.makeReady()

    let result = await harness.store.createNetwork(
      NetworkCreateForm(name: "clash", subnet: "172.17.0.0/16"))

    #expect(result == .failed("Pool overlaps with other one on this address space"))
    #expect(harness.store.createFailure == "Pool overlaps with other one on this address space")
    #expect(harness.listCalls == 1)
    #expect(!harness.store.isCreating)
  }

  @Test func aNewCreateClearsThePreviousErrors() async {
    let harness = Harness()
    await harness.makeReady()
    _ = await harness.store.createNetwork(NetworkCreateForm(name: "", subnet: ""))
    #expect(!harness.store.createFieldErrors.isEmpty)

    let result = await harness.store.createNetwork(NetworkCreateForm(name: "ok", subnet: ""))

    #expect(result == .created(NetworkID(rawValue: "fake-network")))
    #expect(harness.store.createFieldErrors.isEmpty)
  }

  @Test func nothingIsCreatedWhileDockerIsNotReady() async {
    let harness = Harness()
    await harness.makeReady()
    await harness.stopVM()

    let result = await harness.store.createNetwork(NetworkCreateForm(name: "ok", subnet: ""))

    #expect(result == .unavailable)
    #expect(harness.engine.calls.isEmpty)
  }

  @Test func aSecondCreateWhileOneIsRunningIsRefused() async {
    let harness = Harness()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .createNetwork = call { await gate.pass() }
      }
    }
    await harness.makeReady()
    let store = harness.store
    let first = Task { await store.createNetwork(NetworkCreateForm(name: "one", subnet: "")) }
    await gate.waitForArrivals(1)

    let second = await store.createNetwork(NetworkCreateForm(name: "two", subnet: ""))
    gate.open()
    let firstResult = await first.value

    #expect(second == .busy)
    #expect(firstResult == .created(NetworkID(rawValue: "fake-network")))
    #expect(harness.createCalls.map(\.name) == ["one"])
  }

  @Test func cancellingTheCallerDoesNotCutACreateOff() async {
    let harness = Harness()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .createNetwork = call { await gate.pass() }
      }
    }
    await harness.makeReady()
    let store = harness.store
    let caller = Task { await store.createNetwork(NetworkCreateForm(name: "one", subnet: "")) }
    await gate.waitForArrivals(1)

    caller.cancel()
    gate.open()
    let result = await caller.value

    #expect(result == .created(NetworkID(rawValue: "fake-network")))
    #expect(harness.listCalls == 1)
  }

  // MARK: Delete

  @Test func builtInNetworksOfferNoDeleteAndCreateNoRequest() async {
    let harness = Harness(networks: builtIns())
    await harness.makeReady()
    await harness.store.refresh()
    let spoofed = network("custom", id: NetworkID(rawValue: "bridge"))

    for summary in (harness.store.networks.value ?? []) + [spoofed] {
      #expect(!harness.store.canDelete(summary))
      #expect(!harness.store.requestDelete(summary))
    }

    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func aCustomNetworkOffersDelete() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()

    #expect(harness.store.canDelete(network("app")))
  }

  @Test func requestingADeleteAsksFirstAndCallsNothing() async throws {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.store.refresh()
    let callsBefore = harness.engine.calls

    let request = try harness.requestDeleteConfirmation(network("app"))
    await harness.store.awaitOperations()

    #expect(request.intent == .deleteNetwork(network("app").deletableID!))
    #expect(request.origin == .window)
    #expect(request.itemGroups.flatMap(\.items) == ["app"])
    #expect(request.title.contains("app"))
    #expect(request.message.contains("connected containers"))
    #expect(harness.removeCalls.isEmpty)
    #expect(harness.engine.calls == callsBefore)
  }

  @Test func approvingDeletesTheConfirmedNetworkAndFetchesTheListAgain() async throws {
    let harness = Harness(networks: [network("app"), network("db")])
    await harness.makeReady()
    await harness.store.refresh()
    let request = try harness.requestDeleteConfirmation(network("app"))
    harness.engine.configure { $0.networks = .success([network("db")]) }

    let outcome = harness.store.confirm(id: request.id)
    #expect(harness.store.removing == [nid("app")])
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(harness.removeCalls == [network("app").deletableID!])
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.networks.value?.map(\.name) == ["db"])
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.removalFailures.isEmpty)
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndDeletesNothing() async throws {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.store.refresh()
    let request = try harness.requestDeleteConfirmation(network("app"))
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    let outcome = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()
    let again = harness.store.confirm(id: request.id)

    guard case .rejectedBusy = outcome else {
      Issue.record("expected .rejectedBusy, got \(outcome)")
      return
    }
    #expect(again == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == callsBefore)
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func aMismatchedIDConsumesNothing() async throws {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    let request = try harness.requestDeleteConfirmation(network("app"))

    let outcome = harness.store.confirm(id: UUID())

    #expect(outcome == .notPending)
    #expect(harness.store.pendingConfirmation == request)
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func aSecondApprovalOfTheSameRequestDeletesOnce() async throws {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    let request = try harness.requestDeleteConfirmation(network("app"))

    let first = harness.store.confirm(id: request.id)
    let second = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(first == .started)
    #expect(second == .notPending)
    #expect(harness.removeCalls.count == 1)
  }

  @Test func aNewRequestReplacesThePendingOneAndDismissDropsIt() async throws {
    let harness = Harness(networks: [network("app"), network("db")])
    await harness.makeReady()
    let first = try harness.requestDeleteConfirmation(network("app"))
    let second = try harness.requestDeleteConfirmation(network("db"))

    #expect(harness.store.confirm(id: first.id) == .notPending)
    harness.store.dismissConfirmation()

    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.confirm(id: second.id) == .notPending)
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func requestingADeleteWhileDockerIsNotReadyMakesNoRequest() async {
    let harness = Harness(networks: [network("app")])
    await harness.makeReady()
    await harness.stopVM()

    #expect(!harness.store.requestDelete(network("app")))
    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func aNetworkWithConnectedContainersShowsTheEngineErrorAndStaysListed() async throws {
    let message = "error while removing network: network app has active endpoints"
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkRemovalFailures[nid("app")] = .api(status: 403, message: message)
    }
    await harness.makeReady()
    await harness.store.refresh()
    let request = try harness.requestDeleteConfirmation(network("app"))

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.store.removalFailures[nid("app")] == message)
    #expect(harness.store.networks.value?.map(\.name) == ["app"])
    #expect(harness.listCalls == 2)
    #expect(harness.store.removing.isEmpty)
  }

  @Test func theNextDeleteOfTheSameNetworkClearsItsEarlierFailure() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkRemovalFailures[nid("app")] = .api(status: 403, message: "active endpoints")
    }
    await harness.makeReady()
    let first = try harness.requestDeleteConfirmation(network("app"))
    harness.store.confirm(id: first.id)
    await harness.store.awaitOperations()
    #expect(harness.store.removalFailures[nid("app")] != nil)

    harness.engine.configure { $0.networkRemovalFailures = [:] }
    let second = try harness.requestDeleteConfirmation(network("app"))
    harness.store.confirm(id: second.id)

    #expect(harness.store.removalFailures.isEmpty)
    await harness.store.awaitOperations()
  }

  @Test func aDeleteInFlightBlocksAnotherRequestForTheSameNetwork() async throws {
    let harness = Harness(networks: [network("app")])
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeNetwork = call { await gate.pass() }
      }
    }
    await harness.makeReady()
    let request = try harness.requestDeleteConfirmation(network("app"))
    harness.store.confirm(id: request.id)
    await gate.waitForArrivals(1)

    #expect(!harness.store.requestDelete(network("app")))
    gate.open()
    await harness.store.awaitOperations()
  }

  @Test func deletingTheSelectedNetworkClearsTheSelection() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure { $0.networkDetails[nid("app")] = detail(of: "app") }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let request = try harness.requestDeleteConfirmation(network("app"))

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.store.selectedID == nil)
    #expect(harness.store.detail.value == nil)
  }

  @Test func aFailedDeleteKeepsTheSelection() async throws {
    let harness = Harness(networks: [network("app")])
    harness.engine.configure {
      $0.networkDetails[nid("app")] = detail(of: "app", containers: ["web"])
      $0.networkRemovalFailures[nid("app")] = .api(status: 403, message: "active endpoints")
    }
    await harness.makeReady()
    harness.store.select(nid("app"))
    await harness.store.awaitOperations()
    let request = try harness.requestDeleteConfirmation(network("app"))

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.store.selectedID == nid("app"))
    #expect(harness.store.detail.value?.containers.map(\.name) == ["web"])
  }
}
