#if DEBUG
  import SwiftUI

  private struct ListPreview: View {
    let scenario: ImageStorePreviews.Scenario

    var body: some View {
      PreviewHost({ await ImageStorePreviews.make(scenario) }) { scene in
        NavigationStack {
          ImageListView(store: scene.store, controller: scene.controller)
        }
      }
      .frame(width: 780, height: 480)
    }
  }

  #Preview("List: image with two tags, registry with port, untagged") {
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

  #Preview("List: deleting") {
    ListPreview(scenario: .removing)
  }

  #Preview("List: delete failure") {
    ListPreview(scenario: .removalFailed)
  }

  #Preview("List: load failure (no list)") {
    ListPreview(scenario: .listFailed)
  }
#endif
