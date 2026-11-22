import AppKit
import ColimaCore
import SwiftUI

public struct MenuBarContentView: View {
  @Environment(\.openWindow) private var openWindow
  private let controller: VMController
  private let openMainWindow: () -> Void

  public init(controller: VMController, openMainWindow: @escaping () -> Void) {
    self.controller = controller
    self.openMainWindow = openMainWindow
  }

  public var body: some View {
    let presentation = MenuBarPresentation(
      availability: controller.dockerAvailability,
      observation: controller.observation,
      operation: controller.activeOperation,
      failure: controller.lastFailure,
      dataDiskMayRemain: controller.dataDiskMayRemain)
    VStack(alignment: .leading, spacing: 0) {
      MenuBarStatusSection(presentation: presentation)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        primaryAction(presentation.primaryAction)
        // Always mounted: a refused approval is shown by the presenter after the request is already gone.
        ConfirmationPresenter(
          origin: .menuBar,
          request: controller.pendingConfirmation,
          confirm: { controller.confirm(id: $0) },
          dismiss: { controller.dismissConfirmation() }
        )
        .padding(.horizontal, 8)
        if presentation.showsDataDiskNote {
          DataDiskNote()
        }
        abortControl
      }
      .padding(.vertical, 4)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        MenuRow(LocalizedStringResource("Open main window", bundle: #bundle), systemImage: "sidebar.left", action: openMainWindow)
        MenuRow(LocalizedStringResource("Show operation log", bundle: #bundle), systemImage: "text.alignleft") {
          OperationLogWindow.open(with: openWindow)
        }
        MenuRow(LocalizedStringResource("Quit", bundle: #bundle), systemImage: "power") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
      .padding(.vertical, 4)
    }
    .frame(width: 300)
    .onAppear(perform: menuOpened)
    .onDisappear(perform: menuClosed)
  }

  @ViewBuilder
  private func primaryAction(_ action: MenuBarPresentation.PrimaryAction) -> some View {
    switch action {
    case .start(let title):
      MenuRow(title, systemImage: "play.fill") { controller.start() }
    case .stop where !isMenuBarConfirmationPending:
      MenuRow(LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill") { controller.requestStop(from: .menuBar) }
    case .stop, .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var abortControl: some View {
    if let operation = controller.activeOperation {
      TimelineView(.periodic(from: operation.startedAt, by: 1)) { context in
        if operation.isAbortAvailable(at: context.date) {
          OperationAbortControl(abort: { controller.abortOperation() })
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
      }
    }
  }

  private var isMenuBarConfirmationPending: Bool {
    controller.pendingConfirmation?.isShown(on: .menuBar) == true
  }

  private func menuOpened() {
    Task { await controller.refreshNow() }
  }

  private func menuClosed() {
    if isMenuBarConfirmationPending {
      controller.dismissConfirmation()
    }
  }
}

private struct MenuBarStatusSection: View {
  let presentation: MenuBarPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(presentation.statusTitle)
          .font(.headline)
      } icon: {
        if presentation.isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: presentation.statusSymbol)
            .foregroundStyle(presentation.tone.color)
        }
      }
      if let detail = presentation.statusDetail {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let failureTitle = presentation.failureTitle {
        VStack(alignment: .leading, spacing: 2) {
          Label(failureTitle, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
          if let cause = presentation.failureCause {
            Text(cause)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

extension MenuBarPresentation.Tone {
  fileprivate var color: Color {
    switch self {
    case .running: .green
    case .neutral: .secondary
    case .busy: .orange
    case .caution: .red
    }
  }
}

private struct DataDiskNote: View {
  var body: some View {
    Label {
      Text("A data disk may remain. Creating the VM may reattach it.", bundle: #bundle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "externaldrive")
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

private struct MenuRow: View {
  private let title: LocalizedStringResource
  private let systemImage: String
  private let action: () -> Void
  @State private var isHovering = false
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: LocalizedStringResource, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHovering && isEnabled ? Color.accentColor.opacity(0.2) : .clear)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 4)
    .onHover { isHovering = $0 }
  }
}
