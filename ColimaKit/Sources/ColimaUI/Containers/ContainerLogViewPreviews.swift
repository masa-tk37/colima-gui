#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct LogPreview: View {
    let scenario: LogSessionPreviews.Scenario
    var isPinnedToBottom = true

    var body: some View {
      PreviewHost({ await LogSessionPreviews.make(scenario) }) { scene in
        NavigationStack {
          ContainerLogView(session: scene.session, isPinnedToBottom: isPinnedToBottom)
            .navigationTitle(scene.container.name)
        }
      }
      .frame(width: 720, height: 480)
    }
  }

  #Preview("Logs: following") {
    LogPreview(scenario: .following)
  }

  #Preview("Logs: following (with unterminated last line)") {
    LogPreview(scenario: .followingWithUnterminatedLine)
  }

  #Preview("Logs: scrolled away from the end") {
    LogPreview(scenario: .followingLong, isPinnedToBottom: false)
  }

  #Preview("Logs: ended (stream closed)") {
    LogPreview(scenario: .endedStreamClosed)
  }

  #Preview("Logs: ended (container removed)") {
    LogPreview(scenario: .endedContainerGone)
  }

  #Preview("Logs: ended (connection lost)") {
    LogPreview(scenario: .endedConnectionLost)
  }

  #Preview("Logs: ended (unparseable format)") {
    LogPreview(scenario: .endedMalformedFrame)
  }

  #Preview("Logs: TTY") {
    LogPreview(scenario: .tty)
  }

  #Preview("Logs: history of a stopped container") {
    LogPreview(scenario: .history)
  }
#endif
