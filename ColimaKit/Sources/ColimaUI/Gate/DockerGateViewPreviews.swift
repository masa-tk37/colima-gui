#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct GatePreview: View {
    let scenario: VMControllerPreviews.Scenario
    var engineError: DockerError?

    var body: some View {
      PreviewHost({ await VMControllerPreviews.make(scenario) }) { scene in
        DockerGateView(
          controller: scene.controller,
          engineError: engineError,
          retry: { await scene.controller.refreshNow() },
          retryRecreateResult: scene.retryResult)
      }
      .frame(width: 640, height: 560)
    }
  }

  #Preview("Colima not detected") {
    GatePreview(scenario: .colimaMissing)
  }

  #Preview("VM stopped") {
    GatePreview(scenario: .stopped)
  }

  #Preview("VM not created") {
    GatePreview(scenario: .absent)
  }

  #Preview("In progress") {
    GatePreview(scenario: .starting)
  }

  #Preview("Data disk remains") {
    GatePreview(scenario: .dataDiskMayRemain)
  }

  #Preview("Data disk remains and retry was rejected") {
    GatePreview(scenario: .dataDiskMayRemainRetryRefused)
  }

  #Preview("Engine unreachable") {
    GatePreview(scenario: .running, engineError: .engineUnreachable(detail: "connection refused"))
  }

  #Preview("VM status unreadable") {
    GatePreview(scenario: .unknown)
  }

  #Preview("Start failure") {
    GatePreview(scenario: .startFailed)
  }

  #Preview("Create failure") {
    GatePreview(scenario: .createFailed)
  }
#endif
