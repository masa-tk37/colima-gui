import Foundation
import Synchronization
import Testing

@testable import ColimaCore

private func volume(_ name: String, anonymous: Bool = false) -> VolumeSummary {
  VolumeSummary(
    name: name, driver: "local", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    labels: anonymous ? [VolumeSummary.anonymousLabel: "true"] : nil
  )
}

private let listAll = FakeDockerEngine.Call.listVolumes(danglingOnly: false)
private let listDangling = FakeDockerEngine.Call.listVolumes(danglingOnly: true)

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let engine = FakeDockerEngine()
  let controller: VMController
  let store: VolumeStore

  init(all: [VolumeSummary] = [], unused: [VolumeSummary] = [], sizes: [String: VolumeSize] = [:]) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure { $0.listDefault = [.success(.present(instance(running: true)))] }
    engine.configure {
      $0.volumes = .success(all)
      $0.danglingVolumes = .success(unused)
      $0.volumeSizes = .success(sizes)
    }
    store = VolumeStore(engine: engine, controller: controller)
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

  var removeCalls: [String] {
    engine.calls.compactMap { if case .removeVolume(let name) = $0 { name } else { nil } }
  }

  func requestPruneConfirmation() async throws -> ConfirmationRequest {
    let result = await store.requestPrune()
    #expect(result == .confirmationRequested)
    return try #require(store.pendingConfirmation)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VolumeStoreTests {

  // MARK: List

  @Test func aVolumeAbsentFromTheDanglingListIsShownInUse() async {
    let harness = Harness(
      all: [volume("data"), volume("cache"), volume("anon", anonymous: true)],
      unused: [volume("cache")]
    )
    await harness.makeReady()

    await harness.store.refresh()

    let rows = harness.store.volumes.value ?? []
    #expect(rows.map(\.volume.name) == ["data", "cache", "anon"])
    #expect(rows.map(\.isInUse) == [true, false, true])
    #expect(rows[0].volume.driver == "local")
    #expect(rows[2].volume.isAnonymous)
    #expect(harness.engine.calls == [listAll, listDangling])
  }

  @Test func nothingIsFetchedOrRequestedWhileDockerIsNotReady() async {
    let target = VolumeRow(volume: volume("data"), isInUse: false)
    let harness = Harness(all: [volume("data")], unused: [volume("data")])
    await harness.makeReady()
    await harness.store.refresh()
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    await harness.store.refresh()
    let deleteAccepted = harness.store.requestDelete(target)
    let pruneResult = await harness.store.requestPrune()
    await harness.store.awaitOperations()

    #expect(!deleteAccepted)
    #expect(pruneResult == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == callsBefore)
  }

  @Test func aFailedRefreshKeepsThePreviousRowsAndShowsTheError() async {
    let harness = Harness(all: [volume("data")], unused: [])
    await harness.makeReady()
    await harness.store.refresh()

    harness.engine.configure { $0.danglingVolumes = .failure(.timedOut) }
    await harness.store.refresh()

    #expect(harness.store.volumes.value?.count == 1)
    #expect(harness.store.volumes.error == .timedOut)
    #expect(!harness.store.volumes.isRefreshing)
  }

  @Test func theListIsFetchedOnlyWhenAskedAndNeverOnItsOwn() async throws {
    let harness = Harness(all: [volume("data")], unused: [])
    await harness.makeReady()
    await harness.store.refresh()
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.engine.calls == [listAll, listDangling])
  }

  // MARK: Delete

  @Test func requestingADeleteWarnsAboutDataLossAndCallsNothingOnTheEngine() async throws {
    let target = VolumeRow(volume: volume("data"), isInUse: false)
    let harness = Harness(all: [volume("data")], unused: [volume("data")])
    await harness.makeReady()

    let accepted = harness.store.requestDelete(target)

    let request = try #require(harness.store.pendingConfirmation)
    #expect(accepted)
    #expect(request.intent == .deleteVolume(name: "data"))
    #expect(request.origin == .window)
    #expect(request.title.contains("data"))
    #expect(request.message.contains("Data in the volume"))
    #expect(request.message.contains("cannot be recovered"))
    #expect(request.itemGroups.flatMap(\.items) == ["data"])
    #expect(harness.engine.calls.isEmpty)
  }

  @Test func approvingRemovesOnceThenRefreshes() async throws {
    let target = VolumeRow(volume: volume("data"), isInUse: false)
    let harness = Harness(all: [], unused: [])
    await harness.makeReady()
    harness.store.requestDelete(target)
    let id = try #require(harness.store.pendingConfirmation?.id)

    let outcome = harness.store.confirm(id: id)
    #expect(harness.store.removing == ["data"])
    let again = harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(again == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == [.removeVolume("data"), listAll, listDangling])
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.removalFailures.isEmpty)
  }

  @Test func aVolumeThatTurnedInUseFailsWithTheEngineMessageAndStaysListed() async throws {
    let target = VolumeRow(volume: volume("data"), isInUse: true)
    let harness = Harness(all: [volume("data")], unused: [])
    await harness.makeReady()
    await harness.store.refresh()
    let message = "remove data: volume is in use - [4f2c]"
    harness.engine.configure {
      $0.volumeRemovalFailures["data"] = .api(status: 409, message: message)
    }
    harness.store.requestDelete(target)

    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await harness.store.awaitOperations()

    #expect(harness.store.removalFailures["data"] == message)
    #expect(harness.store.volumes.value?.map(\.volume.name) == ["data"])
    #expect(harness.store.volumes.value?.first?.isInUse == true)
    #expect(harness.store.removing.isEmpty)
  }

  @Test func aFailureIsClearedWhenTheNextRemovalOfTheSameVolumeStarts() async throws {
    let target = VolumeRow(volume: volume("data"), isInUse: false)
    let harness = Harness(all: [volume("data")], unused: [volume("data")])
    await harness.makeReady()
    harness.engine.configure { $0.volumeRemovalFailures["data"] = .timedOut }
    harness.store.requestDelete(target)
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await harness.store.awaitOperations()
    #expect(harness.store.removalFailures["data"] != nil)

    harness.engine.configure { $0.volumeRemovalFailures = [:] }
    harness.store.requestDelete(target)
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await harness.store.awaitOperations()

    #expect(harness.store.removalFailures.isEmpty)
  }

  @Test func aRemovalInFlightBlocksAnotherRequestForTheSameVolumeOnly() async throws {
    let target = VolumeRow(volume: volume("data"), isInUse: false)
    let other = VolumeRow(volume: volume("cache"), isInUse: false)
    let harness = Harness()
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeVolume = call { await gate.pass() }
      }
    }
    harness.store.requestDelete(target)
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await gate.waitForArrivals(1)

    let sameAgain = harness.store.requestDelete(target)
    let otherAccepted = harness.store.requestDelete(other)
    gate.open()
    await harness.store.awaitOperations()

    #expect(!sameAgain)
    #expect(otherAccepted)
    #expect(harness.removeCalls == ["data"])
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndNothingRuns() async throws {
    let harness = Harness(all: [volume("data")], unused: [volume("data")])
    await harness.makeReady()
    harness.store.requestDelete(VolumeRow(volume: volume("data"), isInUse: false))
    let id = try #require(harness.store.pendingConfirmation?.id)
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    let outcome = harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls.isEmpty)
    #expect(harness.engine.calls == callsBefore)
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.confirm(id: id) == .notPending)
  }

  @Test func aMismatchedIDKeepsThePendingRequestAndAReplacedRequestCannotBeApproved() async throws {
    let harness = Harness()
    await harness.makeReady()

    harness.store.requestDelete(VolumeRow(volume: volume("first"), isInUse: false))
    let firstID = try #require(harness.store.pendingConfirmation?.id)
    #expect(harness.store.confirm(id: UUID()) == .notPending)
    #expect(harness.store.pendingConfirmation?.id == firstID)

    harness.store.requestDelete(VolumeRow(volume: volume("second"), isInUse: false))
    #expect(harness.store.confirm(id: firstID) == .notPending)
    #expect(harness.store.pendingConfirmation?.intent == .deleteVolume(name: "second"))
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func dismissingDropsThePendingRequest() async {
    let harness = Harness()
    await harness.makeReady()
    harness.store.requestDelete(VolumeRow(volume: volume("data"), isInUse: false))

    harness.store.dismissConfirmation()

    #expect(harness.store.pendingConfirmation == nil)
  }

  // MARK: Prune request

  @Test func zeroCandidatesCreateNoConfirmationAndDeleteNothing() async {
    let harness = Harness(all: [volume("busy")], unused: [])
    await harness.makeReady()

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == [listDangling])
    #expect(harness.store.pruneRequestError == nil)
  }

  @Test func candidatesAreSplitIntoAnonymousAndNamedGroupsAndTheBodySaysNamedOnesGoToo()
    async throws
  {
    let harness = Harness(
      all: [],
      unused: [
        volume("n1"), volume("a1", anonymous: true), volume("n2"), volume("a2", anonymous: true),
      ],
      sizes: [
        "n1": .bytes(1_000_000), "a1": .bytes(2_000_000), "n2": .unknown, "a2": .bytes(500_000),
      ]
    )
    await harness.makeReady()

    let request = try await harness.requestPruneConfirmation()

    #expect(request.intent == .pruneVolumes(names: ["a1", "a2", "n1", "n2"]))
    #expect(request.origin == .window)
    #expect(
      request.itemGroups == [
        ConfirmationItemGroup(title: "Anonymous volumes", items: ["a1", "a2"]),
        ConfirmationItemGroup(title: "Named volumes", items: ["n1", "n2"]),
      ])
    #expect(request.message.contains("Named volumes are deleted too"))
    #expect(request.message.contains("`docker volume prune` deletes only anonymous volumes by default"))
    #expect(request.message.contains("cannot be recovered"))
    let estimate = ByteCountFormatter.string(fromByteCount: 3_500_000, countStyle: .file)
    #expect(request.message.contains(estimate))
    #expect(request.message.contains("excluding volumes of unknown size: 1"))
    #expect(harness.engine.calls == [listDangling, .volumeSizes])
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func aGroupWithoutCandidatesIsLeftOut() async throws {
    let harness = Harness(unused: [volume("a1", anonymous: true)])
    await harness.makeReady()

    let request = try await harness.requestPruneConfirmation()

    #expect(request.itemGroups.map(\.title) == ["Anonymous volumes"])
  }

  @Test func whenSizesCannotBeReadEveryCandidateCountsAsUnknownButTheRequestStillGoes() async throws
  {
    let harness = Harness(unused: [volume("n1"), volume("n2")])
    await harness.makeReady()
    harness.engine.configure { $0.volumeSizes = .failure(.timedOut) }

    let request = try await harness.requestPruneConfirmation()

    #expect(request.message.contains("excluding volumes of unknown size: 2"))
    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()
    #expect(harness.store.lastPruneReport?.unknownSizeCount == 2)
    #expect(harness.store.lastPruneReport?.deletedCount == 2)
    #expect(harness.store.lastPruneReport?.estimatedReclaimedBytes == 0)
  }

  @Test func aFailedCandidateFetchCreatesNoConfirmationAndShowsTheError() async {
    let harness = Harness()
    await harness.makeReady()
    harness.engine.configure { $0.danglingVolumes = .failure(.timedOut) }

    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.pruneRequestError == DockerError.timedOut.displayMessage)
    #expect(harness.removeCalls.isEmpty)
  }

  @Test func dockerStoppingWhileCandidatesAreFetchedCreatesNoConfirmation() async {
    let harness = Harness(unused: [volume("n1")])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if call == listDangling { await gate.pass() }
      }
    }
    let store = harness.store
    let request = Task { await store.requestPrune() }
    await gate.waitForArrivals(1)
    await harness.stopVM()
    gate.open()

    let result = await request.value

    #expect(result == .nothingToPrune)
    #expect(store.pendingConfirmation == nil)
  }

  // MARK: Prune confirm

  @Test func approvingDeletesOnlyTheConfirmedCandidatesOneByOneAndReportsTheOutcome() async throws {
    let harness = Harness(
      unused: [volume("a1", anonymous: true), volume("n1")],
      sizes: ["a1": .bytes(2_000), "n1": .bytes(300), "late": .bytes(9_999)]
    )
    await harness.makeReady()
    let request = try await harness.requestPruneConfirmation()
    harness.engine.configure {
      $0.danglingVolumes = .success([volume("a1", anonymous: true), volume("n1"), volume("late")])
    }

    let outcome = harness.store.confirm(id: request.id)
    let again = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(again == .notPending)
    #expect(harness.removeCalls == ["a1", "n1"])
    #expect(
      harness.store.lastPruneReport == PruneReport(deletedSizes: [2_000, 300], failures: [:]))
    #expect(harness.store.lastPruneReport?.estimatedReclaimedBytes == 2_300)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.store.removing.isEmpty)
    #expect(!harness.store.isPruning)
    #expect(harness.engine.calls.suffix(2) == [listAll, listDangling])
  }

  @Test func aFailedCandidateIsReportedPerItemAndTheRestAreStillDeleted() async throws {
    let harness = Harness(
      unused: [volume("n1"), volume("n2"), volume("n3")],
      sizes: ["n1": .bytes(100), "n2": .bytes(200), "n3": .unknown]
    )
    await harness.makeReady()
    let message = "remove n2: volume is in use"
    harness.engine.configure {
      $0.volumeRemovalFailures["n2"] = .api(status: 409, message: message)
    }
    let request = try await harness.requestPruneConfirmation()

    harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == ["n1", "n2", "n3"])
    let report = try #require(harness.store.lastPruneReport)
    #expect(report.deletedCount == 2)
    #expect(report.estimatedReclaimedBytes == 100)
    #expect(report.unknownSizeCount == 1)
    #expect(report.failures == ["n2": message])
  }

  @Test func candidatesAreRemovedSequentiallyWithoutForce() async throws {
    let harness = Harness(unused: [volume("n1"), volume("n2")])
    await harness.makeReady()
    let request = try await harness.requestPruneConfirmation()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeVolume = call { await gate.pass() }
      }
    }

    harness.store.confirm(id: request.id)
    await gate.waitForArrivals(1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(harness.removeCalls == ["n1"])
    #expect(harness.store.isPruning)
    #expect(harness.store.removing == ["n1", "n2"])
    gate.open()
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == ["n1", "n2"])
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndNothingIsDeleted() async throws {
    let harness = Harness(unused: [volume("n1"), volume("a1", anonymous: true)])
    await harness.makeReady()
    let request = try await harness.requestPruneConfirmation()
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    let outcome = harness.store.confirm(id: request.id)
    await harness.store.awaitOperations()

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls.isEmpty)
    #expect(harness.engine.calls == callsBefore)
    #expect(harness.store.lastPruneReport == nil)
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.confirm(id: request.id) == .notPending)
  }

  @Test func whileAPruneRunsNewPruneAndDeleteRequestsAreRefusedAndNoSecondDeletionStarts()
    async throws
  {
    let harness = Harness(unused: [volume("n1")])
    await harness.makeReady()
    let first = try await harness.requestPruneConfirmation()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeVolume = call { await gate.pass() }
      }
    }
    harness.store.confirm(id: first.id)
    await gate.waitForArrivals(1)
    let callsBefore = harness.engine.calls

    let refusedPrune = await harness.store.requestPrune()
    let refusedDelete = harness.store.requestDelete(
      VolumeRow(volume: volume("other"), isInUse: false))
    let pending = harness.store.pendingConfirmation
    gate.open()
    await harness.store.awaitOperations()

    #expect(refusedPrune == .nothingToPrune)
    #expect(!refusedDelete)
    #expect(pending == nil)
    #expect(harness.engine.calls.starts(with: callsBefore))
    #expect(harness.removeCalls == ["n1"])
  }

  @Test func aPruneApprovedWhileOneOfItsVolumesIsBeingDeletedIsRejectedAndDeletesNothing()
    async throws
  {
    let harness = Harness(unused: [volume("n1"), volume("n2")])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeVolume = call { await gate.pass() }
      }
    }
    harness.store.requestDelete(VolumeRow(volume: volume("n1"), isInUse: false))
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await gate.waitForArrivals(1)
    let prune = try await harness.requestPruneConfirmation()

    let outcome = harness.store.confirm(id: prune.id)
    gate.open()
    await harness.store.awaitOperations()

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.removeCalls == ["n1"])
    #expect(harness.store.lastPruneReport == nil)
    #expect(!harness.store.isPruning)
  }

  @Test func aSecondPruneStartedFromACompletedOneReportsOnlyItsOwnOutcome() async throws {
    let harness = Harness(unused: [volume("n1")])
    await harness.makeReady()
    let first = try await harness.requestPruneConfirmation()
    harness.store.confirm(id: first.id)
    await harness.store.awaitOperations()
    harness.engine.configure { $0.danglingVolumes = .success([volume("n2")]) }

    let second = try await harness.requestPruneConfirmation()
    harness.store.confirm(id: second.id)
    await harness.store.awaitOperations()

    #expect(harness.removeCalls == ["n1", "n2"])
    #expect(harness.store.lastPruneReport == PruneReport(deletedSizes: [nil], failures: [:]))
  }

  @Test func theNextPruneClearsThePreviousReportAndRequestError() async throws {
    let harness = Harness(unused: [volume("n1")])
    await harness.makeReady()
    let first = try await harness.requestPruneConfirmation()
    harness.store.confirm(id: first.id)
    await harness.store.awaitOperations()
    #expect(harness.store.lastPruneReport?.deletedCount == 1)

    harness.engine.configure { $0.danglingVolumes = .success([]) }
    let result = await harness.store.requestPrune()

    #expect(result == .nothingToPrune)
    #expect(harness.store.lastPruneReport == nil)
    #expect(harness.store.pruneRequestError == nil)
  }
}
