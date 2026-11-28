#if DEBUG
  import ColimaCore
  import SwiftUI

  @MainActor
  private struct RootPreviewScene {
    let containers: ContainerStoreScene
    let settings: VMSettingsScene
    let images: ImageStoreScene
    let volumes: VolumeStoreScene
    let machines: MachineControllerScene
    let terminal: TerminalModelScene
  }

  #Preview("Root screen") {
    PreviewHost {
      RootPreviewScene(
        containers: await ContainerStorePreviews.make(.listed),
        settings: await VMSettingsModelPreviews.make(.save),
        images: await ImageStorePreviews.make(.listed),
        volumes: await VolumeStorePreviews.make(.listed),
        machines: await MachineControllerPreviews.make(.mixed),
        terminal: await TerminalModelPreviews.make(.available))
    } content: { scene in
      RootView(
        controller: scene.containers.controller,
        settingsModel: scene.settings.settings,
        usageMonitor: VMUsageMonitor(controller: scene.containers.controller, cli: scene.containers.cli),
        containerStore: scene.containers.store,
        imageStore: scene.images.store,
        volumeStore: scene.volumes.store,
        networkStore: scene.containers.networks,
        slots: scene.containers.slots,
        sessions: scene.containers.sessions,
        machineController: scene.machines.controller,
        terminal: scene.terminal.model
      )
      .frame(width: 1100, height: 720)
    }
  }
#endif
