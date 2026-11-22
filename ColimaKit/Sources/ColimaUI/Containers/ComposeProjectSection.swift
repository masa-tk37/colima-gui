import ColimaCore
import SwiftUI

struct ComposeProjectSection: View {
  let project: ComposeProject
  let outcome: BatchOutcome<ContainerID>?
  let operationFailures: [ContainerID: ContainerOperationFailure]
  let slots: ContainerOperationSlots
  let notices: [ContainerID: DeleteNotice]
  let actions: ContainerListActions
  @Binding var isExpanded: Bool

  /// The rows are left out rather than using `Section(isExpanded:)`, whose disclosure control depends on the list style.
  var body: some View {
    Section {
      if isExpanded {
        ForEach(project.containers) { container in
          ContainerRow(
            container: container,
            isOperating: slots.isBusy(container.id),
            failure: operationFailures[container.id],
            notice: notices[container.id],
            actions: actions)
        }
        if let outcome, !outcome.failed.isEmpty {
          ProjectOutcomeView(outcome: outcome, name: memberName)
            .selectionDisabled()
        }
      }
    } header: {
      header
    }
  }

  private var isOperating: Bool {
    project.containerIDs.contains { slots.isBusy($0) }
  }

  private var canStart: Bool { !isOperating && project.runningCount < project.containers.count }
  private var canStop: Bool { !isOperating && project.runningCount > 0 }

  private func memberName(_ id: ContainerID) -> String {
    project.containers.first { $0.id == id }?.name ?? String(id.rawValue.prefix(12))
  }

  private var header: some View {
    HStack(spacing: 10) {
      disclosureButton
      Label {
        Text(verbatim: project.name)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
      } icon: {
        Image(systemName: "square.stack.3d.down.right")
          .foregroundStyle(.secondary)
      }
      Text("\(project.containers.count) containers, \(project.runningCount) running", bundle: #bundle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      ComposeProjectStateBadge(state: project.state)
      Spacer(minLength: 8)
      if isOperating {
        Label(LocalizedStringResource("In progress", bundle: #bundle), systemImage: "hourglass")
          .font(.caption)
          .foregroundStyle(.secondary)
        ProgressView().controlSize(.small)
      }
      HStack(spacing: 4) {
        CircleActionButton(
          title: LocalizedStringResource("Start all", bundle: #bundle), systemImage: "play.fill", isEnabled: canStart
        ) { actions.performProject(.start, project.name) }
        CircleActionButton(
          title: LocalizedStringResource("Stop all", bundle: #bundle), systemImage: "stop.fill", isEnabled: canStop
        ) { actions.performProject(.stop, project.name) }
        CircleActionButton(
          title: LocalizedStringResource("Restart all", bundle: #bundle), systemImage: "arrow.clockwise",
          isEnabled: canStop
        ) { actions.performProject(.restart, project.name) }
      }
      // Smaller than the rows' buttons so the header keeps a single line.
      .controlSize(.small)
      .fixedSize()
    }
    .textCase(nil)
    .accessibilityElement(children: .contain)
  }

  private var disclosureButton: some View {
    Button {
      withAnimation { isExpanded.toggle() }
    } label: {
      Image(systemName: "chevron.right")
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 12)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(
      isExpanded
        ? LocalizedStringResource("Collapse \(project.name)", bundle: #bundle)
        : LocalizedStringResource("Expand \(project.name)", bundle: #bundle))
    .help(
      isExpanded
        ? LocalizedStringResource("Hide this project's containers", bundle: #bundle)
        : LocalizedStringResource("Show this project's containers", bundle: #bundle))
  }
}

struct ComposeProjectStateBadge: View {
  let state: ComposeProjectState

  var body: some View {
    TagBadge(title: title, tint: tint)
      .accessibilityLabel(LocalizedStringResource("Project status: \(String(localized: title))", bundle: #bundle))
  }

  private var title: LocalizedStringResource {
    switch state {
    case .allRunning: LocalizedStringResource("All running", bundle: #bundle)
    case .partiallyRunning: LocalizedStringResource("Partially running", bundle: #bundle)
    case .allStopped: LocalizedStringResource("All stopped", bundle: #bundle)
    }
  }

  private var tint: Color {
    switch state {
    case .allRunning: .green
    case .partiallyRunning: .orange
    case .allStopped: .secondary
    }
  }
}

private struct ProjectOutcomeView: View {
  let outcome: BatchOutcome<ContainerID>
  let name: (ContainerID) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(LocalizedStringResource("The operation failed for some containers (\(outcome.succeeded.count) succeeded, \(outcome.failed.count) failed)", bundle: #bundle),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)
      ForEach(failures, id: \.id) { failure in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verbatim: failure.name).fontWeight(.medium)
          Text(verbatim: failure.message).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .font(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var failures: [(id: ContainerID, name: String, message: String)] {
    outcome.failed
      .map { (id: $0.key, name: name($0.key), message: $0.value) }
      .sorted { $0.name < $1.name }
  }
}
