#if DEBUG
  import ColimaCore

  extension PreviewDockerEngine.Config {
    static var sample: PreviewDockerEngine.Config {
      var config = PreviewDockerEngine.Config()
      config.containers = .success(PreviewSampleData.containers)
      config.images = .success(PreviewSampleData.images)
      config.volumes = .success(PreviewSampleData.volumes)
      config.unusedVolumes = .success(PreviewSampleData.unusedVolumes)
      config.volumeSizes = .success(PreviewSampleData.volumeSizes)
      config.networks = .success(PreviewSampleData.networks)
      config.unusedNetworks = .success(PreviewSampleData.unusedNetworks)
      config.networkDetails = PreviewSampleData.networkDetails
      // The container detail screen opens these; a scenario about logs replaces them.
      let followed = PreviewDockerEngine.LogScript(
        chunks: PreviewSampleData.logChunks(PreviewSampleData.logEntries(count: 24), tty: false),
        ending: .staysOpen)
      config.logs[PreviewSampleData.webshopWeb.id] = followed
      config.logs[PreviewSampleData.scratchPostgres.id] = followed
      return config
    }
  }

  @MainActor
  struct PreviewDockerBackend {
    let vm: VMControllerScene
    let engine: PreviewDockerEngine
    let slots: ContainerOperationSlots

    var controller: VMController { vm.controller }

    static func make(
      vm: VMControllerPreviews.Scenario = .running,
      engine configure: (inout PreviewDockerEngine.Config) -> Void = { _ in }
    ) async -> PreviewDockerBackend {
      let engine = PreviewDockerEngine()
      engine.configure {
        $0 = .sample
        configure(&$0)
      }
      return PreviewDockerBackend(
        vm: await VMControllerPreviews.make(vm), engine: engine, slots: ContainerOperationSlots())
    }
  }
#endif
