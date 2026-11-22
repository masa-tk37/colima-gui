import AppKit
import ColimaCore
import Observation

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Created once here so the App scenes and the termination path share the same instance.
  let assembly = AppAssembly()
  let windows = AppWindows()

  private var isAwaitingOperationEnd = false
  private var isPromptingForTermination = false
  private var launchedAsLoginItem = false

  /// The launch Apple Event is checked at both points because which one still sees it as current is not documented.
  func applicationWillFinishLaunching(_ notification: Notification) {
    launchedAsLoginItem = Self.isLoginLaunch()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    windows.start()
    assembly.start()
    if !(launchedAsLoginItem || Self.isLoginLaunch()) { windows.showMainWindow() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// A Finder double-click on the running app lands here; with no Dock icon it is the only way back to the window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows || !windows.hasRegularWindow { windows.showMainWindow() }
    return false
  }

  private static func isLoginLaunch() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication
    else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
      == keyAELaunchedAsLogInItem
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if isAwaitingOperationEnd { return .terminateLater }
    if isPromptingForTermination { return .terminateCancel }
    guard assembly.vmController.activeOperation != nil else { return .terminateNow }

    isPromptingForTermination = true
    defer { isPromptingForTermination = false }

    switch promptForTermination() {
    case .waitForCompletion:
      guard assembly.vmController.activeOperation != nil else { return .terminateNow }
      isAwaitingOperationEnd = true
      Task {
        await waitForOperationEnd()
        isAwaitingOperationEnd = false
        // Reached on success and on failure alike: a failed operation also clears `activeOperation`.
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    case .terminateNow:
      return .terminateNow
    case .cancel:
      return .terminateCancel
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    assembly.shutdown()
  }

  private enum TerminationChoice {
    case waitForCompletion
    case terminateNow
    case cancel
  }

  private func promptForTermination() -> TerminationChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "A VM operation is in progress")
    alert.informativeText = String(
      localized: """
        If you quit now, the colima command already running finishes in the background, but its output and \
        result are not shown. A restart or recreation stops after the current step: the remaining steps do not run. \
        Quitting this app does not stop the VM.
        """)
    alert.addButton(withTitle: String(localized: "Quit when finished"))
    alert.addButton(withTitle: String(localized: "Quit now"))
    let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
    cancel.keyEquivalent = "\u{1b}"

    // An LSUIElement app with no regular window is usually inactive, and the alert would open behind other apps.
    NSApplication.shared.activate()
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .waitForCompletion
    case .alertSecondButtonReturn: return .terminateNow
    default: return .cancel
    }
  }

  private func waitForOperationEnd() async {
    let controller = assembly.vmController
    while controller.activeOperation != nil {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        withObservationTracking {
          _ = controller.activeOperation
        } onChange: {
          continuation.resume()
        }
      }
    }
  }
}
