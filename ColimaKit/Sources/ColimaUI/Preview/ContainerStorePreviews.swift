#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct ContainerStoreScene {
    let store: ContainerStore
    let networks: NetworkStore
    let sessions: ContainerSessionFactory
    let slots: ContainerOperationSlots
    let controller: VMController
    let engine: PreviewDockerEngine
    let cli: PreviewColimaCLI
  }

  @MainActor
  enum ContainerStorePreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case listed
      case notLoaded
      case empty
      case unlabeledOnly
      case operating
      case partialFailure
      case operationFailed
      case pendingDelete
      case deleteFailed
      case listFailed
      case listFailedKeepingList
      case engineUnreachable
      case networkConnectFailed
      case networkConnecting
    }

    static let engineFailure = DockerError.api(
      status: 500, message: "error while listing containers: context deadline exceeded")

    static func make(_ scenario: Scenario) async -> ContainerStoreScene {
      let web = PreviewSampleData.webshopWeb.id
      let api = PreviewSampleData.webshopAPI.id
      let adminer = PreviewSampleData.adminer.id
      let scratch = PreviewSampleData.scratchPostgres.id
      let devNet = PreviewSampleData.devNet.id

      let backend = await PreviewDockerBackend.make { config in
        switch scenario {
        case .empty: config.containers = .success([])
        case .unlabeledOnly: config.containers = .success(PreviewSampleData.unlabeledContainers)
        case .operating:
          config.containerActions[web] = .hang
          config.containerActions[PreviewSampleData.analyticsWorker.id] = .hang
          config.containerActions[PreviewSampleData.analyticsDB.id] = .hang
        case .partialFailure:
          config.containerActions[api] = .fail(
            .api(status: 500, message: "cannot stop container: permission denied"))
        case .operationFailed:
          config.containerActions[adminer] = .fail(
            .api(
              status: 500,
              message:
                "driver failed programming external connectivity on endpoint adminer: port is already allocated"
            ))
        case .deleteFailed:
          config.containerRemovals[adminer] = .fail(
            .api(status: 409, message: "removal of container adminer is already in progress"))
        case .listFailed: config.containers = .failure(engineFailure)
        case .engineUnreachable:
          config.containers = .failure(
            .engineUnreachable(
              detail: "connect(2) to /Users/you/.colima/default/docker.sock failed"))
        case .networkConnectFailed:
          config.connections[NetworkMembership(container: scratch, network: devNet)] = .fail(
            .api(
              status: 403,
              message: "container cannot be connected to network endpoints: dev-net is restricted"))
        case .networkConnecting:
          config.connections[NetworkMembership(container: scratch, network: devNet)] = .hang
        case .listed, .notLoaded, .pendingDelete, .listFailedKeepingList: break
        }
      }
      let store = ContainerStore(
        engine: backend.engine, controller: backend.controller, slots: backend.slots)
      let networks = NetworkStore(
        engine: backend.engine, controller: backend.controller, slots: backend.slots,
        containerListDidChange: { [store] in await store.refresh() })
      let scene = ContainerStoreScene(
        store: store, networks: networks, sessions: ContainerSessionFactory(engine: backend.engine),
        slots: backend.slots, controller: backend.controller, engine: backend.engine, cli: backend.vm.cli)
      guard scenario != .notLoaded else { return scene }

      await store.refresh()
      await networks.refresh()
      switch scenario {
      case .operating:
        store.perform(.restart, on: web)
        store.performProject(.stop, on: "analytics")
      case .partialFailure:
        store.performProject(.stop, on: "webshop")
        await PreviewSettle.until("project outcome recorded") {
          store.projectOutcomes["webshop"] != nil
        }
      case .operationFailed:
        store.perform(.start, on: adminer)
        await PreviewSettle.until("operation failure recorded") {
          store.operationFailures[adminer] != nil
        }
      case .pendingDelete:
        store.requestDelete(adminer)
      case .deleteFailed:
        store.requestDelete(adminer)
        if let id = store.pendingConfirmation?.id { store.confirm(id: id) }
        await PreviewSettle.until("delete failure recorded") {
          store.operationFailures[adminer] != nil
        }
      case .listFailedKeepingList:
        backend.engine.configure { $0.containers = .failure(.timedOut) }
        await store.refresh()
      case .networkConnectFailed:
        networks.connect(container: scratch, to: devNet)
        await PreviewSettle.until("connect failure recorded") {
          !networks.connectionFailures.isEmpty
        }
      case .networkConnecting:
        networks.connect(container: scratch, to: devNet)
      default:
        break
      }
      return scene
    }
  }
#endif
