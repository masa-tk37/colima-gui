import ColimaCore
import SwiftUI

struct VMUsageCharts: View {
  private static let chartHeight: CGFloat = 200

  let monitor: VMUsageMonitor
  let isSideBySide: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Usage", bundle: #bundle)
        .font(.headline)
      switch monitor.state {
      case .sampling:
        let layout =
          isSideBySide
          ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
        layout {
          GroupBox {
            UsageChart(LocalizedStringResource("CPU", bundle: #bundle), series: monitor.cpu, metric: .cpuPercent)
              .frame(height: Self.chartHeight)
          }
          GroupBox {
            UsageChart(LocalizedStringResource("Memory", bundle: #bundle), series: monitor.memory, metric: .memoryBytes)
              .frame(height: Self.chartHeight)
          }
        }
      case .unavailable(let reason):
        GroupBox {
          Label {
            Text(verbatim: reason)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "chart.xyaxis.line")
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
