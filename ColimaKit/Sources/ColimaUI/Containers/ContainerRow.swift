import ColimaCore
import SwiftUI

struct ContainerListActions {
  let perform: @MainActor (ContainerAction, ContainerID) -> Void
  let delete: @MainActor (ContainerID) -> Void
  let performProject: @MainActor (ContainerAction, String) -> Void
}

enum DeleteNotice: Equatable {
  case stopFirst
  case busy

  var message: LocalizedStringResource {
    switch self {
    case .stopFirst: LocalizedStringResource("A running container can't be deleted. Stop it first.", bundle: #bundle)
    case .busy: LocalizedStringResource("This container is busy, so it can't be deleted now.", bundle: #bundle)
    }
  }
}

struct ContainerRow: View {
  let container: ContainerSummary
  let isOperating: Bool
  let failure: ContainerOperationFailure?
  let notice: DeleteNotice?
  let actions: ContainerListActions

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        ContainerStateBadge(state: container.state)
          .frame(width: 84, alignment: .leading)
        // Ports sit under the name instead of in their own column, so the row's controls keep their full size in the list's limited width.
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: container.name)
            .fontWeight(.medium)
          Text(verbatim: container.image)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: container.ports.displayText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help(LocalizedStringResource("Published ports", bundle: #bundle))
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        if isOperating {
          Label(LocalizedStringResource("In progress", bundle: #bundle), systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
          ProgressView().controlSize(.small)
        }
        buttons
          .fixedSize()
      }
      if let failure {
        Label {
          Text(failure.operation.failureText(detail: failure.message))
            .textSelection(.enabled)
        } icon: {
          Image(systemName: "xmark.octagon.fill")
        }
        .font(.caption)
        .foregroundStyle(.red)
      }
      if let notice, noticeApplies(notice) {
        Label(notice.message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .contextMenu {
      Button(LocalizedStringResource("Start", bundle: #bundle), systemImage: "play.fill") { actions.perform(.start, container.id) }
        .disabled(!canStart)
      Button(LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill") { actions.perform(.stop, container.id) }
        .disabled(!canStop)
      Button(LocalizedStringResource("Restart", bundle: #bundle), systemImage: "arrow.clockwise") { actions.perform(.restart, container.id) }
        .disabled(!canStop)
      Divider()
      Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive) { actions.delete(container.id) }
        .disabled(isOperating)
    }
  }

  private var buttons: some View {
    HStack(spacing: 6) {
      if container.state.isRunning {
        CircleActionButton(
          title: LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill", isEnabled: canStop
        ) { actions.perform(.stop, container.id) }
      } else {
        CircleActionButton(
          title: LocalizedStringResource("Start", bundle: #bundle), systemImage: "play.fill", isEnabled: canStart
        ) { actions.perform(.start, container.id) }
      }
      CircleActionButton(
        title: LocalizedStringResource("Restart", bundle: #bundle), systemImage: "arrow.clockwise",
        isEnabled: canStop
      ) { actions.perform(.restart, container.id) }
      CircleActionButton(
        title: LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive,
        isEnabled: !isOperating
      ) { actions.delete(container.id) }
    }
  }

  private var canStart: Bool { !isOperating && !container.state.isRunning }
  private var canStop: Bool { !isOperating && container.state.isRunning }

  private func noticeApplies(_ notice: DeleteNotice) -> Bool {
    switch notice {
    case .stopFirst: container.state.isRunning
    case .busy: isOperating
    }
  }
}

struct ContainerStateBadge: View {
  let state: ContainerState

  var body: some View {
    Label {
      Text(verbatim: state.displayName)
        .font(.callout)
    } icon: {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(state.isRunning ? Color.green : Color.secondary)
    }
    .accessibilityLabel(LocalizedStringResource("Status: \(state.displayName)", bundle: #bundle))
  }
}

extension ContainerState {
  var displayName: String {
    switch self {
    // Own keys: the VM states and the list columns share these English words but not their Japanese.
    case .running: String(localized: "containerState.running", defaultValue: "Running", bundle: #bundle)
    case .other(let rawState):
      switch rawState {
      case "exited": String(localized: "containerState.exited", defaultValue: "Stopped", bundle: #bundle)
      case "created": String(localized: "containerState.created", defaultValue: "Created", bundle: #bundle)
      case "paused": String(localized: "Paused", bundle: #bundle)
      case "restarting": String(localized: "Restarting", bundle: #bundle)
      case "removing": String(localized: "Removing", bundle: #bundle)
      case "dead": String(localized: "Dead", bundle: #bundle)
      default: rawState
      }
    }
  }
}

extension ContainerOperation {
  func failureText(detail: String) -> LocalizedStringResource {
    switch self {
    case .action(.start): LocalizedStringResource("Couldn't start the container: \(detail)", bundle: #bundle)
    case .action(.stop): LocalizedStringResource("Couldn't stop the container: \(detail)", bundle: #bundle)
    case .action(.restart): LocalizedStringResource("Couldn't restart the container: \(detail)", bundle: #bundle)
    case .delete: LocalizedStringResource("Couldn't delete the container: \(detail)", bundle: #bundle)
    }
  }
}

extension [ContainerPort] {
  /// One entry per distinct mapping: the engine lists an IPv4 and an IPv6 publication of one port twice.
  var displayText: String {
    var seen = Set<String>()
    let entries = map(\.displayText).filter { seen.insert($0).inserted }
    return entries.isEmpty ? "—" : entries.joined(separator: ", ")
  }
}

extension ContainerPort {
  var displayText: String {
    guard let publicPort else { return "\(privatePort)/\(protocolName)" }
    let host = ip.flatMap { $0 == "0.0.0.0" || $0 == "::" ? nil : "\($0):" } ?? ""
    return "\(host)\(publicPort)→\(privatePort)/\(protocolName)"
  }
}
