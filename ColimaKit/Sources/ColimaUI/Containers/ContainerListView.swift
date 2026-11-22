import ColimaCore
import SwiftUI

public struct ContainerListView: View {
  private let store: ContainerStore
  private let controller: VMController
  private let slots: ContainerOperationSlots
  @Binding private var selection: ContainerID?
  @State private var notices: [ContainerID: DeleteNotice] = [:]
  /// One name per line: a Compose project name cannot contain a newline.
  @AppStorage("containers.collapsedProjects") private var collapsedProjects = ""

  /// - Parameters:
  ///   - slots: the instance the store was created with; it tells which containers have an operation running.
  ///   - selection: the selected container, for the owner to open its detail.
  public init(
    store: ContainerStore,
    controller: VMController,
    slots: ContainerOperationSlots,
    selection: Binding<ContainerID?>
  ) {
    self.store = store
    self.controller = controller
    self.slots = slots
    _selection = selection
  }

  public var body: some View {
    VStack(spacing: 0) {
      ConfirmationPresenter(
        origin: .window,
        request: store.pendingConfirmation,
        confirm: { store.confirm(id: $0) },
        dismiss: { store.dismissConfirmation() })
      content
    }
    .task { await store.monitor() }
    .onChange(of: store.projectOutcomes) { old, new in
      for name in Self.projectsWithNewFailures(old: old, new: new) {
        setExpanded(true, name)
      }
    }
  }

  private var content: some View {
    ResourceListGate(
      snapshot: store.containers,
      controller: controller,
      failureTitle: LocalizedStringResource("Can't load containers", bundle: #bundle),
      loadingTitle: LocalizedStringResource("Loading containers…", bundle: #bundle)
    ) {
      await store.refresh()
    } content: { containers in
      if containers.isEmpty {
        ContentUnavailableView(LocalizedStringResource("No containers", bundle: #bundle), systemImage: "shippingbox",
          description: Text("Containers you create appear here.", bundle: #bundle))
      } else {
        list
      }
    }
  }

  private var list: some View {
    let groups = store.groups
    return List(selection: $selection) {
      ForEach(groups.projects, id: \.name) { project in
        ComposeProjectSection(
          project: project,
          outcome: store.projectOutcomes[project.name],
          operationFailures: store.operationFailures,
          slots: slots,
          notices: notices,
          actions: actions,
          isExpanded: isExpanded(project.name))
      }
      if !groups.ungrouped.isEmpty {
        Section {
          ForEach(groups.ungrouped) { container in
            ContainerRow(
              container: container,
              isOperating: slots.isBusy(container.id),
              failure: store.operationFailures[container.id],
              notice: notices[container.id],
              actions: actions)
          }
        } header: {
          HStack(spacing: 10) {
            Label {
              Text("Containers without a project", bundle: #bundle)
                .font(.headline)
                .foregroundStyle(.primary)
            } icon: {
              Image(systemName: "shippingbox").foregroundStyle(.secondary)
            }
            Text("\(groups.ungrouped.count) containers", bundle: #bundle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .textCase(nil)
        }
      }
    }
  }

  private var collapsed: Set<String> {
    Set(collapsedProjects.split(separator: "\n").map(String.init))
  }

  private func isExpanded(_ name: String) -> Binding<Bool> {
    Binding(
      get: { !collapsed.contains(name) },
      set: { setExpanded($0, name) })
  }

  private func setExpanded(_ expanded: Bool, _ name: String) {
    var names = collapsed
    if expanded { names.remove(name) } else { names.insert(name) }
    collapsedProjects = names.sorted().joined(separator: "\n")
  }

  /// A batch's failures are shown inside the section, so a collapsed project must open when a new one arrives.
  static func projectsWithNewFailures(
    old: [String: BatchOutcome<ContainerID>], new: [String: BatchOutcome<ContainerID>]
  ) -> Set<String> {
    Set(new.filter { name, outcome in !outcome.failed.isEmpty && old[name] != outcome }.keys)
  }

  private var actions: ContainerListActions {
    ContainerListActions(
      perform: { action, id in
        notices[id] = nil
        store.perform(action, on: id)
      },
      delete: { id in
        notices[id] = nil
        switch store.requestDelete(id) {
        case .confirmationRequested: break
        case .mustStopFirst: notices[id] = .stopFirst
        case .busy: notices[id] = .busy
        }
      },
      performProject: { action, project in
        store.performProject(action, on: project)
      })
  }
}
