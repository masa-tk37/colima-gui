import ColimaCore
import SwiftUI

public struct ContainerLogView: View {
  private let session: LogSession
  @State private var isPinnedToBottom: Bool
  @State private var position: ScrollPosition

  public init(session: LogSession, isPinnedToBottom: Bool = true) {
    self.session = session
    _isPinnedToBottom = State(initialValue: isPinnedToBottom)
    _position = State(initialValue: ScrollPosition(edge: isPinnedToBottom ? .bottom : .top))
  }

  private struct Tail: Equatable {
    let count: Int
    let lastID: Int?
    let provisional: [LogLine]
    let state: LogSessionState
    let mode: LogSessionMode
  }

  public var body: some View {
    let rows = LogRows(confirmed: session.lines, provisional: session.provisionalLines)
    let isSeparated = session.mode == .separated
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { line in
          LogLineRow(line: line, showsStreamColumn: isSeparated)
        }
      }
      .scrollTargetLayout()
      .textSelection(.enabled)
      .padding(.vertical, 6)
    }
    .accessibilityLabel(LocalizedStringResource("Container logs", bundle: #bundle))
    .overlay { EmptyLogOverlay(state: session.state, isEmpty: rows.isEmpty) }
    .modifier(
      LogTailFollowing(
        isPinnedToBottom: $isPinnedToBottom, position: $position,
        trigger: Tail(
          count: session.lines.count, lastID: session.lines.last?.id,
          provisional: session.provisionalLines,
          state: session.state, mode: session.mode)))
    // A system bar, so the scroll edge effect separates it from the lines instead of a drawn background.
    .safeAreaBar(edge: .bottom, spacing: 0) {
      LogStatusBar(state: session.state, mode: session.mode, isPinnedToBottom: isPinnedToBottom)
    }
    .scrollEdgeEffectStyle(.hard, for: .bottom)
    .task { await session.run() }
  }
}

private struct LogLineRow: View {
  let line: LogLine
  let showsStreamColumn: Bool

  private var isStandardError: Bool { line.stream == .stderr }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsStreamColumn {
        Text(verbatim: isStandardError ? "ERR" : "")
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .foregroundStyle(.red)
          .frame(width: 28, alignment: .leading)
          .accessibilityHidden(true)
      }
      Text(line.text.isEmpty ? " " : line.text)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(isStandardError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 1)
    .background(isStandardError ? Color.red.opacity(0.08) : .clear)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      isStandardError
        ? Text("Standard error: \(line.text)", bundle: #bundle)
        : Text(verbatim: line.text))
  }
}

private struct EmptyLogOverlay: View {
  let state: LogSessionState
  let isEmpty: Bool

  var body: some View {
    if isEmpty {
      switch state {
      case .loading:
        ProgressView(LocalizedStringResource("Loading logs", bundle: #bundle))
      case .following:
        ContentUnavailableView(LocalizedStringResource("No logs yet", bundle: #bundle), systemImage: "text.alignleft",
          description: Text("Output from the container appears here.", bundle: #bundle))
      case .history, .ended:
        ContentUnavailableView(LocalizedStringResource("No logs", bundle: #bundle), systemImage: "text.alignleft")
      }
    }
  }
}

private struct LogStatusBar: View {
  let state: LogSessionState
  let mode: LogSessionMode
  let isPinnedToBottom: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      statusLabel
      if mode == .singleStream {
        Label(LocalizedStringResource("Standard output and standard error can't be told apart (TTY)", bundle: #bundle), systemImage: "info.circle")
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch state {
    case .loading:
      Label(LocalizedStringResource("Loading logs", bundle: #bundle), systemImage: "hourglass")
        .foregroundStyle(.secondary)
    case .following:
      if isPinnedToBottom {
        Label(LocalizedStringResource("Following", bundle: #bundle), systemImage: "dot.radiowaves.left.and.right")
          .foregroundStyle(.secondary)
      } else {
        Label(LocalizedStringResource("Auto-scroll paused", bundle: #bundle), systemImage: "pause.circle")
          .foregroundStyle(.secondary)
      }
    case .history:
      Label(LocalizedStringResource("Past logs of a stopped container (not following)", bundle: #bundle), systemImage: "clock.arrow.circlepath")
        .foregroundStyle(.secondary)
    case .ended(.streamClosed):
      Label(LocalizedStringResource("Log streaming ended normally", bundle: #bundle), systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
    case .ended(.containerGone):
      Label(LocalizedStringResource("The container was removed, so log streaming ended", bundle: #bundle), systemImage: "trash")
        .foregroundStyle(.orange)
    case .ended(.failed(let message)):
      Label(LocalizedStringResource("Couldn't load logs: \(message)", bundle: #bundle), systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    }
  }
}
