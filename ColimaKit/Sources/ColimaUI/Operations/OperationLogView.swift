import ColimaCore
import SwiftUI

public struct OperationLogView: View {
  private let controller: VMController

  public init(controller: VMController) {
    self.controller = controller
  }

  public var body: some View {
    Group {
      if let record = controller.latestRecord {
        OperationRecordView(record: record)
          .id(record.id)
      } else {
        ContentUnavailableView(
          LocalizedStringResource("No VM operations yet", bundle: #bundle), systemImage: "text.alignleft",
          description: Text("colima's output appears here when you start, stop or create the VM.", bundle: #bundle))
      }
    }
    .navigationTitle(LocalizedStringResource("Operation log", bundle: #bundle))
    .frame(minWidth: 480, minHeight: 280)
  }
}

private struct OperationRecordView: View {
  let record: VMOperationRecord
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
    .safeAreaBar(edge: .top) { RecordHeader(record: record) }
    .scrollEdgeEffectStyle(.hard, for: .top)
  }
}

private struct RecordHeader: View {
  let record: VMOperationRecord

  var body: some View {
    HStack(spacing: 8) {
      status
      Text(verbatim: record.kind.label).font(.headline)
      Spacer()
      Text(record.startedAt, format: .dateTime.hour().minute().second())
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var status: some View {
    switch record.outcome {
    case nil:
      ProgressView().controlSize(.small)
        .accessibilityLabel(LocalizedStringResource("In progress", bundle: #bundle))
    case .succeeded:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        .accessibilityLabel(LocalizedStringResource("Completed", bundle: #bundle))
    case .failed(let failure):
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        .accessibilityLabel(failure.kind.failureTitle)
    }
  }
}
