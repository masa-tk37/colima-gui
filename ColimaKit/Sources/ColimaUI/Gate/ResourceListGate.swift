import ColimaCore
import SwiftUI

struct ResourceListGate<Rows: Sendable, Content: View>: View {
  let snapshot: ResourceSnapshot<Rows>
  let controller: VMController
  let failureTitle: LocalizedStringResource
  let loadingTitle: LocalizedStringResource
  let retry: @MainActor () async -> Void
  @ViewBuilder let content: (Rows) -> Content

  var body: some View {
    if let rows = snapshot.value, controller.dockerAvailability == .ready {
      content(rows)
        // A system bar over the list, so the scroll edge effect separates it instead of a drawn background.
        .safeAreaBar(edge: .top) {
          if let error = snapshot.error {
            ListErrorBanner(error: error, controller: controller)
          }
        }
    } else if controller.dockerAvailability != .ready || snapshot.error?.isConnectionFailure == true
    {
      DockerGateView(controller: controller, engineError: snapshot.error, retry: retry)
    } else if let error = snapshot.error {
      ContentUnavailableView {
        Label(failureTitle, systemImage: "exclamationmark.triangle")
      } description: {
        Text(verbatim: error.displayMessage).textSelection(.enabled)
      } actions: {
        Button(LocalizedStringResource("Retry", bundle: #bundle)) { Task { await retry() } }
      }
    } else {
      ProgressView(loadingTitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct ListErrorBanner: View {
  let error: DockerError
  let controller: VMController

  var body: some View {
    let text =
      error.isConnectionFailure
      ? EngineGuidance(observation: controller.observation).message
      : error.displayMessage
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: text).textSelection(.enabled)
        Text("Showing the last list that loaded.", bundle: #bundle).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
