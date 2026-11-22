#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct UsagePreview: View {
    let scenario: VMUsageMonitorPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMUsageMonitorPreviews.make(scenario) }) { scene in
        VStack(spacing: 20) {
          UsageChart(LocalizedStringResource("CPU", bundle: #bundle), series: scene.monitor.cpu, metric: .cpuPercent)
          UsageChart(LocalizedStringResource("Memory", bundle: #bundle), series: scene.monitor.memory, metric: .memoryBytes)
        }
      }
      .padding()
      .frame(width: 480, height: 440)
    }
  }

  #Preview("Series with gaps") {
    UsagePreview(scenario: .runningWithGaps)
  }

  #Preview("Series without gaps") {
    UsagePreview(scenario: .runningWithoutGaps)
  }
#endif
