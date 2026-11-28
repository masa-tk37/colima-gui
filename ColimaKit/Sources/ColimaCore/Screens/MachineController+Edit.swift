import Foundation

public enum MachineEditOutcome: Sendable, Equatable {
  case started, invalid(MachineValidationFailure), mustStopFirst, busy
}

extension MachineController {
  public func canEdit(_ name: MachineName) -> Bool {
    if case .stopped? = idleMachine(name)?.runState { true } else { false }
  }

  public func canOpenShell(_ name: MachineName) -> Bool {
    if case .running? = idleMachine(name)?.runState { true } else { false }
  }

  public func saveEdit(_ name: MachineName, _ input: MachineEditInput) -> MachineEditOutcome {
    guard operations[name.key] == nil else { return .busy }
    guard canEdit(name), let current = idleMachine(name) else { return .mustStopFirst }
    switch MachineSpecValidator.validateEdit(
      input, currentDiskBytes: current.diskBytes, currentMounts: current.mounts, host: host,
      directoryExists: directoryExists)
    {
    case .failure(let failure):
      return .invalid(failure)
    case .success(let spec):
      begin(.edit(name, spec))
      return .started
    }
  }

  public func dismissNotice() {
    notice = nil
  }
}
