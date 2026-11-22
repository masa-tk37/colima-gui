#if DEBUG
  import SwiftUI

  private struct ListPreview: View {
    let scenario: VolumeStorePreviews.Scenario

    var body: some View {
      PreviewHost({ await VolumeStorePreviews.make(scenario) }) { scene in
        NavigationStack {
          VolumeListView(
            store: scene.store, controller: scene.controller,
            pruneRequestResult: scene.pruneRequestResult)
        }
      }
      .frame(width: 780, height: 520)
    }
  }

  #Preview("List: in use, unused, anonymous, no creation date") {
    ListPreview(scenario: .listed)
  }

  #Preview("List: before first load") {
    ListPreview(scenario: .notLoaded)
  }

  #Preview("List: empty") {
    ListPreview(scenario: .empty)
  }

  #Preview("List: delete confirmation") {
    ListPreview(scenario: .pendingDelete)
  }

  #Preview("List: delete failure (volume in use)") {
    ListPreview(scenario: .removalFailed)
  }

  #Preview("List: nothing to prune") {
    ListPreview(scenario: .noPruneCandidates)
  }

  #Preview("List: prune candidates unavailable") {
    ListPreview(scenario: .pruneRequestFailed)
  }

  #Preview("List: prune confirmation (anonymous and named)") {
    ListPreview(scenario: .pendingPrune)
  }

  #Preview("List: pruning") {
    ListPreview(scenario: .pruning)
  }

  #Preview("List: prune result (with unknown sizes and failures)") {
    ListPreview(scenario: .pruneResult)
  }
#endif
