#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct OperationPreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMControllerPreviews.make(scenario) }) { scene in
        if let operation = scene.controller.activeOperation {
          OperationOutputView(
            operation: operation, record: scene.controller.latestRecord,
            abort: { scene.controller.abortOperation() })
        }
      }
      .padding()
      .frame(width: 460, height: 380, alignment: .topLeading)
    }
  }

  #Preview("Long wait with no output") {
    OperationPreview(scenario: .startingNoOutputYet)
  }

  #Preview("Output stalled while elapsed time advances") {
    OperationPreview(scenario: .startingSilentForAWhile)
  }

  #Preview("Abort available") {
    OperationPreview(scenario: .startingAbortable)
  }

  #Preview("Start with streaming output") {
    OperationPreview(scenario: .starting)
  }
#endif
