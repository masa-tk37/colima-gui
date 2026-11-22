#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct NetworkStoreScene {
    let store: NetworkStore
    let controller: VMController
    let slots: ContainerOperationSlots
    let engine: PreviewDockerEngine
    var pruneRequestResult: PruneRequestResult?
    var createResult: NetworkCreateResult?
  }

  @MainActor
  enum NetworkStorePreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case listed
      case notLoaded
      case empty
      case listFailed
      case detailSelected
      case builtInSelected
      case detailEmpty
      case createFieldErrors
      case createNameTaken
      case createFailed
      case creating
      case pendingDelete
      case deleteFailed
      case pendingPrune
      case noPruneCandidates
      case pruneRequestFailed
      case pruneResult
      case pendingDisconnect
      case disconnectFailed
    }

    static let selected = PreviewSampleData.webshopDefault
    static let disconnecting = PreviewSampleData.webshopCache
    static let failingPruneCandidate = PreviewSampleData.devNet

    static func make(_ scenario: Scenario) async -> NetworkStoreScene {
      let backend = await PreviewDockerBackend.make { config in
        switch scenario {
        case .empty:
          config.networks = .success([])
          config.unusedNetworks = .success([])
        case .listFailed: config.networks = .failure(.timedOut)
        case .createFailed:
          config.networkCreation = .fail(
            .api(
              status: 403,
              message: "invalid pool request: Pool overlaps with other one on this address space"))
        case .creating: config.networkCreation = .hang
        case .deleteFailed:
          config.networkRemovals[PreviewSampleData.devNet.id] = .fail(
            .api(
              status: 403,
              message: "error while removing network: network dev-net has active endpoints"))
        case .noPruneCandidates: config.unusedNetworks = .success([])
        case .pruneRequestFailed: config.unusedNetworks = .failure(.timedOut)
        case .pruneResult:
          config.networkRemovals[failingPruneCandidate.id] = .fail(
            .api(
              status: 403,
              message: "error while removing network: network dev-net has active endpoints"))
        case .disconnectFailed:
          config.disconnections[
            NetworkMembership(container: disconnecting.id, network: selected.id)] = .fail(
              .api(status: 500, message: "container is not connected to the network"))
        default: break
        }
      }
      let store = NetworkStore(
        engine: backend.engine, controller: backend.controller, slots: backend.slots)
      var scene = NetworkStoreScene(
        store: store, controller: backend.controller, slots: backend.slots, engine: backend.engine)
      guard scenario != .notLoaded else { return scene }

      await store.refresh()
      await drive(&scene, scenario)
      return scene
    }

    private static func drive(_ scene: inout NetworkStoreScene, _ scenario: Scenario) async {
      let store = scene.store
      switch scenario {
      case .detailSelected, .pendingDisconnect, .disconnectFailed:
        await select(selected.id, in: store)
      case .builtInSelected:
        await select(PreviewSampleData.bridge.id, in: store)
      case .detailEmpty:
        await select(PreviewSampleData.devNet.id, in: store)
      default:
        break
      }

      switch scenario {
      case .createFieldErrors:
        scene.createResult = await store.createNetwork(
          NetworkCreateForm(name: "", subnet: "not-a-subnet"))
      case .createNameTaken:
        scene.createResult = await store.createNetwork(
          NetworkCreateForm(name: "dev-net", subnet: ""))
      case .createFailed:
        scene.createResult = await store.createNetwork(
          NetworkCreateForm(name: "staging-net", subnet: "172.31.0.0/16"))
      case .creating:
        // The create outlives this task, and the scenario must not wait for it.
        Task { _ = await store.createNetwork(NetworkCreateForm(name: "staging-net", subnet: "")) }
        await PreviewSettle.until("the create started") { store.isCreating }
      case .pendingDelete:
        store.requestDelete(PreviewSampleData.devNet)
      case .deleteFailed:
        store.requestDelete(PreviewSampleData.devNet)
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        await PreviewSettle.until("delete failure recorded") { !store.removalFailures.isEmpty }
      case .pendingPrune, .noPruneCandidates, .pruneRequestFailed:
        scene.pruneRequestResult = await store.requestPrune()
      case .pruneResult:
        scene.pruneRequestResult = await store.requestPrune()
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        await PreviewSettle.until("prune outcome recorded") { store.lastPruneOutcome != nil }
      case .pendingDisconnect:
        store.requestDisconnect(container: disconnecting.id, from: selected.id)
      case .disconnectFailed:
        store.requestDisconnect(container: disconnecting.id, from: selected.id)
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        await PreviewSettle.until("disconnect failure recorded") {
          !store.connectionFailures.isEmpty
        }
      default:
        break
      }
    }

    private static func select(_ id: NetworkID, in store: NetworkStore) async {
      store.select(id)
      await PreviewSettle.until("the network detail arrived") { store.detail.value != nil }
    }
  }
#endif
