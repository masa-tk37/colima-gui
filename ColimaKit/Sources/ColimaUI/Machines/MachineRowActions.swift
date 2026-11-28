import ColimaCore
import SwiftUI

struct MachineRowHandlers {
  let start: @MainActor (MachineName) -> Void
  let stop: @MainActor (MachineName) -> Void
  let openShell: @MainActor (MachineName) -> Void
  let edit: @MainActor (MachineName) -> Void
  let delete: @MainActor (MachineName) -> Void
  let cancelCreate: @MainActor (MachineName) -> Void
}

struct MachineRowActions: View {
  let name: MachineName
  let state: MachineRowActionState
  let handlers: MachineRowHandlers

  var body: some View {
    HStack(spacing: 6) {
      toggle
      CircleActionButton(
        title: LocalizedStringResource("Open shell", bundle: #bundle), systemImage: "terminal",
        isEnabled: state.shellEnabled
      ) { handlers.openShell(name) }
      CircleActionButton(
        title: LocalizedStringResource("Edit", bundle: #bundle), systemImage: "slider.horizontal.3",
        isEnabled: state.editEnabled
      ) { handlers.edit(name) }
      if state.cancelCreate == .hidden {
        CircleActionButton(
          title: LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive,
          isEnabled: state.deleteEnabled
        ) { handlers.delete(name) }
      } else {
        CircleActionButton(
          title: LocalizedStringResource("Cancel creation", bundle: #bundle), systemImage: "xmark",
          role: .destructive, isEnabled: state.cancelCreate == .enabled
        ) { handlers.cancelCreate(name) }
      }
    }
    .fixedSize()
  }

  @ViewBuilder
  private var toggle: some View {
    switch state.toggle {
    case .start(let enabled):
      CircleActionButton(
        title: LocalizedStringResource("Start", bundle: #bundle), systemImage: "play.fill", isEnabled: enabled
      ) { handlers.start(name) }
    case .stop(let enabled):
      CircleActionButton(
        title: LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill", isEnabled: enabled
      ) { handlers.stop(name) }
    }
  }
}

struct MachineRowMenu: View {
  let name: MachineName
  let state: MachineRowActionState
  let handlers: MachineRowHandlers

  var body: some View {
    switch state.toggle {
    case .start(let enabled):
      Button(LocalizedStringResource("Start", bundle: #bundle), systemImage: "play.fill") { handlers.start(name) }
        .disabled(!enabled)
    case .stop(let enabled):
      Button(LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill") { handlers.stop(name) }
        .disabled(!enabled)
    }
    Button(LocalizedStringResource("Open shell", bundle: #bundle), systemImage: "terminal") { handlers.openShell(name) }
      .disabled(!state.shellEnabled)
    Button(LocalizedStringResource("Edit", bundle: #bundle), systemImage: "slider.horizontal.3") { handlers.edit(name) }
      .disabled(!state.editEnabled)
    Divider()
    if state.cancelCreate != .hidden {
      Button(LocalizedStringResource("Cancel creation", bundle: #bundle), systemImage: "xmark") { handlers.cancelCreate(name) }
        .disabled(state.cancelCreate != .enabled)
    }
    Button(LocalizedStringResource("Delete", bundle: #bundle), systemImage: "trash", role: .destructive) { handlers.delete(name) }
      .disabled(!state.deleteEnabled)
  }
}
