#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct PresenterPreview: View {
    let scenario: ConfirmationPreviews.Scenario
    let origin: ConfirmationOrigin

    var body: some View {
      PreviewHost {
        await ConfirmationPreviews.make(scenario)
      } content: { scene in
        ConfirmationPresenter(
          origin: origin,
          request: scene.request,
          rejectionReason: scene.rejectionReason,
          confirm: { scene.confirm($0) },
          dismiss: { scene.dismiss() }
        )
        .padding()
        .frame(width: 420, height: 320, alignment: .topLeading)
      }
    }
  }

  #Preview("Window confirmation pending") {
    PresenterPreview(scenario: .stopFromWindow, origin: .window)
  }

  #Preview("Window confirmation pending (with items)") {
    PresenterPreview(scenario: .pruneVolumes, origin: .window)
  }

  #Preview("Menu bar confirmation pending") {
    PresenterPreview(scenario: .stopFromMenuBar, origin: .menuBar)
  }

  #Preview("With approval rejection reason") {
    PresenterPreview(scenario: .approvalRejected, origin: .window)
  }
#endif
