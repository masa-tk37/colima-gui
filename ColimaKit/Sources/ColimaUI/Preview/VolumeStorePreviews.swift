#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct VolumeStoreScene {
    let store: VolumeStore
    let controller: VMController
    let engine: PreviewDockerEngine
    var pruneRequestResult: PruneRequestResult?
  }

  @MainActor
  enum VolumeStorePreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case listed
      case notLoaded
      case empty
      case pendingDelete
      case removalFailed
      case noPruneCandidates
      /// The candidates could not be read, so `pruneRequestError` is set.
      case pruneRequestFailed
      case pendingPrune
      case pruning
      case pruneResult
    }

    static let inUse = "webshop_pgdata"
    static let failingPruneCandidate = "analytics_cache"

    static func make(_ scenario: Scenario) async -> VolumeStoreScene {
      let backend = await PreviewDockerBackend.make { config in
        switch scenario {
        case .empty:
          config.volumes = .success([])
          config.unusedVolumes = .success([])
        case .removalFailed:
          config.volumeRemovals[inUse] = .fail(
            .api(status: 409, message: "remove webshop_pgdata: volume is in use - [4f2b]"))
        case .noPruneCandidates:
          config.unusedVolumes = .success([])
        case .pruneRequestFailed:
          config.unusedVolumes = .failure(.timedOut)
        case .pruning:
          config.volumeRemovals[failingPruneCandidate] = .hang
        case .pruneResult:
          config.volumeRemovals[failingPruneCandidate] = .fail(
            .api(status: 409, message: "remove analytics_cache: volume is in use - [9ac1]"))
        default: break
        }
      }
      let store = VolumeStore(engine: backend.engine, controller: backend.controller)
      var scene = VolumeStoreScene(
        store: store, controller: backend.controller, engine: backend.engine)
      guard scenario != .notLoaded else { return scene }

      await store.refresh()
      switch scenario {
      case .pendingDelete:
        if let row = store.volumes.value?.first(where: { $0.volume.name == inUse }) {
          store.requestDelete(row)
        }
      case .removalFailed:
        if let row = store.volumes.value?.first(where: { $0.volume.name == inUse }) {
          store.requestDelete(row)
          if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        }
        await PreviewSettle.until("removal failure recorded") {
          store.removalFailures[inUse] != nil
        }
      case .noPruneCandidates, .pruneRequestFailed, .pendingPrune:
        scene.pruneRequestResult = await store.requestPrune()
      case .pruning:
        scene.pruneRequestResult = await store.requestPrune()
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
      case .pruneResult:
        scene.pruneRequestResult = await store.requestPrune()
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        await PreviewSettle.until("prune report recorded") { store.lastPruneReport != nil }
      default:
        break
      }
      return scene
    }
  }
#endif
