import ColimaCore
import SwiftUI

public struct MachineOperationPanel: View {
  private let controller: MachineController
  private let name: MachineName

  public init(controller: MachineController, name: MachineName) {
    self.controller = controller
    self.name = name
  }

  public var body: some View {
    let key = name.key
    let presentation = MachineOperationPresentation(
      progress: controller.operations[key], record: controller.records[key], failure: controller.failures[key],
      canCancel: controller.canCancelCreate(name))
    Group {
      if presentation.isEmpty {
        ContentUnavailableView(
          LocalizedStringResource("No operations on this machine yet", bundle: #bundle),
          systemImage: "text.alignleft",
          description: Text("limactl's output appears here when you create, start, stop or delete the machine.", bundle: #bundle))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          PanelHeader(presentation: presentation) { controller.cancelCreate(name) }
          Divider()
          PanelContent(
            presentation: presentation, record: controller.records[key],
            dismissFailure: { controller.dismissFailure(for: name) })
        }
      }
    }
    .frame(minWidth: 480, minHeight: 240)
  }
}

private struct PanelHeader: View {
  let presentation: MachineOperationPresentation
  let cancel: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 8) {
      status
      if let kind = presentation.kind {
        Text(verbatim: kind.label).font(.headline)
      }
      Spacer()
      CancelCreateButton(control: presentation.cancel, action: cancel)
      if presentation.startedAt != nil { elapsed }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var elapsed: some View {
    if presentation.status == .running, let startedAt = presentation.startedAt {
      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        ElapsedText(seconds: presentation.elapsedSeconds(at: context.date))
      }
    } else {
      ElapsedText(seconds: presentation.elapsedSeconds(at: .now))
    }
  }

  @ViewBuilder
  private var status: some View {
    switch presentation.status {
    case .idle:
      EmptyView()
    case .running, .earlierSession:
      ProgressView().controlSize(.small)
        .accessibilityLabel(LocalizedStringResource("In progress", bundle: #bundle))
    case .succeeded:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        .accessibilityLabel(LocalizedStringResource("Completed", bundle: #bundle))
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        .accessibilityLabel(presentation.kind?.failureTitle ?? LocalizedStringResource("Failed", bundle: #bundle))
    case .cancelled:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        .accessibilityLabel(LocalizedStringResource("Cancelled", bundle: #bundle))
    }
  }
}

private struct ElapsedText: View {
  let seconds: Int?

  var body: some View {
    if let seconds {
      LabeledContent(LocalizedStringResource("Elapsed time", bundle: #bundle)) {
        Text(OperationClock.text(seconds: seconds)).monospacedDigit()
      }
      .fixedSize()
      .foregroundStyle(.secondary)
    }
  }
}

private struct CancelCreateButton: View {
  let control: MachineOperationPresentation.CancelControl
  let action: @MainActor () -> Void

  var body: some View {
    switch control {
    case .hidden:
      EmptyView()
    case .enabled, .disabled:
      Button(LocalizedStringResource("Cancel creation", bundle: #bundle), role: .destructive) { action() }
        .disabled(control == .disabled)
    case .requested:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small).accessibilityHidden(true)
        Button(LocalizedStringResource("Cancelling", bundle: #bundle), role: .destructive) {}
          .disabled(true)
      }
    }
  }
}

private struct PanelContent: View {
  let presentation: MachineOperationPresentation
  let record: MachineOperationRecord?
  let dismissFailure: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if presentation.showsEarlierSessionNotice {
        ContentUnavailableView(
          LocalizedStringResource("An operation started in an earlier session is running", bundle: #bundle),
          systemImage: "clock.arrow.circlepath",
          description: Text("Its output can't be shown.", bundle: #bundle))
      }
      if let failure = presentation.failure {
        MachineFailureBox(failure: failure, dismiss: dismissFailure).padding(12)
      }
      if presentation.showsOutput, let record {
        MachineOutputList(record: record).id(record.id)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

private struct MachineFailureBox: View {
  let failure: MachineOperationFailure
  let dismiss: @MainActor () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Label {
            Text(failure.kind.failureTitle).font(.headline)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Spacer()
          Button(LocalizedStringResource("Dismiss failure", bundle: #bundle), systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(LocalizedStringResource("Dismiss failure", bundle: #bundle))
        }
        LabeledContent(LocalizedStringResource("Cause", bundle: #bundle)) {
          Text(verbatim: failure.cause.message)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !failure.outputTail.isEmpty {
          GroupBox(LocalizedStringResource("End of output", bundle: #bundle)) {
            ScrollView {
              Text(verbatim: failure.outputTail.joined(separator: "\n"))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct MachineOutputList: View {
  let record: MachineOperationRecord
  @State private var isPinnedToBottom = true
  @State private var position = ScrollPosition(edge: .bottom)

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(record.lines) { line in
          Text(verbatim: line.text)
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .scrollTargetLayout()
      .textSelection(.enabled)
      .padding(12)
    }
    .overlay {
      if record.lines.isEmpty {
        Text("No output yet", bundle: #bundle).foregroundStyle(.secondary)
      }
    }
    .modifier(
      LogTailFollowing(isPinnedToBottom: $isPinnedToBottom, position: $position, trigger: record.lines.last?.id))
  }
}

#if DEBUG
  private struct MachineOperationPanelPreview: View {
    let scenario: MachineControllerPreviews.Scenario
    let name: MachineName

    var body: some View {
      PreviewHost({ await MachineControllerPreviews.make(scenario) }) { scene in
        MachineOperationPanel(controller: scene.controller, name: name)
      }
      .frame(width: 640, height: 360)
    }
  }

  #Preview("Create in progress") {
    MachineOperationPanelPreview(scenario: .creating, name: PreviewMachineData.creating)
  }

  #Preview("Start in progress") {
    MachineOperationPanelPreview(scenario: .starting, name: PreviewMachineData.stopped)
  }

  #Preview("Start failed") {
    MachineOperationPanelPreview(scenario: .startFailed, name: PreviewMachineData.stopped)
  }

  #Preview("Operation from an earlier session") {
    MachineOperationPanelPreview(scenario: .earlierSession, name: PreviewMachineData.stopped)
  }

  #Preview("Cancel requested") {
    MachineOperationPanelPreview(scenario: .createCancelRequested, name: PreviewMachineData.creating)
  }

  #Preview("No operation yet") {
    MachineOperationPanelPreview(scenario: .mixed, name: PreviewMachineData.running)
  }
#endif
