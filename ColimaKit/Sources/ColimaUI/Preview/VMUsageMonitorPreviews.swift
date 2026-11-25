#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct VMUsageScene {
    let monitor: VMUsageMonitor
    let controller: VMController
  }

  @MainActor
  enum VMUsageMonitorPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      /// The screen's own `run()` goes on from there with measured samples.
      case runningWithGaps
      case runningWithoutGaps
      case runningNoSamplesYet
      case stopped
      case absent
      case colimaMissing
      case operationInProgress
      case unknown
    }

    static func make(_ scenario: Scenario) async -> VMUsageScene {
      let controllerScenario: VMControllerPreviews.Scenario =
        switch scenario {
        case .runningWithGaps, .runningWithoutGaps, .runningNoSamplesYet: .running
        case .stopped: .stopped
        case .absent: .absent
        case .colimaMissing: .colimaMissing
        case .operationInProgress: .starting
        case .unknown: .unknown
        }
      let base = await VMControllerPreviews.make(controllerScenario)
      let monitor = VMUsageMonitor(controller: base.controller, cli: base.cli)
      let window = monitor.cpu.window
      switch scenario {
      case .runningWithGaps:
        monitor.seedForPreview(
          cpu: PreviewSeriesData.cpu(window: window, count: 60, gaps: [12, 13, 40]),
          memory: PreviewSeriesData.memory(window: window, count: 60, gaps: [12, 13, 40]),
          previous: try? await base.cli.sampleUsage())
      case .runningWithoutGaps:
        monitor.seedForPreview(
          cpu: PreviewSeriesData.cpu(window: window, count: 60, gaps: []),
          memory: PreviewSeriesData.memory(window: window, count: 60, gaps: []),
          previous: try? await base.cli.sampleUsage())
      default:
        break
      }
      return VMUsageScene(monitor: monitor, controller: base.controller)
    }
  }
#endif
