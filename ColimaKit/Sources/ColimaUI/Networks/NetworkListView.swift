import ColimaCore
import SwiftUI

public struct NetworkListView: View {
  private let store: NetworkStore
  private let controller: VMController
  @State private var sortOrder = [KeyPathComparator(\NetworkSummary.name)]
  @State private var showsCreateSheet = false
  @State private var pruneRequestResult: PruneRequestResult?

  /// - Parameters:
  ///   - pruneRequestResult: what `requestPrune()` returned, to show "Nothing to delete" from the start in a
  ///     static preview. The result is a return value, not store state, so the view keeps it itself afterwards.
  public init(
    store: NetworkStore, controller: VMController, pruneRequestResult: PruneRequestResult? = nil
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
        snapshot: store.networks,
        controller: controller,
        failureTitle: LocalizedStringResource("Can't load networks", bundle: #bundle),
        loadingTitle: LocalizedStringResource("Loading networks…", bundle: #bundle),
        retry: { await store.refresh() }
      ) { rows in
        VStack(spacing: 0) {
          NetworkPruneStatus(
            store: store, controller: controller, pruneRequestResult: pruneRequestResult)
          if rows.isEmpty {
            ContentUnavailableView {
              Label(LocalizedStringResource("No networks", bundle: #bundle), systemImage: "network")
            } description: {
              Text("Networks you create appear here.", bundle: #bundle)
            } actions: {
              Button(LocalizedStringResource("Create network", bundle: #bundle)) { showsCreateSheet = true }
            }
          } else {
            table(rows)
            RemovalFailurePanel(
              failures: rows.compactMap { summary in
                store.removalFailures[summary.id].map { (name: summary.name, message: $0) }
              })
          }
        }
      }
    }
    .inspector(isPresented: inspectorPresented) {
      if let summary = selectedSummary {
        NetworkDetailView(store: store, controller: controller, summary: summary)
          .id(summary.id)
          .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
      }
    }
    .sheet(isPresented: $showsCreateSheet) { NetworkCreateSheet(store: store) }
    .navigationTitle(LocalizedStringResource("Networks", bundle: #bundle))
    .toolbar { toolbarContent }
    // A `store.monitor()` round does nothing until Docker is ready.
    .task { await store.monitor() }
    .onChange(of: controller.dockerAvailability) { pruneRequestResult = nil }
  }

  // MARK: Selection

  /// Selection goes through `store.select(_:)`, which fetches the detail; the store also clears it on deletion.
  private var selection: Binding<NetworkID?> {
    Binding(get: { store.selectedID }, set: { store.select($0) })
  }

  private var selectedSummary: NetworkSummary? {
    guard let id = store.selectedID else { return nil }
    return store.networks.value?.first { $0.id == id }
  }

  private var inspectorPresented: Binding<Bool> {
    Binding(
      get: { controller.isDockerReady && selectedSummary != nil },
      set: { if !$0 { store.select(nil) } })
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if store.networks.isRefreshing {
        ProgressView().controlSize(.small)
      }
      Button(LocalizedStringResource("Create", bundle: #bundle), systemImage: "plus") { showsCreateSheet = true }
        .disabled(!controller.isDockerReady)
        .help(LocalizedStringResource("Create network", bundle: #bundle))
      if selectedSummary.map(store.canDelete) ?? true {
        Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash") {
          if let summary = selectedSummary { store.requestDelete(summary) }
        }
        .disabled(isDeleteDisabled)
        .help(LocalizedStringResource("Delete the selected network", bundle: #bundle))
      }
      Button(LocalizedStringResource("Delete unused", bundle: #bundle), systemImage: "xmark.bin") { Task { await requestPrune() } }
        .disabled(store.isPruning || !controller.isDockerReady)
        .help(LocalizedStringResource("Delete networks that no running container is connected to", bundle: #bundle))
      Button(LocalizedStringResource("Refresh", bundle: #bundle), systemImage: "arrow.clockwise") {
        pruneRequestResult = nil
        Task { await store.refresh() }
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.networks.isRefreshing || !controller.isDockerReady)
      .help(LocalizedStringResource("Refresh the network list", bundle: #bundle))
    }
  }

  private var isDeleteDisabled: Bool {
    guard let summary = selectedSummary else { return true }
    return store.removing.contains(summary.id) || store.isPruning
  }

  /// `.nothingToPrune` is also returned when the VM was not ready, a prune was running or the candidates could not
  /// be read, so it is kept only when none of those held.
  private func requestPrune() async {
    pruneRequestResult = nil
    let result = await store.requestPrune()
    guard store.pruneRequestError == nil, controller.isDockerReady, !store.isPruning else { return }
    pruneRequestResult = result
  }

  // MARK: Table

  private func table(_ rows: [NetworkSummary]) -> some View {
    let sorted = rows.sorted(using: sortOrder + [KeyPathComparator(\NetworkSummary.id.rawValue)])
    return Table(sorted, selection: selection, sortOrder: $sortOrder) {
      TableColumn(LocalizedStringResource("Name", bundle: #bundle), value: \.name) { summary in
        nameCell(summary)
      }
      .width(min: 140, ideal: 220)
      TableColumn(LocalizedStringResource("Driver", bundle: #bundle), value: \.driver) { summary in
        Text(verbatim: summary.driver)
          .font(.caption.monospaced())
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(.quaternary, in: .capsule)
      }
      .width(min: 60, ideal: 80)
      TableColumn(LocalizedStringResource("Scope", bundle: #bundle), value: \.scope) { summary in
        Text(verbatim: summary.scope)
      }
      .width(min: 60, ideal: 70)
      TableColumn(LocalizedStringResource("Subnet", bundle: #bundle)) { summary in
        addressList(summary.ipam.compactMap(\.subnet))
      }
      .width(min: 110, ideal: 150)
      TableColumn(LocalizedStringResource("Gateway", bundle: #bundle)) { summary in
        addressList(summary.ipam.compactMap(\.gateway))
      }
      .width(min: 100, ideal: 130)
    }
    .alternatingRowBackgrounds(.disabled)
    .safeAreaBar(edge: .bottom) {
      ListSummaryBar(
        text: Text(
          "\(rows.count) networks, \(rows.count { $0.deletableID == nil }) built in", bundle: #bundle))
    }
    .contextMenu(forSelectionType: NetworkID.self) { ids in
      if let id = ids.first, let summary = rows.first(where: { $0.id == id }),
        store.canDelete(summary)
      {
        Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive) { store.requestDelete(summary) }
          .disabled(store.removing.contains(summary.id) || store.isPruning)
      }
    }
  }

  private func nameCell(_ summary: NetworkSummary) -> some View {
    let isBuiltIn = summary.deletableID == nil
    return HStack(spacing: 6) {
      Text(verbatim: summary.name)
        .foregroundStyle(isBuiltIn ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(summary.name)
      if isBuiltIn {
        TagBadge(title: LocalizedStringResource("Built in", bundle: #bundle))
          .help(LocalizedStringResource("Created by Docker; it can't be deleted", bundle: #bundle))
      }
      RemovalStatusCell(
        isRemoving: store.removing.contains(summary.id), failure: store.removalFailures[summary.id])
    }
  }

  /// Networks without IPAM (`host`, `none`) have no address; a network may also have several pools.
  @ViewBuilder
  private func addressList(_ values: [String]) -> some View {
    if values.isEmpty {
      Text(verbatim: "—")
        .foregroundStyle(.secondary)
        .accessibilityLabel(LocalizedStringResource("None", bundle: #bundle))
    } else {
      Text(verbatim: values.joined(separator: ", "))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(values.joined(separator: "\n"))
    }
  }
}
