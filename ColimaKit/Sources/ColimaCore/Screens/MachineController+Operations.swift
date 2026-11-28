import Foundation

public enum MachineRequestOutcome: Sendable, Equatable {
  case started, confirmationRequested, busy, notApplicable
}

extension MachineController {
  static let finalReadAttempts = 3

  // MARK: Whether an operation can start

  public func canStart(_ name: MachineName) -> Bool {
    if case .stopped? = idleMachine(name)?.runState { true } else { false }
  }

  public func canStop(_ name: MachineName) -> Bool {
    if case .running? = idleMachine(name)?.runState { true } else { false }
  }

  public func canDelete(_ name: MachineName) -> Bool {
    idleMachine(name) != nil
  }

  func idleMachine(_ name: MachineName) -> MachineInstance? {
    let key = name.key
    guard isLimactlFound, operations[key] == nil else { return nil }
    return listing?.machines.first { $0.name.key == key }
  }

  // MARK: Requests

  /// `requestStart` holds a memory warning for approval; this runs the start once that is settled.
  @discardableResult
  func performStart(_ name: MachineName) -> MachineRequestOutcome {
    request(.start(name), allowed: canStart(name))
  }

  @discardableResult
  public func stop(_ name: MachineName) -> MachineRequestOutcome {
    request(.stop(name), allowed: canStop(name))
  }

  /// Synchronous for the same reason as `create`: the check and the slot are one step.
  private func request(_ command: MachineCommand, allowed: Bool) -> MachineRequestOutcome {
    guard operations[command.name.key] == nil else { return .busy }
    guard allowed else { return .notApplicable }
    begin(command)
    return .started
  }

  public func dismissFailure(for name: MachineName) {
    failures[name.key] = nil
  }

  // MARK: Running

  func begin(_ command: MachineCommand) {
    let key = command.name.key
    let startedAt = Date()
    operations[key] = MachineOperationProgress(kind: command.kind, origin: .thisSession(startedAt: startedAt))
    let record = MachineOperationRecord(kind: command.kind, startedAt: startedAt)
    records[key] = record
    failures[key] = nil
    cancelReplies[key] = nil
    operationGeneration += 1
    ColimaLog.machine.info("operation started: kind=\(command.kind.rawValue, privacy: .public)")
    operationTasks[key] = Task { await run(command, record: record) }
  }

  private func run(_ command: MachineCommand, record: MachineOperationRecord) async {
    let run = await cli.run(command)
    activeRuns[command.name.key] = run
    var terminal: ProcessEvent?
    for await event in run.events {
      switch event {
      case .output(let line): record.append(line)
      case .exited, .launchFailed: terminal = event
      }
    }
    activeRuns[command.name.key] = nil

    let cause: MachineFailureCause?
    switch terminal {
    case .exited(code: 0)?: cause = nil
    case .exited(let code)?: cause = .exited(code: code)
    case .launchFailed(let reason)?: cause = .launchFailed(reason: reason)
    case .output?, nil:
      cause = .launchFailed(reason: String(localized: "limactl output ended unexpectedly", bundle: #bundle))
    }
    await finish(command, record: record, cause: cause)
  }

  /// The slot stays held through the final read, so the screen never shows the state from before the operation.
  private func finish(_ command: MachineCommand, record: MachineOperationRecord, cause: MachineFailureCause?) async {
    let key = command.name.key
    operationGeneration += 1
    let cancelAccepted = await cancelReplies[key]?.value ?? false
    await readAfterOperation()

    let kind = command.kind.rawValue
    switch endOfOperation(command, cause: cause, cancelAccepted: cancelAccepted) {
    case .succeeded:
      if case .edit = command { notice = .editSaved(command.name) }
      record.end(.succeeded, at: Date())
      ColimaLog.machine.info("operation finished: kind=\(kind, privacy: .public)")
    case .cancelled:
      notice = .createCancelled(command.name)
      record.end(.cancelled, at: Date())
      ColimaLog.machine.info("operation cancelled: kind=\(kind, privacy: .public)")
    case .failed(let cause):
      let failure = MachineOperationFailure(
        name: command.name, kind: command.kind, cause: cause, outputLines: record.texts)
      failures[key] = failure
      record.end(.failed(failure), at: Date())
      ColimaLog.machine.error("operation failed: kind=\(kind, privacy: .public)")
    }
    operations[key] = nil
    creatingNames[key] = nil
    activeRuns[key] = nil
    cancelReplies[key] = nil
    operationTasks[key] = nil
  }

  func readAfterOperation() async {
    for _ in 0..<Self.finalReadAttempts {
      if await read() { break }
    }
  }
}
