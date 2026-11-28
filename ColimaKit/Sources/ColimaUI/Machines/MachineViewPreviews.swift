#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct ListPreview: View {
    let scenario: MachineControllerPreviews.Scenario
    var keepingListAfterFailedRead = false
    var terminalScenario = TerminalModelPreviews.Scenario.available

    var body: some View {
      PreviewHost({ await Self.make(scenario, keepingListAfterFailedRead, terminalScenario) }) { scene in
        MachineListView(controller: scene.controller.controller, terminal: scene.terminal)
      }
      .frame(width: 900, height: 600)
    }

    private struct Scene {
      let controller: MachineControllerScene
      let terminal: TerminalModel
    }

    private static func make(
      _ scenario: MachineControllerPreviews.Scenario, _ keepingList: Bool,
      _ terminalScenario: TerminalModelPreviews.Scenario
    ) async -> Scene {
      let machines = await MachineControllerPreviews.make(scenario)
      if keepingList {
        machines.cli.configure { $0.listing = .failure(.nonZeroExit(code: 1, output: PreviewMachineData.listFailureOutput)) }
        await machines.controller.refreshNow()
      }
      let terminal = await TerminalModelPreviews.make(terminalScenario).model
      return Scene(controller: machines, terminal: terminal)
    }
  }

  #Preview("No machines") {
    ListPreview(scenario: .noMachines)
  }

  #Preview("limactl missing") {
    ListPreview(scenario: .limactlMissing)
  }

  #Preview("Read failed") {
    ListPreview(scenario: .listFailed)
  }

  #Preview("Read failed, last list kept") {
    ListPreview(scenario: .mixed, keepingListAfterFailedRead: true)
  }

  #Preview("Running and stopped machines") {
    ListPreview(scenario: .mixed)
  }

  #Preview("Creating") {
    ListPreview(scenario: .creating)
  }

  #Preview("Cancel requested") {
    ListPreview(scenario: .createCancelRequested)
  }

  #Preview("Create failed") {
    ListPreview(scenario: .createFailed)
  }

  #Preview("Starting") {
    ListPreview(scenario: .starting)
  }

  #Preview("Start failed") {
    ListPreview(scenario: .startFailed)
  }

  #Preview("Broken row") {
    ListPreview(scenario: .brokenRow)
  }

  #Preview("Operations from an earlier session") {
    ListPreview(scenario: .earlierSession)
  }

  #Preview("Create cancelled notice") {
    ListPreview(scenario: .createCancelled)
  }

  #Preview("Delete a running machine") {
    ListPreview(scenario: .pendingDeleteRunning)
  }

  #Preview("Delete a stopped machine") {
    ListPreview(scenario: .pendingDeleteStopped)
  }

  #Preview("Memory warning") {
    ListPreview(scenario: .pendingMemoryWarning)
  }

  #Preview("Shell: terminal not found") {
    ListPreview(scenario: .mixed, terminalScenario: .shellApplicationNotFound)
  }

  #Preview("Shell: automation denied") {
    ListPreview(scenario: .mixed, terminalScenario: .shellAutomationDenied)
  }

  #Preview("Shell: failed") {
    ListPreview(scenario: .mixed, terminalScenario: .shellFailed)
  }
#endif
