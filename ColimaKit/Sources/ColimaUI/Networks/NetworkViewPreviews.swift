#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct ListPreview: View {
    let scenario: NetworkStorePreviews.Scenario

    var body: some View {
      PreviewHost {
        await NetworkStorePreviews.make(scenario)
      } content: { scene in
        NavigationStack {
          NetworkListView(
            store: scene.store, controller: scene.controller,
            pruneRequestResult: scene.pruneRequestResult)
        }
      }
      .frame(width: 1000, height: 560)
    }
  }

  private struct CreateSheetPreview: View {
    let scenario: NetworkStorePreviews.Scenario
    let form: NetworkCreateForm

    var body: some View {
      PreviewHost {
        await NetworkStorePreviews.make(scenario)
      } content: { scene in
        NetworkCreateSheet(store: scene.store, form: form, result: scene.createResult)
      }
    }
  }

  #Preview("List: built-in and created networks") {
    ListPreview(scenario: .listed)
  }

  #Preview("List: before first load") {
    ListPreview(scenario: .notLoaded)
  }

  #Preview("List: empty") {
    ListPreview(scenario: .empty)
  }

  #Preview("List: load failure") {
    ListPreview(scenario: .listFailed)
  }

  #Preview("Detail: three connected containers") {
    ListPreview(scenario: .detailSelected)
  }

  #Preview("Detail: no connected containers") {
    ListPreview(scenario: .detailEmpty)
  }

  #Preview("Built-in network: no delete") {
    ListPreview(scenario: .builtInSelected)
  }

  #Preview("Create sheet error: empty name and invalid subnet") {
    CreateSheetPreview(
      scenario: .createFieldErrors, form: NetworkCreateForm(name: "", subnet: "not-a-subnet"))
  }

  #Preview("Create sheet error: duplicate name") {
    CreateSheetPreview(
      scenario: .createNameTaken, form: NetworkCreateForm(name: "dev-net", subnet: ""))
  }

  #Preview("Create sheet: engine refused") {
    CreateSheetPreview(
      scenario: .createFailed, form: NetworkCreateForm(name: "staging-net", subnet: "172.31.0.0/16")
    )
  }

  #Preview("Create sheet: creating") {
    CreateSheetPreview(
      scenario: .creating, form: NetworkCreateForm(name: "staging-net", subnet: ""))
  }

  #Preview("List: delete confirmation") {
    ListPreview(scenario: .pendingDelete)
  }

  #Preview("List: delete failure (network in use)") {
    ListPreview(scenario: .deleteFailed)
  }

  #Preview("List: prune confirmation") {
    ListPreview(scenario: .pendingPrune)
  }

  #Preview("List: nothing to prune") {
    ListPreview(scenario: .noPruneCandidates)
  }

  #Preview("List: prune candidates unavailable") {
    ListPreview(scenario: .pruneRequestFailed)
  }

  #Preview("List: prune result (with failures)") {
    ListPreview(scenario: .pruneResult)
  }

  #Preview("Detail: disconnect confirmation") {
    ListPreview(scenario: .pendingDisconnect)
  }

  #Preview("Detail: disconnect failure") {
    ListPreview(scenario: .disconnectFailed)
  }
#endif
