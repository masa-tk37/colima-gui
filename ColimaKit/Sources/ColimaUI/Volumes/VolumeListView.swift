import ColimaCore
import SwiftUI

public struct VolumeListView: View {
  private let store: VolumeStore
  private let controller: VMController
  @State private var sortOrder = [KeyPathComparator(\VolumeRow.volume.name)]
  @State private var selection: VolumeRow.ID?
  @State private var pruneRequestResult: PruneRequestResult?

  /// - Parameters:
  ///   - pruneRequestResult: what `requestPrune()` returned, to show "Nothing to delete" from the start in a
  ///     static preview. The result is a return value, not store state, so the view keeps it itself afterwards.
  public init(
    store: VolumeStore, controller: VMController, pruneRequestResult: PruneRequestResult? = nil
  ) {
    self.store = store
    self.controller = controller
    _pruneRequestResult = State(initialValue: pruneRequestResult)
  }

  public var body: some View {
    VStack(spacing: 0) {
      ConfirmationPresenter(
        origin: .window,
        request: store.pendingConfirmation,
        confirm: { store.confirm(id: $0) },
        dismiss: { store.dismissConfirmation() })
      ResourceListGate(
        snapshot: store.volumes,
        controller: controller,
        failureTitle: LocalizedStringResource("Can't load volumes", bundle: #bundle),
        loadingTitle: LocalizedStringResource("Loading volumes…", bundle: #bundle),
        retry: { await store.refresh() }
      ) { rows in
        VStack(spacing: 0) {
          VolumePruneStatus(
            store: store, controller: controller, pruneRequestResult: pruneRequestResult)
          if rows.isEmpty {
            ContentUnavailableView(LocalizedStringResource("No volumes", bundle: #bundle), systemImage: "externaldrive",
              description: Text("Volumes you create appear here.", bundle: #bundle))
          } else {
            table(rows)
            RemovalFailurePanel(
              failures: rows.compactMap { row in
                store.removalFailures[row.id].map { (name: row.id, message: $0) }
              })
          }
        }
      }
    }
    .navigationTitle(LocalizedStringResource("Volumes", bundle: #bundle))
    .toolbar { toolbarContent }
    .task(id: controller.dockerAvailability) { await store.refresh() }
    .onChange(of: controller.dockerAvailability) { pruneRequestResult = nil }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if store.volumes.isRefreshing {
        ProgressView().controlSize(.small)
      }
      Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash") {
        if let row = selectedRow { store.requestDelete(row) }
      }
      .disabled((selectedRow.map { store.removing.contains($0.id) } ?? true) || store.isPruning)
      .help(LocalizedStringResource("Delete the selected volume", bundle: #bundle))
      Button(LocalizedStringResource("Delete unused", bundle: #bundle), systemImage: "xmark.bin") { Task { await requestPrune() } }
        .disabled(store.isPruning || !controller.isDockerReady)
        .help(LocalizedStringResource("Delete volumes that no container uses", bundle: #bundle))
      Button(LocalizedStringResource("Refresh", bundle: #bundle), systemImage: "arrow.clockwise") {
        pruneRequestResult = nil
        Task { await store.refresh() }
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.volumes.isRefreshing || !controller.isDockerReady)
      .help(LocalizedStringResource("Refresh the volume list", bundle: #bundle))
    }
  }

  private var selectedRow: VolumeRow? {
    guard let selection else { return nil }
    return store.volumes.value?.first { $0.id == selection }
  }

  /// Same caveat as `NetworkListView.requestPrune`: `.nothingToPrune` also covers VM not ready, a running prune and
  /// unreadable candidates.
  private func requestPrune() async {
    pruneRequestResult = nil
    let result = await store.requestPrune()
    guard store.pruneRequestError == nil, controller.isDockerReady, !store.isPruning else { return }
    pruneRequestResult = result
  }

  // MARK: Table

  private func table(_ rows: [VolumeRow]) -> some View {
    let sorted = rows.sorted(using: sortOrder + [KeyPathComparator(\VolumeRow.id)])
    return Table(sorted, selection: $selection, sortOrder: $sortOrder) {
      TableColumn(LocalizedStringResource("Name", bundle: #bundle), value: \.volume.name) { row in
        nameCell(row)
      }
      .width(min: 160, ideal: 260)
      TableColumn(LocalizedStringResource("Driver", bundle: #bundle), value: \.volume.driver) { row in
        Text(verbatim: row.volume.driver)
      }
      .width(min: 60, ideal: 80)
      TableColumn(LocalizedStringResource("Created", bundle: #bundle), value: \.sortCreatedAt) { row in
        creationDate(row)
      }
      .width(min: 120, ideal: 150)
      TableColumn(LocalizedStringResource("In use", bundle: #bundle), value: \.sortUsage) { row in
        if row.isInUse {
          TagBadge(title: LocalizedStringResource("In use", bundle: #bundle), tint: .green)
        } else {
          Text("Unused", bundle: #bundle).foregroundStyle(.secondary)
        }
      }
      .width(min: 60, ideal: 80)
    }
    .alternatingRowBackgrounds(.disabled)
    .safeAreaBar(edge: .bottom) {
      ListSummaryBar(
        text: Text("\(rows.count) volumes, \(rows.count { $0.isInUse }) in use", bundle: #bundle))
    }
    .contextMenu(forSelectionType: VolumeRow.ID.self) { ids in
      if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
        Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive) { store.requestDelete(row) }
          .disabled(store.removing.contains(row.id) || store.isPruning)
      }
    }
  }

  private func nameCell(_ row: VolumeRow) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: row.volume.name)
        .lineLimit(1)
        .truncationMode(.middle)
      if row.volume.isAnonymous {
        TagBadge(title: LocalizedStringResource("Anonymous", bundle: #bundle))
          .help(LocalizedStringResource("An anonymous volume created automatically when a container was created", bundle: #bundle))
      }
      RemovalStatusCell(isRemoving: store.removing.contains(row.id), failure: store.removalFailures[row.id])
    }
    .help(row.volume.name)
  }

  @ViewBuilder
  private func creationDate(_ row: VolumeRow) -> some View {
    if let date = row.volume.createdAt {
      Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
        .help(date.formatted(.relative(presentation: .named)))
    } else {
      Text(verbatim: "—")
        .foregroundStyle(.secondary)
        .accessibilityLabel(LocalizedStringResource("Creation date unknown", bundle: #bundle))
    }
  }
}

extension VolumeRow {
  fileprivate var sortCreatedAt: Date { volume.createdAt ?? .distantPast }
  fileprivate var sortUsage: Int { isInUse ? 1 : 0 }
}
