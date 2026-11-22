import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ImageVolumeNetworkPreviewScenarioTests {
  // MARK: Images

  @Test func imageRowsPerTagAndUntagged() async {
    let scene = await ImageStorePreviews.make(.listed)
    let rows = scene.store.images.value ?? []
    #expect(
      rows.map(\.reference.value) == [
        "nginx:1.27", "nginx:latest", "postgres:17", "registry.example.com:5000/webshop/api:2.4.1",
        "sha256:aa04",
      ])
    #expect((await ImageStorePreviews.make(.empty)).store.images.value == [])
    #expect((await ImageStorePreviews.make(.notLoaded)).store.images.value == nil)
    #expect((await ImageStorePreviews.make(.listFailed)).store.images.error == .timedOut)
  }

  @Test func imageDeleteStates() async {
    let target = ImageStorePreviews.nginxRow.reference
    #expect(
      (await ImageStorePreviews.make(.pendingDelete)).store.pendingConfirmation?.intent
        == .deleteImage(target))
    #expect((await ImageStorePreviews.make(.removing)).store.removing == [target])

    let failed = await ImageStorePreviews.make(.removalFailed)
    #expect(failed.store.removalFailures[target]?.contains("must force") == true)
    #expect(failed.store.removing.isEmpty)
  }

  // MARK: Volumes

  @Test func volumeRowsMarkTheUsedOnes() async {
    let rows = await VolumeStorePreviews.make(.listed).store.volumes.value ?? []
    #expect(rows.filter(\.isInUse).map(\.volume.name) == ["webshop_pgdata"])
    #expect(rows.contains { $0.volume.isAnonymous })
    #expect(rows.contains { $0.volume.createdAt == nil })
  }

  @Test func volumeDeleteStates() async {
    let pending = await VolumeStorePreviews.make(.pendingDelete)
    #expect(pending.store.pendingConfirmation?.intent == .deleteVolume(name: "webshop_pgdata"))

    let failed = await VolumeStorePreviews.make(.removalFailed)
    #expect(failed.store.removalFailures["webshop_pgdata"]?.contains("in use") == true)
  }

  @Test func pruneWithNoCandidatesHasNoRequestAndNoError() async {
    let scene = await VolumeStorePreviews.make(.noPruneCandidates)
    #expect(scene.pruneRequestResult == .nothingToPrune)
    #expect(scene.store.pruneRequestError == nil)
    #expect(scene.store.pendingConfirmation == nil)
    #expect(!scene.store.isPruning)

    let failed = await VolumeStorePreviews.make(.pruneRequestFailed)
    #expect(failed.pruneRequestResult == .nothingToPrune)
    #expect(failed.store.pruneRequestError != nil)
  }

  @Test func aPendingPruneHasBothGroups() async throws {
    let scene = await VolumeStorePreviews.make(.pendingPrune)
    #expect(scene.pruneRequestResult == .confirmationRequested)
    let request = try #require(scene.store.pendingConfirmation)
    #expect(request.itemGroups.map(\.title) == ["Anonymous volumes", "Named volumes"])
    #expect(request.itemGroups[0].items == [PreviewSampleData.anonymousVolumeName])
    #expect((await VolumeStorePreviews.make(.pruning)).store.isPruning)
  }

  @Test func aPruneResultCountsDeletedUnknownSizeAndFailures() async throws {
    let scene = await VolumeStorePreviews.make(.pruneResult)
    let report = try #require(scene.store.lastPruneReport)
    #expect(report.deletedCount == 2)
    #expect(report.unknownSizeCount == 1)
    #expect(report.estimatedReclaimedBytes == 12_000_000)
    #expect(report.failures.keys.sorted() == ["analytics_cache"])
    #expect(!scene.store.isPruning)
  }

  // MARK: Networks

  @Test func theListHasTheThreeBuiltInNetworksWithoutADeleteAction() async throws {
    let scene = await NetworkStorePreviews.make(.listed)
    let networks = try #require(scene.store.networks.value)
    let builtIn = networks.filter { !scene.store.canDelete($0) }
    #expect(builtIn.map(\.name) == ["bridge", "host", "none"])
    #expect(scene.store.selectedID == nil)
  }

  @Test func aSelectedNetworkShowsItsContainersWithTheirAddresses() async throws {
    let scene = await NetworkStorePreviews.make(.detailSelected)
    let detail = try #require(scene.store.detail.value)
    #expect(detail.name == "webshop_default")
    #expect(detail.containers.map(\.name) == ["webshop-web-1", "webshop-api-1", "webshop-cache-1"])
    #expect(
      detail.containers.map(\.ipv4Address) == ["172.20.0.2/16", "172.20.0.3/16", "172.20.0.4/16"])

    let builtIn = await NetworkStorePreviews.make(.builtInSelected)
    #expect(builtIn.store.selectedID == PreviewSampleData.bridge.id)
    #expect(builtIn.store.requestDelete(PreviewSampleData.bridge) == false)

    let empty = await NetworkStorePreviews.make(.detailEmpty)
    #expect(empty.store.detail.value?.containers.isEmpty == true)
  }

  @Test func createFormErrorsAreLeftOnTheStore() async {
    let invalid = await NetworkStorePreviews.make(.createFieldErrors)
    guard case .invalid(let failure)? = invalid.createResult else {
      Issue.record("expected an invalid result")
      return
    }
    #expect(Set(failure.fields.map(\.field)) == [.name, .subnet])
    #expect(invalid.store.createFieldErrors == failure.fields)

    let taken = await NetworkStorePreviews.make(.createNameTaken)
    guard case .invalid(let nameFailure)? = taken.createResult else {
      Issue.record("expected an invalid result")
      return
    }
    #expect(nameFailure.fields.map(\.field) == [.name])

    let failed = await NetworkStorePreviews.make(.createFailed)
    #expect(failed.store.createFailure?.contains("overlaps") == true)
    #expect((await NetworkStorePreviews.make(.creating)).store.isCreating)
  }

  @Test func networkDeleteAndPruneStates() async throws {
    let pending = await NetworkStorePreviews.make(.pendingDelete)
    #expect(pending.store.pendingConfirmation != nil)

    let deleteFailed = await NetworkStorePreviews.make(.deleteFailed)
    #expect(
      deleteFailed.store.removalFailures[PreviewSampleData.devNet.id]?.contains("active endpoints")
        == true)

    let prune = await NetworkStorePreviews.make(.pendingPrune)
    #expect(prune.pruneRequestResult == .confirmationRequested)
    let names = try #require(prune.store.pendingConfirmation).itemGroups.flatMap(\.items)
    #expect(names == ["legacy_default", "dev-net", "old-experiment"])

    let nothing = await NetworkStorePreviews.make(.noPruneCandidates)
    #expect(nothing.pruneRequestResult == .nothingToPrune)
    #expect(nothing.store.pruneRequestError == nil)

    #expect((await NetworkStorePreviews.make(.pruneRequestFailed)).store.pruneRequestError != nil)

    let result = await NetworkStorePreviews.make(.pruneResult)
    let outcome = try #require(result.store.lastPruneOutcome)
    #expect(outcome.succeeded.count == 2)
    #expect(outcome.failed.keys.contains(PreviewSampleData.devNet.id))
  }

  @Test func disconnectStates() async throws {
    let pending = await NetworkStorePreviews.make(.pendingDisconnect)
    let request = try #require(pending.store.pendingConfirmation)
    #expect(
      request.intent
        == .disconnect(
          container: PreviewSampleData.webshopCache.id, network: PreviewSampleData.webshopDefault.id
        ))

    let failed = await NetworkStorePreviews.make(.disconnectFailed)
    #expect(failed.store.connectionFailures.count == 1)
    #expect(failed.store.pendingConfirmation == nil)
  }

  @Test func listStatesOfTheNetworkStore() async {
    #expect((await NetworkStorePreviews.make(.notLoaded)).store.networks.value == nil)
    #expect((await NetworkStorePreviews.make(.empty)).store.networks.value == [])
    #expect((await NetworkStorePreviews.make(.listFailed)).store.networks.error == .timedOut)
  }

  @Test func theConfirmationSceneCoversTheDockerModels() async {
    for scenario in [
      ConfirmationPreviews.Scenario.deleteContainer, .pruneVolumes, .pruneNetworks, .recreateVM,
      .restartVM,
    ] {
      let scene = await ConfirmationPreviews.make(scenario)
      #expect(scene.request?.isShown(on: .window) == true, "\(scenario)")
    }
  }
}
