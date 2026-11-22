import SwiftUI

private struct SidebarSelectionKey: FocusedValueKey {
  typealias Value = Binding<SidebarItem>
}

extension FocusedValues {
  fileprivate var sidebarSelection: Binding<SidebarItem>? {
    get { self[SidebarSelectionKey.self] }
    set { self[SidebarSelectionKey.self] = newValue }
  }
}

extension View {
  func sidebarSelectionForCommands(_ selection: Binding<SidebarItem>) -> some View {
    focusedSceneValue(\.sidebarSelection, selection)
  }
}

public struct SidebarNavigationCommands: Commands {
  @FocusedBinding(\.sidebarSelection) private var selection

  public init() {}

  public var body: some Commands {
    CommandGroup(after: .sidebar) {
      Divider()
      ForEach(SidebarItem.allCases, id: \.self) { item in
        Button {
          selection = item
        } label: {
          Label(item.title, systemImage: item.systemImage)
        }
        .keyboardShortcut(item.shortcutKey, modifiers: .command)
        .disabled(selection == nil)
      }
    }
  }
}
