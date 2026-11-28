#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct TerminalModelScene {
    let model: TerminalModel
    let launcher: PreviewTerminalLauncher
  }

  @MainActor
  enum TerminalModelPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case available
      case terminalNotFound
      case shellApplicationNotFound
      case shellAutomationDenied
      case shellFailed
    }

    static func make(_ scenario: Scenario) async -> TerminalModelScene {
      let launcher = PreviewTerminalLauncher()
      let model = TerminalModel(launcher: launcher, defaults: UserDefaults(suiteName: "preview.\(UUID().uuidString)")!)

      switch scenario {
      case .available:
        break
      case .terminalNotFound:
        launcher.configure { $0.availability = .notFound }
      case .shellApplicationNotFound:
        launcher.configure { $0.openShell = .failure(.applicationNotFound) }
      case .shellAutomationDenied:
        launcher.configure { $0.openShell = .failure(.automationDenied) }
      case .shellFailed:
        launcher.configure { $0.openShell = .failure(PreviewMachineData.shellFailed.error) }
      }
      await model.refreshAvailability()
      if scenario != .available, scenario != .terminalNotFound {
        await model.openShell(for: PreviewMachineData.running)
      }
      return TerminalModelScene(model: model, launcher: launcher)
    }
  }
#endif
