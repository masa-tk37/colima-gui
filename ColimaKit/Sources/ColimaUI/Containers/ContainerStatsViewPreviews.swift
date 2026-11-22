#if DEBUG
  import SwiftUI

  private struct StatsPreview: View {
    let scenario: StatsSessionPreviews.Scenario

    var body: some View {
      PreviewHost({ await StatsSessionPreviews.make(scenario) }) { scene in
        NavigationStack {
          ContainerStatsView(session: scene.session)
            .navigationTitle(scene.container.name)
        }
      }
      .frame(width: 560, height: 520)
    }
  }

  #Preview("Stats: running") {
    StatsPreview(scenario: .running)
  }

  #Preview("Stats: running (with gaps)") {
    StatsPreview(scenario: .runningWithGaps)
  }

  #Preview("Stats: stopped") {
    StatsPreview(scenario: .containerStopped)
  }

  #Preview("Stats: not running") {
    StatsPreview(scenario: .notRunning)
  }
#endif
