#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct OverviewPreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMControllerPreviews.make(scenario) }) { scene in
        VMOverviewView(
          controller: scene.controller, usageMonitor: VMUsageMonitor(controller: scene.controller, cli: scene.cli),
          retryRecreateResult: scene.retryResult)
      }
      .frame(width: 900, height: 640)
    }
  }

  private struct UsagePreview: View {
    let scenario: VMUsageMonitorPreviews.Scenario
    let width: CGFloat

    var body: some View {
      PreviewHost({ await VMUsageMonitorPreviews.make(scenario) }) { scene in
        VMOverviewView(controller: scene.controller, usageMonitor: scene.monitor)
      }
      .frame(width: width, height: 720)
    }
  }

  #Preview("Running with charts") {
    UsagePreview(scenario: .runningWithGaps, width: 900)
  }

  #Preview("Running, no samples yet") {
    UsagePreview(scenario: .runningNoSamplesYet, width: 900)
  }

  #Preview("Narrow (stacked)") {
    UsagePreview(scenario: .runningWithoutGaps, width: 600)
  }

  #Preview("Stopped") {
    OverviewPreview(scenario: .stopped)
  }

  #Preview("Running") {
    OverviewPreview(scenario: .running)
  }

  #Preview("In progress (start output)") {
    OverviewPreview(scenario: .starting)
  }

  #Preview("In progress (abort available)") {
    OverviewPreview(scenario: .startingAbortable)
  }

  #Preview("Failed (start)") {
    OverviewPreview(scenario: .startFailed)
  }

  #Preview("Broken state") {
    OverviewPreview(scenario: .broken)
  }

  #Preview("Not created") {
    OverviewPreview(scenario: .absent)
  }

  #Preview("Status unavailable") {
    OverviewPreview(scenario: .unknown)
  }

  #Preview("Colima not detected") {
    OverviewPreview(scenario: .colimaMissing)
  }

  #Preview("Data disk may remain") {
    OverviewPreview(scenario: .dataDiskMayRemain)
  }

  #Preview("Data disk retry rejected") {
    OverviewPreview(scenario: .dataDiskMayRemainRetryRefused)
  }
#endif
