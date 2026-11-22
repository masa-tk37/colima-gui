#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct ImageStoreScene {
    let store: ImageStore
    let controller: VMController
    let engine: PreviewDockerEngine
  }

  @MainActor
  enum ImageStorePreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case listed
      case notLoaded
      case empty
      case pendingDelete
      case removing
      case removalFailed
      case listFailed
    }

    static var nginxRow: ImageRow {
      PreviewSampleData.images[0].rows[0]
    }

    static func make(_ scenario: Scenario) async -> ImageStoreScene {
      let target = nginxRow.reference
      let backend = await PreviewDockerBackend.make { config in
        switch scenario {
        case .empty: config.images = .success([])
        case .removing: config.imageRemovals[target] = .hang
        case .removalFailed:
          config.imageRemovals[target] = .fail(
            .api(
              status: 409,
              message:
                "conflict: unable to remove repository reference \"nginx:1.27\" (must force) - container 4f2b is using its referenced image aa01"
            ))
        case .listFailed: config.images = .failure(.timedOut)
        case .listed, .notLoaded, .pendingDelete: break
        }
      }
      let store = ImageStore(engine: backend.engine, controller: backend.controller)
      let scene = ImageStoreScene(
        store: store, controller: backend.controller, engine: backend.engine)
      guard scenario != .notLoaded else { return scene }

      await store.refresh()
      switch scenario {
      case .pendingDelete:
        store.requestDelete(nginxRow)
      case .removing:
        requestAndConfirm(store)
      case .removalFailed:
        requestAndConfirm(store)
        await PreviewSettle.until("removal failure recorded") {
          store.removalFailures[target] != nil
        }
      default:
        break
      }
      return scene
    }

    private static func requestAndConfirm(_ store: ImageStore) {
      store.requestDelete(nginxRow)
      if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
    }
  }
#endif
