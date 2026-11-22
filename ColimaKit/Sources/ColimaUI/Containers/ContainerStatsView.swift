import ColimaCore
import SwiftUI

public struct ContainerStatsView: View {
  private let session: StatsSession

  public init(session: StatsSession) {
    self.session = session
  }

  public var body: some View {
    Group {
      switch session.state {
      case .starting:
        ProgressView(LocalizedStringResource("Loading stats", bundle: #bundle))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .notRunning:
        ContentUnavailableView(LocalizedStringResource("Can't show stats", bundle: #bundle), systemImage: "chart.line.downtrend.xyaxis",
          description: Text(session.state.message ?? ""))
      case .running, .containerStopped:
        charts
      }
    }
    .task { await session.run() }
  }

  private var charts: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if session.state == .containerStopped, let message = session.state.message {
          Label(message, systemImage: "stop.circle")
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox {
          UsageChart(LocalizedStringResource("CPU", bundle: #bundle), series: session.cpu, metric: .cpuPercent)
            .padding(4)
        }
        Text("One CPU core is 100%, so a container using several cores can exceed 100%.", bundle: #bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
        GroupBox {
          UsageChart(LocalizedStringResource("Memory", bundle: #bundle), series: session.memory, metric: .memoryBytes)
            .padding(4)
        }
      }
      .padding()
    }
  }
}
