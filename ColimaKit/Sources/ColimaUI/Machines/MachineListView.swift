import ColimaCore
import SwiftUI

public struct MachineListView: View {
  private let controller: MachineController
  private let terminal: TerminalModel
  @State private var selection: MachineKey?
  @State private var showsCreate = false
  @State private var editing: EditTarget?

  private struct EditTarget: Identifiable {
    let name: MachineName
    var id: MachineKey { name.key }
  }

  public init(controller: MachineController, terminal: TerminalModel) {
    self.controller = controller
    self.terminal = terminal
  }

  public var body: some View {
    let presentation = MachineListPresentation(controller: controller)
    let banners = MachineBannersPresentation(controller: controller, terminal: terminal)
    VStack(spacing: 0) {
      ConfirmationPresenter(
        origin: .window,
        request: controller.pendingConfirmation,
        confirm: { controller.confirm(id: $0) },
        dismiss: { controller.dismissConfirmation() })
      if let notice = banners.notice {
        MachineNoticeBannerView(banner: notice) { controller.dismissNotice() }
      }
      if let failure = banners.shellFailure {
        ShellFailureBannerView(banner: failure) { terminal.dismissLaunchFailure() }
      }
      if let failure = presentation.readFailure {
        MachineReadFailureBanner(failure: failure) { Task { await controller.refreshNow() } }
      }
      content(presentation)
    }
    .navigationTitle(LocalizedStringResource("Machines", bundle: #bundle))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(LocalizedStringResource("Create machine", bundle: #bundle), systemImage: "plus") { showsCreate = true }
          .disabled(!presentation.canCreate)
          .help(LocalizedStringResource("Create a Linux machine", bundle: #bundle))
      }
    }
    .task { await controller.monitor() }
    .onChange(of: presentation.rows) { old, new in
      selection = MachineListPresentation.selection(selection, afterRows: old, become: new)
    }
    .sheet(isPresented: $showsCreate) { MachineCreateSheet(controller: controller) }
    .sheet(item: $editing) { MachineEditSheet(controller: controller, name: $0.name) }
  }

  @ViewBuilder
  private func content(_ presentation: MachineListPresentation) -> some View {
    switch presentation.screen {
    case .loading:
      ProgressView(LocalizedStringResource("Loading machines…", bundle: #bundle))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .limactlMissing(let searched):
      LimactlMissingView(searched: searched) { Task { await controller.refreshNow() } }
    case .noMachines:
      ContentUnavailableView {
        Label(LocalizedStringResource("No machines", bundle: #bundle), systemImage: "desktopcomputer")
      } description: {
        Text("Linux machines you create appear here.", bundle: #bundle)
      } actions: {
        Button(LocalizedStringResource("Create machine", bundle: #bundle)) { showsCreate = true }
          .disabled(!presentation.canCreate)
      }
    case .readFailedWithoutList:
      Spacer()
    case .table:
      VSplitView {
        table(presentation.rows)
        detail(presentation)
      }
    }
  }

  private func table(_ rows: [MachineRow]) -> some View {
    Table(rows, selection: $selection) {
      TableColumn(LocalizedStringResource("Name", bundle: #bundle)) { row in
        HStack(spacing: 6) {
          Text(verbatim: MachineRowCells(row: row).name).fontWeight(.medium).lineLimit(1)
          if controller.failures[row.id] != nil {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .help(LocalizedStringResource("The last operation on this machine failed", bundle: #bundle))
          }
        }
      }
      .width(min: 100, ideal: 140)
      TableColumn(LocalizedStringResource("Status", bundle: #bundle)) { row in
        MachineStateBadge(state: MachineRowCells(row: row).state)
      }
      .width(min: 90, ideal: 110)
      TableColumn(LocalizedStringResource("Distribution", bundle: #bundle)) { row in
        Text(verbatim: MachineRowCells(row: row).distribution).lineLimit(1)
      }
      .width(min: 100, ideal: 150)
      TableColumn(LocalizedStringResource("CPU", bundle: #bundle)) { row in
        Text(verbatim: MachineRowCells(row: row).cpu).monospacedDigit()
      }
      .width(min: 40, ideal: 50)
      TableColumn(LocalizedStringResource("Memory", bundle: #bundle)) { row in
        Text(verbatim: MachineRowCells(row: row).memory).monospacedDigit()
      }
      .width(min: 70, ideal: 80)
      TableColumn(LocalizedStringResource("Disk", bundle: #bundle)) { row in
        Text(verbatim: MachineRowCells(row: row).disk).monospacedDigit()
      }
      .width(min: 70, ideal: 80)
      TableColumn(Text(verbatim: "")) { row in
        MachineRowActions(name: row.name, state: MachineRowActionState(row: row, controller: controller), handlers: handlers)
      }
      .width(min: 170, ideal: 170)
    }
    .alternatingRowBackgrounds(.disabled)
    .contextMenu(forSelectionType: MachineKey.self) { keys in
      if let row = keys.first.flatMap({ MachineListPresentation.selectedRow($0, in: rows) }) {
        MachineRowMenu(name: row.name, state: MachineRowActionState(row: row, controller: controller), handlers: handlers)
      }
    }
    .frame(minHeight: 120)
  }

  @ViewBuilder
  private func detail(_ presentation: MachineListPresentation) -> some View {
    let row = MachineListPresentation.selectedRow(selection, in: presentation.rows)
    switch MachineListPresentation.detail(for: row, operationsAreEmpty: operationsAreEmpty(row)) {
    case .none:
      EmptyView()
    case .operations(let name):
      MachineOperationPanel(controller: controller, name: name)
    case .brokenErrors(_, let errors):
      MachineBrokenErrors(errors: errors)
    }
  }

  private func operationsAreEmpty(_ row: MachineRow?) -> Bool {
    guard let key = row?.id, let name = row?.name else { return true }
    return MachineOperationPresentation(
      progress: controller.operations[key], record: controller.records[key], failure: controller.failures[key],
      canCancel: controller.canCancelCreate(name)
    ).isEmpty
  }

  private var handlers: MachineRowHandlers {
    MachineRowHandlers(
      start: { name in
        selection = name.key
        controller.requestStart(name)
      },
      stop: { name in
        selection = name.key
        controller.stop(name)
      },
      openShell: { name in Task { await terminal.openShell(for: name) } },
      edit: { editing = EditTarget(name: $0) },
      delete: { controller.requestDelete($0) },
      cancelCreate: { controller.cancelCreate($0) })
  }
}

struct MachineStateBadge: View {
  let state: MachineStatePresentation

  var body: some View {
    Label {
      Text(verbatim: state.label).font(.callout)
    } icon: {
      Image(systemName: state.symbol)
        .font(.system(size: 8))
        .foregroundStyle(tint)
    }
    .accessibilityLabel(LocalizedStringResource("Status: \(state.label)", bundle: #bundle))
  }

  private var tint: Color {
    switch state.tone {
    case .running: .green
    case .stopped: .secondary
    case .transitional: .orange
    case .attention: .red
    }
  }
}

private struct MachineReadFailureBanner: View {
  let failure: MachineListPresentation.ReadFailure
  let retry: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Label {
            Text("Couldn't read the machines", bundle: #bundle).font(.headline)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Spacer()
          Button(LocalizedStringResource("Retry", bundle: #bundle), action: retry)
        }
        if let summary = failure.summary {
          Text(verbatim: summary).textSelection(.enabled)
        }
        if !failure.output.isEmpty {
          ScrollView {
            Text(verbatim: failure.output.joined(separator: "\n"))
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
        }
      }
    }
    .padding(12)
    .accessibilityElement(children: .contain)
  }
}

private struct LimactlMissingView: View {
  let searched: [String]
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(LocalizedStringResource("limactl not found", bundle: #bundle), systemImage: "exclamationmark.triangle")
    } description: {
      VStack(spacing: 8) {
        Text("limactl was not found. Install Lima, then try again.", bundle: #bundle)
        if !searched.isEmpty {
          Text("Searched locations", bundle: #bundle).font(.subheadline)
          VStack(spacing: 2) {
            ForEach(searched, id: \.self) { path in
              Text(verbatim: path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }
          }
        }
      }
    } actions: {
      Button(LocalizedStringResource("Retry", bundle: #bundle), action: retry)
    }
  }
}

private struct MachineBrokenErrors: View {
  let errors: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text("Couldn't read this machine", bundle: #bundle).font(.headline)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      ScrollView {
        Text(verbatim: errors.joined(separator: "\n"))
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 120)
  }
}
