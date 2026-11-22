#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct ListPreview: View {
    let scenario: ContainerStorePreviews.Scenario
    var width: CGFloat = 780
    @State private var selection: ContainerID?

    var body: some View {
      PreviewHost({ await ContainerStorePreviews.make(scenario) }) { scene in
        ContainerListView(
          store: scene.store, controller: scene.controller, slots: scene.slots,
          selection: $selection)
      }
      .frame(width: width, height: 560)
    }
  }

  /// `ContainerListView` keeps the expansion in app storage; a single section takes it as a binding instead.
  private struct CollapsedProjectPreview: View {
    var body: some View {
      PreviewHost({ await ContainerStorePreviews.make(.partialFailure) }) { scene in
        List {
          ForEach(scene.store.groups.projects, id: \.name) { project in
            ComposeProjectSection(
              project: project, outcome: scene.store.projectOutcomes[project.name],
              operationFailures: scene.store.operationFailures, slots: scene.slots, notices: [:],
              actions: ContainerListActions(perform: { _, _ in }, delete: { _ in }, performProject: { _, _ in }),
              isExpanded: .constant(false))
          }
        }
      }
      .frame(width: 480, height: 300)
    }
  }

  #Preview("List: the app's list width (480pt)") {
    ListPreview(scenario: .listed, width: 480)
  }

  #Preview("List: narrowest list width (420pt) with an operation in progress") {
    ListPreview(scenario: .operating, width: 420)
  }

  #Preview("Projects collapsed") {
    CollapsedProjectPreview()
  }

  #Preview("List: three project states (all running, partially running, all stopped) and unlabeled") {
    ListPreview(scenario: .listed)
  }

  #Preview("List: unlabeled only") {
    ListPreview(scenario: .unlabeledOnly)
  }

  #Preview("List: operation in progress") {
    ListPreview(scenario: .operating)
  }

  #Preview("List: partial failure") {
    ListPreview(scenario: .partialFailure)
  }

  #Preview("List: operation failure") {
    ListPreview(scenario: .operationFailed)
  }

  #Preview("List: delete confirmation") {
    ListPreview(scenario: .pendingDelete)
  }

  #Preview("List: delete failure") {
    ListPreview(scenario: .deleteFailed)
  }

  #Preview("List: empty") {
    ListPreview(scenario: .empty)
  }

  #Preview("List: before first load") {
    ListPreview(scenario: .notLoaded)
  }

  #Preview("List: load failure (no list)") {
    ListPreview(scenario: .listFailed)
  }

  #Preview("List: load failure (keeping previous list)") {
    ListPreview(scenario: .listFailedKeepingList)
  }

  #Preview("List: engine unreachable") {
    ListPreview(scenario: .engineUnreachable)
  }
#endif
