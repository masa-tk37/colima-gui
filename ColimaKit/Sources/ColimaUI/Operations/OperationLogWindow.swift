import AppKit
import SwiftUI

public enum OperationLogWindow {
  public static let id = "operation-log"
  public static let opensOnStartKey = "opensOperationLogOnStart"

  /// Activates the app as well, because the menu bar and a closed main window leave it in the background.
  @MainActor public static func open(with openWindow: OpenWindowAction) {
    openWindow(id: id)
    NSApplication.shared.activate()
  }
}

struct ShowOperationLogButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(LocalizedStringResource("Show log", bundle: #bundle), systemImage: "text.alignleft") {
      OperationLogWindow.open(with: openWindow)
    }
    .help(LocalizedStringResource("Open the window with colima's output", bundle: #bundle))
  }
}
