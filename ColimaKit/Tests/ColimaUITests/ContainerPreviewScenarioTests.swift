import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ContainerPreviewScenarioTests {
  @Test func theListShowsThreeProjectStatesAndUnlabeledContainers() async {
    let scene = await ContainerStorePreviews.make(.listed)
    let groups = scene.store.groups
    #expect(groups.projects.map(\.name) == ["analytics", "legacy", "webshop"])
    #expect(groups.projects.map(\.state) == [.partiallyRunning, .allStopped, .allRunning])
    #expect(groups.ungrouped.map(\.name) == ["scratch-postgres", "adminer"])
    #expect(scene.networks.networks.value?.count == PreviewSampleData.networks.count)
  }

  @Test func notLoadedEmptyAndUnlabeledOnly() async {
    let notLoaded = await ContainerStorePreviews.make(.notLoaded)
    #expect(notLoaded.store.containers.value == nil)
    #expect(notLoaded.store.containers.error == nil)

    let empty = await ContainerStorePreviews.make(.empty)
    #expect(empty.store.containers.value == [])

    let unlabeled = await ContainerStorePreviews.make(.unlabeledOnly)
    #expect(unlabeled.store.groups.projects.isEmpty)
    #expect(unlabeled.store.groups.ungrouped.count == 2)
  }

  @Test func operationsInProgressHoldTheirSlots() async {
    let scene = await ContainerStorePreviews.make(.operating)
    let busy = scene.slots.busyIDs
    #expect(
      busy == [
        PreviewSampleData.webshopWeb.id, PreviewSampleData.analyticsWorker.id,
        PreviewSampleData.analyticsDB.id,
      ])
  }

  @Test func aProjectStopThatPartlyFailedKeepsTheBreakdown() async throws {
    let scene = await ContainerStorePreviews.make(.partialFailure)
    let outcome = try #require(scene.store.projectOutcomes["webshop"])
    #expect(
      outcome.succeeded == [PreviewSampleData.webshopWeb.id, PreviewSampleData.webshopCache.id])
    #expect(
      outcome.failed == [
        PreviewSampleData.webshopAPI.id: "cannot stop container: permission denied"
      ])
  }

  @Test func singleContainerFailuresAndPendingDelete() async throws {
    let adminer = PreviewSampleData.adminer.id
    let failed = await ContainerStorePreviews.make(.operationFailed)
    #expect(failed.store.operationFailures[adminer]?.operation == .action(.start))

    let pending = await ContainerStorePreviews.make(.pendingDelete)
    #expect(pending.store.pendingConfirmation?.intent == .deleteContainer(adminer))

    let deleteFailed = await ContainerStorePreviews.make(.deleteFailed)
    #expect(deleteFailed.store.operationFailures[adminer]?.operation == .delete)
    #expect(deleteFailed.store.pendingConfirmation == nil)
  }

  @Test func listErrors() async {
    let failed = await ContainerStorePreviews.make(.listFailed)
    #expect(failed.store.containers.value == nil)
    #expect(failed.store.containers.error == ContainerStorePreviews.engineFailure)

    let stale = await ContainerStorePreviews.make(.listFailedKeepingList)
    #expect(stale.store.containers.value?.count == PreviewSampleData.containers.count)
    #expect(stale.store.containers.error == .timedOut)

    let unreachable = await ContainerStorePreviews.make(.engineUnreachable)
    guard case .engineUnreachable? = unreachable.store.containers.error else {
      Issue.record("expected engineUnreachable")
      return
    }
    #expect(EngineGuidance(observation: unreachable.controller.observation) == .restartVM)
  }

  @Test func theDetailSceneCanChooseAnUnconnectedNetworkAndListTheConnectedOnes() async throws {
    let scene = await ContainerStorePreviews.make(.listed)
    let scratch = try #require(
      scene.store.containers.value?.first { $0.id == PreviewSampleData.scratchPostgres.id })
    #expect(scratch.networkNames == ["bridge"])
    let candidates = try #require(scene.networks.networks.value).filter {
      !scratch.networkNames.contains($0.name)
    }
    #expect(candidates.contains { $0.name == "dev-net" })

    let failed = await ContainerStorePreviews.make(.networkConnectFailed)
    let key = NetworkMembership(
      container: PreviewSampleData.scratchPostgres.id, network: PreviewSampleData.devNet.id)
    #expect(failed.networks.connectionFailures[key]?.contains("restricted") == true)

    let connecting = await ContainerStorePreviews.make(.networkConnecting)
    #expect(connecting.slots.isBusy(PreviewSampleData.scratchPostgres.id))
  }

  @Test func theSessionFactoryGivesIndependentSessionsOnTheSharedEngine() async throws {
    let scene = await ContainerStorePreviews.make(.listed)
    let first = scene.sessions.makeLogSession(for: PreviewSampleData.adminer.id)
    let second = scene.sessions.makeLogSession(for: PreviewSampleData.adminer.id)
    #expect(first !== second)
    await first.run()
    #expect(first.state == .history)
    #expect(second.state == .loading)

    let followed = scene.sessions.makeLogSession(for: PreviewSampleData.webshopWeb.id)
    let task = Task { await followed.run() }
    defer { task.cancel() }
    await PreviewSettle.until("the web log arrived") { followed.lines.count == 24 }
    #expect(followed.state == .following)
  }
}
