import ColimaAdapters
import ColimaCore
import ColimaUI
import ServiceManagement
import SwiftUI

enum MainWindow {
  static let id = "main"
}

@main
struct ColimaGUIApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    let assembly = appDelegate.assembly

    Window("Colima", id: MainWindow.id) {
      RootView(
        controller: assembly.vmController,
        settingsModel: assembly.settingsModel,
        usageMonitor: assembly.usageMonitor,
        containerStore: assembly.containerStore,
        imageStore: assembly.imageStore,
        volumeStore: assembly.volumeStore,
        networkStore: assembly.networkStore,
        slots: assembly.slots,
        sessions: assembly.sessions
      )
      .frame(minWidth: 960, minHeight: 520)
    }
    .defaultSize(width: 1180, height: 720)
    .windowResizability(.contentMinSize)
    .commands { SidebarNavigationCommands() }
    // AppDelegate opens it unless the launch came from the login item.
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Window("Operation log", id: OperationLogWindow.id) {
      OperationLogView(controller: assembly.vmController)
    }
    .defaultSize(width: 760, height: 480)
    .keyboardShortcut("l", modifiers: [.command, .shift])
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Settings {
      AppSettingsView()
    }

    MenuBarExtra {
      MenuBarMenu(controller: assembly.vmController, windows: appDelegate.windows)
    } label: {
      MenuBarLabel(controller: assembly.vmController, windows: appDelegate.windows)
    }
    .menuBarExtraStyle(.window)
  }
}

/// A view of its own because only a view body tracks the controller's state; the scene body does not. It also opens
/// windows for the delegate, because the label is the one view that exists for the app's whole lifetime.
private struct MenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  @AppStorage(OperationLogWindow.opensOnStartKey) private var opensLogOnStart = false
  let controller: VMController
  let windows: AppWindows

  var body: some View {
    MenuBarIcon(state: controller.displayState)
      .onAppear { windows.connect(openWindow) }
      .onChange(of: controller.latestRecord?.id) { _, newID in
        guard opensLogOnStart, newID != nil else { return }
        OperationLogWindow.open(with: openWindow)
      }
  }
}

private struct MenuBarMenu: View {
  @State private var helperNeedsApproval = false
  let controller: VMController
  let windows: AppWindows

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if helperNeedsApproval {
        BackgroundHelperNotice()
        Divider()
      }
      MenuBarContentView(controller: controller) { windows.showMainWindow() }
    }
    .onAppear { helperNeedsApproval = AgentRegistration.current == .requiresApproval }
  }
}

private struct BackgroundHelperNotice: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("The background helper is turned off", systemImage: "exclamationmark.triangle.fill")
        .font(.callout.weight(.semibold))
      Text("VM operations need it. Turn on ColimaGUI in Login Items & Extensions.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
  }
}
