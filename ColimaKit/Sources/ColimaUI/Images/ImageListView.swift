import ColimaCore
import SwiftUI

public struct ImageListView: View {
  private let store: ImageStore
  private let controller: VMController
  @State private var sortOrder = [KeyPathComparator(\ImageRow.created, order: .reverse)]
  @State private var selection: ImageRow.ID?

  public init(store: ImageStore, controller: VMController) {
    self.store = store
    self.controller = controller
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
    .navigationTitle(LocalizedStringResource("Images", bundle: #bundle))
    .toolbar { toolbarContent }
    .task(id: controller.dockerAvailability) { await store.refresh() }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if store.images.isRefreshing {
        ProgressView().controlSize(.small)
      }
      Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash") {
        if let row = selectedRow { store.requestDelete(row) }
      }
      .disabled(selectedRow.map { store.removing.contains($0.reference) } ?? true)
      .help(LocalizedStringResource("Delete the selected image", bundle: #bundle))
      Button(LocalizedStringResource("Refresh", bundle: #bundle), systemImage: "arrow.clockwise") { Task { await store.refresh() } }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.images.isRefreshing || controller.dockerAvailability != .ready)
        .help(LocalizedStringResource("Refresh the image list", bundle: #bundle))
    }
  }

  private var selectedRow: ImageRow? {
    guard let selection else { return nil }
    return store.images.value?.first { $0.id == selection }
  }

  private var content: some View {
    ResourceListGate(
      snapshot: store.images,
      controller: controller,
      failureTitle: LocalizedStringResource("Can't load images", bundle: #bundle),
      loadingTitle: LocalizedStringResource("Loading images…", bundle: #bundle)
    ) {
      await store.refresh()
    } content: { rows in
      if rows.isEmpty {
        ContentUnavailableView(LocalizedStringResource("No images", bundle: #bundle), systemImage: "square.stack.3d.up",
          description: Text("Images you pull appear here.", bundle: #bundle))
      } else {
        table(rows)
        RemovalFailurePanel(
          failures: rows.compactMap { row in
            store.removalFailures[row.reference].map { (name: row.reference.value, message: $0) }
          })
      }
    }
  }

  private func table(_ rows: [ImageRow]) -> some View {
    let sorted = rows.sorted(using: sortOrder + [KeyPathComparator(\ImageRow.id)])
    return Table(sorted, selection: $selection, sortOrder: $sortOrder) {
      TableColumn(LocalizedStringResource("Repository", bundle: #bundle), value: \.repository) { row in
        HStack(spacing: 6) {
          nameText(row.repository)
          // Shown only while deleting or after a failure, so it needs no column of its own.
          RemovalStatusCell(
            isRemoving: store.removing.contains(row.reference),
            failure: store.removalFailures[row.reference])
        }
      }
      TableColumn(LocalizedStringResource("Tag", bundle: #bundle), value: \.tag) { row in
        nameText(row.tag)
      }
      .width(min: 60, ideal: 90)
      TableColumn(LocalizedStringResource("Size", bundle: #bundle), value: \.size) { row in
        Text(row.size, format: .byteCount(style: .file))
          .monospacedDigit()
      }
      .width(min: 70, ideal: 90)
      TableColumn(LocalizedStringResource("Created", bundle: #bundle), value: \.created) { row in
        Text(row.created, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
          .help(row.created.formatted(.relative(presentation: .named)))
      }
      .width(min: 120, ideal: 150)
      TableColumn(LocalizedStringResource("Used by", bundle: #bundle)) { row in
        usage(store.containerCount(for: row))
      }
      .width(min: 80, ideal: 110)
    }
    .alternatingRowBackgrounds(.disabled)
    .safeAreaBar(edge: .bottom) { ListSummaryBar(text: summary(rows)) }
    .contextMenu(forSelectionType: ImageRow.ID.self) { ids in
      if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
        Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive) { store.requestDelete(row) }
          .disabled(store.removing.contains(row.reference))
      }
    }
  }

  /// Stopped containers count too: the engine refuses to delete an image any container still references.
  @ViewBuilder
  private func usage(_ count: Int?) -> some View {
    switch count {
    case nil:
      Text(verbatim: "—").foregroundStyle(.secondary)
        .help(LocalizedStringResource("Could not read the container list", bundle: #bundle))
    case 0?:
      Text("Unused", bundle: #bundle).foregroundStyle(.secondary)
    case let count?:
      TagBadge(title: LocalizedStringResource("\(count) containers", bundle: #bundle), tint: .green)
    }
  }

  /// One image can have several tag rows, so the size counts each image ID once.
  private func summary(_ rows: [ImageRow]) -> Text {
    var sizes: [String: Int64] = [:]
    for row in rows { sizes[row.imageID] = row.size }
    let total = sizes.values.reduce(0, +).formatted(.byteCount(style: .file))
    return Text("\(sizes.count) images, \(total) in total", bundle: #bundle)
  }

  private func nameText(_ name: String) -> some View {
    Text(verbatim: name)
      .foregroundStyle(name == ImageRow.noneLabel ? .secondary : .primary)
      .lineLimit(1)
      .truncationMode(.middle)
  }
}
