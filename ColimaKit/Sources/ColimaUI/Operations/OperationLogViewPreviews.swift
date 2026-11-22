#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct OperationLogPreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMControllerPreviews.make(scenario) }) { scene in
        OperationLogView(controller: scene.controller)
      }
      .frame(width: 640, height: 360)
    }
  }

  #Preview("No operation yet") {
    OperationLogPreview(scenario: .running)
  }

  #Preview("Start streaming output") {
    OperationLogPreview(scenario: .starting)
  }

  #Preview("Start failed") {
    OperationLogPreview(scenario: .startFailed)
  }

  #Preview("Create failed") {
    OperationLogPreview(scenario: .createFailed)
  }
#endif
