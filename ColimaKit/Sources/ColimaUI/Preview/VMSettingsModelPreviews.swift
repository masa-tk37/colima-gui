#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct VMSettingsScene {
    let settings: VMSettingsModel
    let controller: VMController
    let files: PreviewColimaFileStore
    var submitResult: SettingsSubmitResult?
  }

  @MainActor
  enum VMSettingsModelPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case save
      case saveWithUnappliedChanges
      case saveWhileStopped
      case recreate
      case recreateMissingExecutables
      case recreateRejected
      case create
      case createWithDataDiskNotice
      case unavailableUnknownState
      case unavailableVMTypeUnreadable
      case operationInProgress
      case fieldErrors
      case saveFailed
      case savedRestartRequired
      case loadFailed
    }

    static func make(_ scenario: Scenario) async -> VMSettingsScene {
      let controllerScenario: VMControllerPreviews.Scenario =
        switch scenario {
        case .save, .saveWithUnappliedChanges, .recreate, .recreateMissingExecutables,
          .recreateRejected,
          .unavailableVMTypeUnreadable, .fieldErrors, .saveFailed, .savedRestartRequired,
          .loadFailed:
          .running
        case .saveWhileStopped: .stopped
        case .create: .absent
        case .createWithDataDiskNotice: .dataDiskMayRemain
        case .unavailableUnknownState: .unknown
        case .operationInProgress: .starting
        }
      let base = await VMControllerPreviews.make(controllerScenario)
      // The model reads the files when it is created, so they are configured first.
      configureFiles(base.files, for: scenario)
      if scenario == .recreateMissingExecutables || scenario == .recreateRejected {
        base.cli.configure {
          $0.toolchain = ToolchainStatus(
            colima: .found(path: "/opt/homebrew/bin/colima"),
            installedExecutables: ["qemu-img", "qemu-system-aarch64"])
        }
        await base.controller.redetectToolchain()
      }
      let settings = VMSettingsModel(controller: base.controller, files: base.files)
      var scene = VMSettingsScene(
        settings: settings, controller: base.controller, files: base.files)
      await drive(&scene, scenario)
      return scene
    }

    private static func configureFiles(_ files: PreviewColimaFileStore, for scenario: Scenario) {
      let matching = ProfileSettings(
        resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 100), vmType: .vz)
      switch scenario {
      case .saveWithUnappliedChanges:
        files.configure {
          $0.profile = .success(
            ProfileSettings(
              resources: VMResourceSettings(cpus: 4, memoryGiB: 8, diskGiB: 100), vmType: .vz))
        }
      case .unavailableVMTypeUnreadable:
        files.configure { $0.instanceVMType = .success(nil) }
      case .saveFailed:
        files.configure {
          $0.profile = .success(matching)
          $0.writeFailure = .writeFailed(
            path: "~/.colima/default/colima.yaml", reason: "Operation not permitted")
        }
      case .loadFailed:
        files.configure {
          $0.profile = .failure(
            .unreadable(path: "~/.colima/default/colima.yaml", reason: "Permission denied"))
        }
      default:
        files.configure { $0.profile = .success(matching) }
      }
    }

    private static func drive(_ scene: inout VMSettingsScene, _ scenario: Scenario) async {
      let settings = scene.settings
      switch scenario {
      case .recreate:
        await settings.selectVMType(.qemu)
      case .recreateMissingExecutables:
        await settings.selectVMType(.krunkit)
      case .recreateRejected:
        await settings.selectVMType(.krunkit)
        scene.submitResult = await settings.submit()
      case .fieldErrors:
        settings.cpusText = "0"
        settings.memoryGiBText = "abc"
        settings.diskGiBText = "10"
        scene.submitResult = await settings.submit()
      case .saveFailed, .savedRestartRequired:
        settings.cpusText = "4"
        scene.submitResult = await settings.submit()
      default:
        break
      }
    }
  }
#endif
