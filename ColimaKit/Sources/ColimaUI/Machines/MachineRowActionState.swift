import ColimaCore

struct MachineRowCapabilities: Equatable {
  let canStart: Bool
  let canStop: Bool
  let canDelete: Bool
  let canEdit: Bool
  let canOpenShell: Bool
  let canCancelCreate: Bool

  @MainActor
  init(name: MachineName, controller: MachineController) {
    canStart = controller.canStart(name)
    canStop = controller.canStop(name)
    canDelete = controller.canDelete(name)
    canEdit = controller.canEdit(name)
    canOpenShell = controller.canOpenShell(name)
    canCancelCreate = controller.canCancelCreate(name)
  }

  init(
    canStart: Bool, canStop: Bool, canDelete: Bool, canEdit: Bool, canOpenShell: Bool, canCancelCreate: Bool
  ) {
    self.canStart = canStart
    self.canStop = canStop
    self.canDelete = canDelete
    self.canEdit = canEdit
    self.canOpenShell = canOpenShell
    self.canCancelCreate = canCancelCreate
  }
}

struct MachineRowActionState: Equatable {
  enum Toggle: Equatable {
    case start(enabled: Bool)
    case stop(enabled: Bool)
  }

  enum CancelCreate: Equatable {
    case hidden, enabled, disabled
  }

  let toggle: Toggle
  let shellEnabled: Bool
  let editEnabled: Bool
  let deleteEnabled: Bool
  let cancelCreate: CancelCreate

  @MainActor
  init(row: MachineRow, controller: MachineController) {
    self.init(display: row.display, capabilities: MachineRowCapabilities(name: row.name, controller: controller))
  }

  init(display: MachineDisplayState, capabilities: MachineRowCapabilities) {
    switch display {
    case .running, .stopping:
      toggle = .stop(enabled: capabilities.canStop)
    default:
      toggle = .start(enabled: capabilities.canStart)
    }
    shellEnabled = capabilities.canOpenShell
    editEnabled = capabilities.canEdit
    deleteEnabled = capabilities.canDelete
    if display == .creating {
      cancelCreate = capabilities.canCancelCreate ? .enabled : .disabled
    } else {
      cancelCreate = .hidden
    }
  }
}
