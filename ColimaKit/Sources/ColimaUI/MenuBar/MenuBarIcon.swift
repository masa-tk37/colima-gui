import ColimaCore
import SwiftUI

/// The badge is drawn into each image because a menu bar label renders a single image and drops overlays; badges differ in shape, not only colour, so the states stay apart in the monochrome template rendering.
public struct MenuBarIcon: View {
  private let state: VMDisplayState

  public init(state: VMDisplayState) {
    self.state = state
  }

  public var body: some View {
    Image(state.menuBarImageName, bundle: #bundle)
      .accessibilityLabel(state.menuBarAccessibilityLabel)
  }
}

extension VMDisplayState {
  var menuBarImageName: String {
    switch self {
    case .running: "MenuBarRunning"
    case .stopped: "MenuBarStopped"
    case .starting: "MenuBarStarting"
    case .stopping: "MenuBarStopping"
    }
  }

  var menuBarAccessibilityLabel: LocalizedStringResource {
    switch self {
    case .running: LocalizedStringResource("Colima: Running", bundle: #bundle)
    case .stopped: LocalizedStringResource("Colima: Stopped", bundle: #bundle)
    case .starting: LocalizedStringResource("Colima: Starting", bundle: #bundle)
    case .stopping: LocalizedStringResource("Colima: Stopping", bundle: #bundle)
    }
  }
}
