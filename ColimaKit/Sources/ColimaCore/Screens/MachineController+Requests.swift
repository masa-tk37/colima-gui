import Foundation

extension MachineController {
  // MARK: Start

  @discardableResult
  public func requestStart(_ name: MachineName) -> MachineRequestOutcome {
    guard operations[name.key] == nil else { return .busy }
    guard canStart(name), let target = idleMachine(name) else { return .notApplicable }
    guard let warning = memoryWarning(starting: target) else { return performStart(name) }
    pendingConfirmation = ConfirmationRequest(
      intent: .startMachine(name, warning: warning),
      origin: .window,
      title: String(localized: "Start the machine “\(name.rawValue)”?", bundle: #bundle),
      message: String(
        localized:
          "Starting this machine brings the memory allocated to running VMs to \(Self.gibibytes(warning.totalBytes)). That is above \(Self.gibibytes(warning.thresholdBytes)), 75% of this Mac’s \(Self.gibibytes(warning.physicalBytes)). Other apps and containers may slow down.",
        bundle: #bundle),
      itemGroups: [],
      confirmLabel: String(localized: "Start", bundle: #bundle),
      confirmRole: .standard)
    return .confirmationRequested
  }

  private func memoryWarning(starting target: MachineInstance) -> MemoryWarning? {
    let targetKey = target.name.key
    let others = (listing?.machines ?? []).filter { machine in
      let key = machine.name.key
      guard key != targetKey else { return false }
      switch operations[key]?.kind {
      case .create?: return false
      case .start?: return true
      default: if case .running = machine.runState { return true } else { return false }
      }
    }
    let defaultVMBytes = vmController.flatMap {
      MemoryPressureCheck.defaultVMBytes(
        operationKind: $0.activeOperation?.kind, observation: $0.observation, createSpec: $0.activeCreateSpec)
    }
    return MemoryPressureCheck.evaluate(
      defaultVMBytes: defaultVMBytes, otherMachineBytes: others.map(\.memoryBytes),
      targetBytes: target.memoryBytes, physicalBytes: host.memoryBytes)
  }

  // MARK: Delete

  @discardableResult
  public func requestDelete(_ name: MachineName) -> MachineRequestOutcome {
    guard operations[name.key] == nil else { return .busy }
    guard canDelete(name), let machine = idleMachine(name) else { return .notApplicable }
    let wasRunning = Self.isRunning(machine)
    let title = String(localized: "Delete the machine “\(name.rawValue)”?", bundle: #bundle)
    let message =
      wasRunning
      ? String(
        localized:
          "This machine is running. It is force-stopped before it is deleted, and everything inside it is lost. This cannot be undone.",
        bundle: #bundle)
      : String(
        localized: "Everything inside the machine is lost when it is deleted. This cannot be undone.",
        bundle: #bundle)
    pendingConfirmation = ConfirmationRequest(
      intent: .deleteMachine(name, wasRunning: wasRunning), title: title, message: message,
      item: name.rawValue, confirmLabel: String(localized: "Delete", bundle: #bundle))
    return .confirmationRequested
  }

  // MARK: Confirmation

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  /// The request is consumed whatever the outcome. Approving a start does not evaluate the memory total again:
  /// the user approved the figures shown.
  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id else { return .notPending }
    switch request.intent {
    case .startMachine(let name, _):
      pendingConfirmation = nil
      return approveStart(name)
    case .deleteMachine(let name, let wasRunning):
      pendingConfirmation = nil
      return approveDelete(name, wasRunning: wasRunning)
    default:
      return .notPending
    }
  }

  private func approveStart(_ name: MachineName) -> ConfirmationOutcome {
    switch performStart(name) {
    case .started:
      return .started
    case .busy:
      return .rejectedBusy(
        reason: String(
          localized: "Another operation is running on this machine, so the start was not performed.",
          bundle: #bundle))
    case .notApplicable, .confirmationRequested:
      return .rejectedBusy(
        reason: String(
          localized: "The machine’s state changed, so the start was not performed. Choose Start again.",
          bundle: #bundle))
    }
  }

  private func approveDelete(_ name: MachineName, wasRunning: Bool) -> ConfirmationOutcome {
    guard operations[name.key] == nil else {
      return .rejectedBusy(
        reason: String(
          localized: "Another operation is running on this machine, so the deletion was not performed.",
          bundle: #bundle))
    }
    guard let machine = idleMachine(name), Self.isRunning(machine) == wasRunning else {
      return .rejectedBusy(
        reason: String(
          localized: "The machine’s state changed, so the deletion was not performed. Choose Delete again.",
          bundle: #bundle))
    }
    begin(.delete(name))
    return .started
  }

  private static func isRunning(_ machine: MachineInstance) -> Bool {
    if case .running = machine.runState { true } else { false }
  }

  private static func gibibytes(_ bytes: Int64) -> String {
    let figure = (Double(bytes) / Double(1 << 30)).formatted(
      .number.precision(.fractionLength(0...1)).grouping(.never))
    return "\(figure) GiB"
  }
}
