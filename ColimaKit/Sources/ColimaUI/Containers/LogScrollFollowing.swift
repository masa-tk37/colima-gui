import ColimaCore
import SwiftUI

struct LogScrollMetrics: Equatable {
  var offset: CGFloat
  var contentHeight: CGFloat
  var viewportHeight: CGFloat
  var bottomInset: CGFloat

  init(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat) {
    self.offset = offset
    self.contentHeight = contentHeight
    self.viewportHeight = viewportHeight
    self.bottomInset = bottomInset
  }

  init(_ geometry: ScrollGeometry) {
    self.init(
      offset: geometry.contentOffset.y,
      contentHeight: geometry.contentSize.height,
      viewportHeight: geometry.containerSize.height,
      bottomInset: geometry.contentInsets.bottom)
  }

  var distanceFromBottom: CGFloat {
    max(0, contentHeight + bottomInset - viewportHeight - offset)
  }
}

enum LogFollowRule {
  /// Less than one line of text, so a half-line of slack at the end still counts as the end.
  static let tolerance: CGFloat = 8

  /// Growth of the content is not a scroll away from the end, and the bounce back from an overscroll moves the
  /// offset up while the view is still at the end, so only a move up that leaves the end behind stops following.
  static func isPinned(was wasPinned: Bool, from old: LogScrollMetrics, to new: LogScrollMetrics)
    -> Bool
  {
    if new.distanceFromBottom <= tolerance { return true }
    if new.offset < old.offset { return false }
    return wasPinned
  }
}

struct LogTailFollowing<Trigger: Equatable>: ViewModifier {
  @Binding var isPinnedToBottom: Bool
  @Binding var position: ScrollPosition
  /// Changes whenever the end of the log may have moved.
  let trigger: Trigger
  @State private var isUserScrolling = false

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .overlay(alignment: .bottomTrailing) {
        LogJumpToEndButton(isVisible: !isPinnedToBottom) {
          isPinnedToBottom = true
          position.scrollTo(edge: .bottom)
        }
        .animation(.default, value: isPinnedToBottom)
      }
      .onScrollPhaseChange { _, phase in
        isUserScrolling = phase == .interacting || phase == .decelerating
      }
      .onScrollGeometryChange(for: LogScrollMetrics.self) { LogScrollMetrics($0) } action: { old, new in
        guard isUserScrolling else { return }
        isPinnedToBottom = LogFollowRule.isPinned(was: isPinnedToBottom, from: old, to: new)
      }
      .onChange(of: trigger, initial: true) {
        if isPinnedToBottom { position.scrollTo(edge: .bottom) }
      }
  }
}

/// One collection so a line keeps its row when a provisional line is confirmed under the same id.
struct LogRows: RandomAccessCollection {
  let confirmed: [LogLine]
  let provisional: [LogLine]

  var startIndex: Int { 0 }
  var endIndex: Int { confirmed.count + provisional.count }

  subscript(position: Int) -> LogLine {
    position < confirmed.count ? confirmed[position] : provisional[position - confirmed.count]
  }
}
