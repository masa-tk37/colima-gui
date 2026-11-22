#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct SettingsPreview: View {
    let scenario: VMSettingsModelPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMSettingsModelPreviews.make(scenario) }) { scene in
        VMSettingsView(
          model: scene.settings, controller: scene.controller, submitResult: scene.submitResult,
          host: HostResources(cpus: 10, memoryGiB: 16, diskGiB: 460))
      }
      .frame(width: 520, height: 640)
    }
  }

  #Preview("Save") {
    SettingsPreview(scenario: .save)
  }

  #Preview("Save (with unapplied changes)") {
    SettingsPreview(scenario: .saveWithUnappliedChanges)
  }

  #Preview("Save (stopped)") {
    SettingsPreview(scenario: .saveWhileStopped)
  }

  #Preview("Save (restart required)") {
    SettingsPreview(scenario: .savedRestartRequired)
  }

  #Preview("Save (failed)") {
    SettingsPreview(scenario: .saveFailed)
  }

  #Preview("Recreate VM") {
    SettingsPreview(scenario: .recreate)
  }

  #Preview("Recreate VM (missing executables)") {
    SettingsPreview(scenario: .recreateMissingExecutables)
  }

  #Preview("Recreate VM (rejected)") {
    SettingsPreview(scenario: .recreateRejected)
  }

  #Preview("Create and start") {
    SettingsPreview(scenario: .create)
  }

  #Preview("Data disk warning") {
    SettingsPreview(scenario: .createWithDataDiskNotice)
  }

  #Preview("Disabled with reason (status unavailable)") {
    SettingsPreview(scenario: .unavailableUnknownState)
  }

  #Preview("Disabled with reason (VM type unreadable)") {
    SettingsPreview(scenario: .unavailableVMTypeUnreadable)
  }

  #Preview("In progress") {
    SettingsPreview(scenario: .operationInProgress)
  }

  #Preview("Per-field errors") {
    SettingsPreview(scenario: .fieldErrors)
  }

  #Preview("Config file unreadable") {
    SettingsPreview(scenario: .loadFailed)
  }
#endif
