#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct FailurePreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost({ await VMControllerPreviews.make(scenario) }) { scene in
        if let failure = scene.controller.lastFailure {
          OperationFailureView(failure: failure)
        }
      }
      .padding()
      .frame(width: 520, height: 360, alignment: .topLeading)
    }
  }

  #Preview("Start failure with output tail") {
    FailurePreview(scenario: .startFailed)
  }

  #Preview("Create failure") {
    FailurePreview(scenario: .createFailed)
  }

  #Preview("Create failure: missing executables") {
    FailurePreview(scenario: .createFailedMissingExecutables)
  }

  #Preview("Start aborted") {
    FailurePreview(scenario: .startAborted)
  }

  #Preview("Failure at the delete stage") {
    FailurePreview(scenario: .dataDiskMayRemain)
  }
#endif
