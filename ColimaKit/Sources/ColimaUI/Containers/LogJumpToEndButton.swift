import SwiftUI

struct LogJumpToEndButton: View {
  let isVisible: Bool
  let jump: () -> Void

  var body: some View {
    if isVisible {
      Button(LocalizedStringResource("Jump to end", bundle: #bundle), systemImage: "arrow.down.to.line", action: jump)
        .buttonStyle(.glass)
        .help(LocalizedStringResource("Scroll to the end of the log and resume auto-scrolling", bundle: #bundle))
        .padding(12)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
  }
}
