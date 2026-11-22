import Foundation
import Synchronization
import Testing

@testable import ColimaCore

private func image(_ id: String, tags: [String], size: Int64 = 1_000) -> ImageSummary {
  ImageSummary(
    id: id, repoTags: tags, size: size, created: Date(timeIntervalSince1970: 1_700_000_000))
}

private func usingImage(_ imageID: String, id: String) -> ContainerSummary {
  ContainerSummary(
    id: ContainerID(rawValue: id), name: id, image: "", state: .running, ports: [], labels: [:], networkNames: [],
    imageID: imageID)
}

private func row(_ id: String, tag: String) -> ImageRow {
  let summary = image(id, tags: [tag])
  return summary.rows[0]
}

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let engine = FakeDockerEngine()
  let controller: VMController
  let store: ImageStore

  init(images: [ImageSummary] = []) {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure { $0.listDefault = [.success(.present(instance(running: true)))] }
    engine.configure { $0.images = .success(images) }
    store = ImageStore(engine: engine, controller: controller)
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

  var listCalls: Int { count { $0 == .listImages } }
  var removeCalls: Int { count { if case .removeImage = $0 { true } else { false } } }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ImageStoreTests {

  // MARK: List

  @Test func refreshCountsTheContainersUsingEachImage() async {
    let harness = Harness(images: [image("sha256:aaa", tags: ["web:1"]), image("sha256:bbb", tags: ["db:1"])])
    harness.engine.configure {
      $0.containers = .success([
        usingImage("sha256:aaa", id: "c1"), usingImage("sha256:aaa", id: "c2"), usingImage("", id: "c3"),
      ])
    }
    await harness.makeReady()
    await harness.store.refresh()

    let rows = harness.store.images.value ?? []
    #expect(rows.first { $0.imageID == "sha256:aaa" }.flatMap(harness.store.containerCount(for:)) == 2)
    #expect(rows.first { $0.imageID == "sha256:bbb" }.flatMap(harness.store.containerCount(for:)) == 0)
  }

  @Test func aFailedContainerListLeavesUsageUnknownButKeepsTheImages() async {
    let harness = Harness(images: [image("sha256:aaa", tags: ["web:1"])])
    harness.engine.configure { $0.containers = .failure(.engineUnreachable(detail: "socket closed")) }
    await harness.makeReady()
    await harness.store.refresh()

    let rows = harness.store.images.value ?? []
    #expect(rows.count == 1)
    #expect(harness.store.containerCount(for: rows[0]) == nil)
  }

  @Test func refreshShowsOneRowPerTagAndANoneRowForAnUntaggedImage() async {
    let harness = Harness(images: [
      image("sha256:aaa", tags: ["nginx:latest", "nginx:1.27"]),
      image("sha256:bbb", tags: []),
    ])
    await harness.makeReady()

    await harness.store.refresh()

    let rows = harness.store.images.value ?? []
    #expect(
      rows.map(\.reference) == [
        .tag(repository: "nginx", tag: "latest"),
        .tag(repository: "nginx", tag: "1.27"),
        .imageID("sha256:bbb"),
      ])
    #expect(rows.last?.repository == ImageRow.noneLabel)
  }

  @Test func nothingIsFetchedOrRemovedWhileDockerIsNotReady() async {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()
    await harness.stopVM()
    let callsBefore = harness.engine.calls

    await harness.store.refresh()
    let accepted = harness.store.requestDelete(target)
    await harness.store.awaitOperations()

    #expect(!accepted)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == callsBefore)
  }

  @Test func aFailedRefreshKeepsThePreviousRowsAndShowsTheError() async {
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()

    harness.engine.configure { $0.images = .failure(.timedOut) }
    await harness.store.refresh()

    #expect(harness.store.images.value?.count == 1)
    #expect(harness.store.images.error == .timedOut)
    #expect(!harness.store.images.isRefreshing)
  }

  @Test func aSlowEarlierRefreshDoesNotOverwriteALaterOne() async {
    let harness = Harness()
    await harness.makeReady()
    let gate = ArrivalGate()
    let engine = harness.engine
    let older = [image("sha256:old", tags: ["old:1"])]
    let newer = [image("sha256:new", tags: ["new:1"])]
    let started = Mutex(0)
    engine.configure {
      $0.beforeReturn = { call in
        guard call == .listImages else { return }
        let number = started.withLock {
          $0 += 1
          return $0
        }
        if number == 1 {
          await gate.pass()
          engine.configure { $0.images = .success(older) }
        } else {
          engine.configure { $0.images = .success(newer) }
        }
      }
    }
    let store = harness.store
    let slow = Task { await store.refresh() }
    await gate.waitForArrivals(1)

    await store.refresh()
    gate.open()
    await slow.value

    #expect(store.images.value?.map(\.repository) == ["new"])
    #expect(!store.images.isRefreshing)
  }

  @Test func theListIsFetchedOnlyWhenAskedAndNeverOnItsOwn() async throws {
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    #expect(harness.listCalls == 0)

    await harness.store.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.listCalls == 1)

    await harness.store.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.listCalls == 2)
  }

  // MARK: Delete

  @Test func requestingADeleteAsksForConfirmationAndCallsNothingOnTheEngine() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()

    let accepted = harness.store.requestDelete(target)
    await harness.store.awaitOperations()

    let request = try #require(harness.store.pendingConfirmation)
    #expect(accepted)
    #expect(request.intent == .deleteImage(.tag(repository: "nginx", tag: "latest")))
    #expect(request.origin == .window)
    #expect(request.title.contains("nginx:latest"))
    #expect(request.itemGroups.flatMap(\.items) == ["nginx:latest"])
    #expect(harness.removeCalls == 0)
    #expect(harness.listCalls == 1)
  }

  @Test func anUntaggedRowIsNamedByItsImageID() async throws {
    let harness = Harness(images: [image("sha256:bbb", tags: [])])
    await harness.makeReady()
    await harness.store.refresh()
    let target = try #require(harness.store.images.value?.first)

    harness.store.requestDelete(target)

    let request = try #require(harness.store.pendingConfirmation)
    #expect(request.intent == .deleteImage(.imageID("sha256:bbb")))
    #expect(request.title.contains("sha256:bbb"))
  }

  @Test func approvingRemovesOnceWithoutForceThenRefreshes() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()
    harness.store.requestDelete(target)
    let id = try #require(harness.store.pendingConfirmation?.id)

    let outcome = harness.store.confirm(id: id)
    #expect(harness.store.removing == [target.reference])
    let again = harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    #expect(outcome == .started)
    #expect(again == .notPending)
    #expect(harness.store.pendingConfirmation == nil)
    #expect(harness.engine.calls == [.listImages, .listContainers, .removeImage(target.reference), .listImages, .listContainers])
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.removalFailures.isEmpty)
  }

  @Test func aRemovalInFlightBlocksAnotherRequestForTheSameImageOnly() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let other = row("sha256:bbb", tag: "redis:7")
    let harness = Harness(images: [
      image("sha256:aaa", tags: ["nginx:latest"]), image("sha256:bbb", tags: ["redis:7"]),
    ])
    await harness.makeReady()
    let gate = ArrivalGate()
    harness.engine.configure {
      $0.beforeReturn = { call in
        if case .removeImage = call { await gate.pass() }
      }
    }
    harness.store.requestDelete(target)
    let id = try #require(harness.store.pendingConfirmation?.id)
    harness.store.confirm(id: id)
    await gate.waitForArrivals(1)

    let sameAgain = harness.store.requestDelete(target)
    let otherAccepted = harness.store.requestDelete(other)
    gate.open()
    await harness.store.awaitOperations()

    #expect(!sameAgain)
    #expect(otherAccepted)
    #expect(harness.removeCalls == 1)
  }

  @Test func approvingAfterDockerStoppedBeingReadyIsRejectedAndNothingRuns() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()
    harness.store.requestDelete(target)
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
    #expect(harness.removeCalls == 0)
    #expect(harness.engine.calls == callsBefore)
    #expect(harness.store.removing.isEmpty)
    #expect(harness.store.confirm(id: id) == .notPending)
  }

  @Test func aMismatchedIDKeepsThePendingRequestAndAReplacedRequestCannotBeApproved() async throws {
    let first = row("sha256:aaa", tag: "nginx:latest")
    let second = row("sha256:bbb", tag: "redis:7")
    let harness = Harness(images: [
      image("sha256:aaa", tags: ["nginx:latest"]), image("sha256:bbb", tags: ["redis:7"]),
    ])
    await harness.makeReady()
    await harness.store.refresh()

    harness.store.requestDelete(first)
    let firstID = try #require(harness.store.pendingConfirmation?.id)
    #expect(harness.store.confirm(id: UUID()) == .notPending)
    #expect(harness.store.pendingConfirmation?.id == firstID)

    harness.store.requestDelete(second)
    #expect(harness.store.confirm(id: firstID) == .notPending)
    #expect(harness.store.pendingConfirmation?.intent == .deleteImage(second.reference))
    #expect(harness.removeCalls == 0)
  }

  @Test func confirmingWithNothingPendingDoesNothing() async {
    let harness = Harness()
    await harness.makeReady()

    #expect(harness.store.confirm(id: UUID()) == .notPending)
    #expect(harness.removeCalls == 0)
  }

  @Test func dismissingDropsThePendingRequest() async {
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    harness.store.requestDelete(row("sha256:aaa", tag: "nginx:latest"))

    harness.store.dismissConfirmation()

    #expect(harness.store.pendingConfirmation == nil)
  }

  @Test func aFailedRemovalShowsTheEngineMessageRefreshesAndKeepsTheImageListed() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    await harness.store.refresh()
    let message =
      "conflict: unable to delete aaa (must be forced) - image is being used by running container"
    harness.engine.configure {
      $0.imageRemovalFailures[target.reference] = .api(status: 409, message: message)
    }
    harness.store.requestDelete(target)
    let id = try #require(harness.store.pendingConfirmation?.id)

    harness.store.confirm(id: id)
    await harness.store.awaitOperations()

    #expect(harness.store.removalFailures[target.reference] == message)
    #expect(harness.store.images.value?.map(\.reference) == [target.reference])
    #expect(harness.engine.calls == [.listImages, .listContainers, .removeImage(target.reference), .listImages, .listContainers])
    #expect(harness.store.removing.isEmpty)
  }

  @Test func aFailureIsClearedWhenTheNextRemovalOfTheSameImageStarts() async throws {
    let target = row("sha256:aaa", tag: "nginx:latest")
    let harness = Harness(images: [image("sha256:aaa", tags: ["nginx:latest"])])
    await harness.makeReady()
    harness.engine.configure { $0.imageRemovalFailures[target.reference] = .timedOut }
    harness.store.requestDelete(target)
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await harness.store.awaitOperations()
    #expect(harness.store.removalFailures[target.reference] != nil)

    harness.engine.configure { $0.imageRemovalFailures = [:] }
    harness.store.requestDelete(target)
    harness.store.confirm(id: try #require(harness.store.pendingConfirmation?.id))
    await harness.store.awaitOperations()

    #expect(harness.store.removalFailures.isEmpty)
  }
}
