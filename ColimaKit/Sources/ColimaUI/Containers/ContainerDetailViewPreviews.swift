#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct DetailPreview: View {
    let scenario: ContainerStorePreviews.Scenario
    let containerID: ContainerID
    var section: ContainerDetailSection = .overview

    var body: some View {
      PreviewHost({ await ContainerStorePreviews.make(scenario) }) { scene in
        NavigationStack {
          ContainerDetailView(
            containerID: containerID, store: scene.store, networks: scene.networks,
            sessions: scene.sessions, slots: scene.slots, initialSection: section)
        }
      }
      .frame(width: 560, height: 640)
    }
  }

  private struct RemovedWhileLogOpenPreview: View {
    var body: some View {
      PreviewHost({
        let scene = await ContainerStorePreviews.make(.listed)
        let removed = PreviewSampleData.webshopWeb
        let entries = PreviewSampleData.logEntries(count: 10)
        scene.engine.configure { config in
          config.logs[removed.id] = PreviewDockerEngine.LogScript(
            chunks: PreviewSampleData.logChunks(entries, tty: false),
            ending: .fails(.api(status: 404, message: "No such container: \(removed.name)")))
          config.containers = .success(PreviewSampleData.containers.filter { $0.id != removed.id })
        }
        await scene.store.refresh()
        return scene
      }) { scene in
        NavigationStack {
          ContainerDetailView(
            containerID: PreviewSampleData.webshopWeb.id, store: scene.store,
            networks: scene.networks,
            sessions: scene.sessions, slots: scene.slots, initialSection: .logs)
        }
      }
      .frame(width: 560, height: 640)
    }
  }

  private struct ConnectPreview: View {
    let scenario: ContainerStorePreviews.Scenario
    let containerID: ContainerID
    var initialSelection: NetworkID?
    var isRefused = false

    var body: some View {
      PreviewHost({ await ContainerStorePreviews.make(scenario) }) { scene in
        if let container = scene.store.containers.value?.first(where: { $0.id == containerID }) {
          Form {
            AttachedNetworksSection(networkNames: container.networkNames)
            ContainerNetworkConnectSection(
              container: container, networks: scene.networks, slots: scene.slots,
              initialSelection: initialSelection, isRefused: isRefused)
          }
          .formStyle(.grouped)
        } else {
          Form {
            ContainerNetworkConnectSection(
              container: ContainerSummary(
                id: containerID, name: "scratch-postgres", image: "postgres:17", state: .running,
                ports: [], labels: [:], networkNames: ["bridge"]),
              networks: scene.networks, slots: scene.slots)
          }
          .formStyle(.grouped)
        }
      }
      .frame(width: 520, height: 420)
    }
  }

  private let scratch = PreviewSampleData.scratchPostgres.id

  #Preview("Detail: overview (running, with ports, on one network)") {
    DetailPreview(scenario: .listed, containerID: PreviewSampleData.webshopWeb.id)
  }

  #Preview("Detail: overview (stopped)") {
    DetailPreview(scenario: .listed, containerID: PreviewSampleData.adminer.id)
  }

  #Preview("Detail: logs open") {
    DetailPreview(scenario: .listed, containerID: PreviewSampleData.webshopWeb.id, section: .logs)
  }

  #Preview("Detail: stats open") {
    DetailPreview(scenario: .listed, containerID: PreviewSampleData.webshopWeb.id, section: .stats)
  }

  #Preview("Detail: container not in the list") {
    DetailPreview(scenario: .listed, containerID: ContainerID(rawValue: "removed-container"))
  }

  #Preview("Detail: container removed while logs are open") {
    RemovedWhileLogOpenPreview()
  }

  #Preview("Detail: before the list loads") {
    DetailPreview(scenario: .notLoaded, containerID: scratch)
  }

  #Preview("Detail: list load failure (no list)") {
    DetailPreview(scenario: .listFailed, containerID: scratch)
  }

  #Preview("Connect: nothing selected") {
    ConnectPreview(scenario: .listed, containerID: scratch)
  }

  #Preview("Connect: network selected") {
    ConnectPreview(
      scenario: .listed, containerID: scratch, initialSelection: PreviewSampleData.devNet.id)
  }

  #Preview("Connect: connecting (busy state)") {
    ConnectPreview(
      scenario: .networkConnecting, containerID: scratch,
      initialSelection: PreviewSampleData.devNet.id)
  }

  #Preview("Connect: connection failure") {
    ConnectPreview(
      scenario: .networkConnectFailed, containerID: scratch,
      initialSelection: PreviewSampleData.devNet.id)
  }

  #Preview("Connect: request refused") {
    ConnectPreview(
      scenario: .listed, containerID: scratch, initialSelection: PreviewSampleData.devNet.id,
      isRefused: true)
  }

  #Preview("Connect: before the network list loads") {
    ConnectPreview(scenario: .notLoaded, containerID: scratch)
  }

  #Preview("Attached networks: several") {
    Form {
      AttachedNetworksSection(networkNames: ["webshop_default", "dev-net", "bridge"])
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 240)
  }

  #Preview("Attached networks: none") {
    Form {
      AttachedNetworksSection(networkNames: [])
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 200)
  }
#endif
