import Foundation
import Testing

@testable import ColimaCore

private func makeRequest(
  id: UUID = UUID(),
  intent: DestructiveIntent = .stopVM,
  origin: ConfirmationOrigin = .window,
  itemGroups: [ConfirmationItemGroup] = []
) -> ConfirmationRequest {
  ConfirmationRequest(
    id: id,
    intent: intent,
    origin: origin,
    title: "Stop VM",
    message: "Running containers stop.",
    itemGroups: itemGroups,
    confirmLabel: "Stop"
  )
}

@Test func volumePruneRequestCarriesAnonymousAndNamedGroups() {
  let groups = [
    ConfirmationItemGroup(title: "Anonymous volumes", items: ["a1b2", "c3d4"]),
    ConfirmationItemGroup(title: "Named volumes", items: ["pgdata"]),
  ]
  let request = makeRequest(
    intent: .pruneVolumes(names: ["a1b2", "c3d4", "pgdata"]),
    itemGroups: groups
  )
  #expect(request.itemGroups.count == 2)
  #expect(request.itemGroups[0].title == "Anonymous volumes")
  #expect(request.itemGroups[0].items == ["a1b2", "c3d4"])
  #expect(request.itemGroups[1].title == "Named volumes")
  #expect(request.itemGroups[1].items == ["pgdata"])
  #expect(request.intent == .pruneVolumes(names: ["a1b2", "c3d4", "pgdata"]))
}

@Test func singleGroupHasNoTitle() {
  let group = ConfirmationItemGroup(title: nil, items: ["web"])
  #expect(group.title == nil)
  #expect(group != ConfirmationItemGroup(title: "Containers", items: ["web"]))
}

@Test func windowAndMenuBarOriginsAreMutuallyExclusive() {
  let windowRequest = makeRequest(origin: .window)
  #expect(windowRequest.isShown(on: .window))
  #expect(!windowRequest.isShown(on: .menuBar))

  let menuBarRequest = makeRequest(origin: .menuBar)
  #expect(menuBarRequest.isShown(on: .menuBar))
  #expect(!menuBarRequest.isShown(on: .window))
}

@Test func exactlyOneSurfaceShowsAnyRequest() {
  for origin in [ConfirmationOrigin.window, .menuBar] {
    let request = makeRequest(origin: origin)
    let showing = [ConfirmationOrigin.window, .menuBar].filter { request.isShown(on: $0) }
    #expect(showing == [origin])
  }
}

@Test func requestsAreIdentifiedByTheirOwnID() {
  let first = makeRequest()
  let second = makeRequest()
  #expect(first.id != second.id)
  #expect(first != second)

  let id = UUID()
  #expect(makeRequest(id: id) == makeRequest(id: id))
}

@Test func intentsCompareByAssociatedValues() {
  let container = ContainerID(rawValue: "c1")
  let network = NetworkID(rawValue: "n1")
  #expect(
    DestructiveIntent.deleteContainer(container) == .deleteContainer(ContainerID(rawValue: "c1")))
  #expect(
    DestructiveIntent.deleteContainer(container) != .deleteContainer(ContainerID(rawValue: "c2")))
  #expect(
    DestructiveIntent.disconnect(container: container, network: network)
      == .disconnect(container: container, network: NetworkID(rawValue: "n1"))
  )
  #expect(
    DestructiveIntent.deleteImage(.imageID("sha256:abc")) == .deleteImage(.imageID("sha256:abc")))
  #expect(DestructiveIntent.deleteVolume(name: "v") != .pruneVolumes(names: ["v"]))
  #expect(DestructiveIntent.stopVM != .restartVM)
}

@Test func networkIntentsCarryOnlyDeletableIDs() throws {
  let network = NetworkSummary(
    id: NetworkID(rawValue: "abc"), name: "appnet", driver: "bridge", scope: "local", ipam: [])
  let deletable = try #require(network.deletableID)
  #expect(DestructiveIntent.deleteNetwork(deletable) == .deleteNetwork(deletable))
  #expect(DestructiveIntent.pruneNetworks(ids: [deletable]) == .pruneNetworks(ids: [deletable]))
}

@Test func outcomesDistinguishConsumedFromNotPending() {
  #expect(ConfirmationOutcome.started != .notPending)
  #expect(ConfirmationOutcome.rejectedBusy(reason: "a") == .rejectedBusy(reason: "a"))
  #expect(ConfirmationOutcome.rejectedBusy(reason: "a") != .rejectedBusy(reason: "b"))
  #expect(ConfirmationOutcome.rejectedBusy(reason: "a") != .started)
}
