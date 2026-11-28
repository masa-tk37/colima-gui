import ColimaCore
import SwiftUI

public struct OperationOutputView: View {
  private let operation: VMOperationProgress
  private let record: VMOperationRecord?
  private let showsLogButton: Bool
  private let abort: @MainActor () -> Void

  /// - Parameter showsLogButton: false where the screen already offers the log, e.g. in its toolbar.
  public init(
    operation: VMOperationProgress, record: VMOperationRecord?, showsLogButton: Bool = true,
    abort: @escaping @MainActor () -> Void
  ) {
    self.operation = operation
    self.record = record
    self.showsLogButton = showsLogButton
    self.abort = abort
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TimelineView(.periodic(from: operation.startedAt, by: 1)) { context in
        OperationStatus(operation: operation, now: context.date, abort: abort)
      }
      LatestLine(text: record?.lines.last?.text)
      if showsLogButton {
        ShowOperationLogButton()
      }
    }
  }
}

private struct OperationStatus: View {
  let operation: VMOperationProgress
  let now: Date
  let abort: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
        Text("\(operation.kind.label): \(operation.stage.label)", bundle: #bundle)
          .font(.headline)
      }
      LabeledContent(LocalizedStringResource("Elapsed time", bundle: #bundle)) {
        Text(OperationClock.text(seconds: Self.seconds(from: operation.startedAt, to: now)))
          .monospacedDigit()
      }
      LabeledContent(LocalizedStringResource("Since last output", bundle: #bundle)) {
        if let lastOutputAt = operation.lastOutputAt {
          Text("\(Self.seconds(from: lastOutputAt, to: now)) seconds ago", bundle: #bundle)
            .monospacedDigit()
        } else {
          Text("No output", bundle: #bundle)
        }
      }
      if operation.isAbortAvailable(at: now) {
        OperationAbortControl(abort: abort)
      }
    }
  }

  private static func seconds(from start: Date, to end: Date) -> Int {
    max(0, Int(end.timeIntervalSince(start)))
  }
}

private struct LatestLine: View {
  let text: String?

  var body: some View {
    Group {
      if let text {
        Text(verbatim: text).font(.callout.monospaced())
      } else {
        Text("No output yet", bundle: #bundle).foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(text ?? "")
  }
}
