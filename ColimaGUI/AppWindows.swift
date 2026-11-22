import AppKit
import SwiftUI

final class AppWindows {
  private var observers: [any NSObjectProtocol] = []
  /// Set once a SwiftUI view hands over `openWindow`; the delegate has no other way to open a scene.
  private var openWindow: OpenWindowAction?
  private var opensMainWindowWhenReady = false

  func start() {
    let center = NotificationCenter.default
    let shown = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    observers = shown.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateDockPresence(closing: nil) }
      }
    }
    observers.append(
      center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
        [weak self] notification in
        let closing = notification.object as? NSWindow
        MainActor.assumeIsolated { self?.updateDockPresence(closing: closing) }
      })
  }

  func connect(_ openWindow: OpenWindowAction) {
    self.openWindow = openWindow
    if opensMainWindowWhenReady {
      opensMainWindowWhenReady = false
      showMainWindow()
    }
  }

  func showMainWindow() {
    guard let openWindow else {
      opensMainWindowWhenReady = true
      return
    }
    NSApplication.shared.setActivationPolicy(.regular)
    // `openWindow` also fronts an open main window; only a miniaturized one needs `deminiaturize`.
    let main = NSApplication.shared.windows.first { $0.identifier?.rawValue == MainWindow.id }
    if let main, main.isMiniaturized {
      main.deminiaturize(nil)
    } else {
      openWindow(id: MainWindow.id)
    }
    NSApplication.shared.activate()
  }

  var hasRegularWindow: Bool {
    NSApplication.shared.windows.contains { Self.isShown($0) }
  }

  private func updateDockPresence(closing: NSWindow?) {
    let keepsIcon = NSApplication.shared.windows.contains { $0 !== closing && Self.isShown($0) }
    let policy: NSApplication.ActivationPolicy = keepsIcon ? .regular : .accessory
    if NSApplication.shared.activationPolicy() != policy {
      NSApplication.shared.setActivationPolicy(policy)
    }
  }

  /// The MenuBarExtra content is a panel; the main, log and Settings windows are the ones that warrant a Dock icon.
  private static func isShown(_ window: NSWindow) -> Bool {
    window.canBecomeMain && !(window is NSPanel) && (window.isVisible || window.isMiniaturized)
  }
}
