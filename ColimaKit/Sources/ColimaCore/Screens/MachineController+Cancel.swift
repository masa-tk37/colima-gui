import Foundation

enum MachineOperationEnd {
  case succeeded
  case cancelled
  case failed(MachineFailureCause)
}

extension MachineController {
  public func canCancelCreate(_ name: MachineName) -> Bool {
    let key = name.key
    guard let progress = operations[key], progress.kind == .create, !progress.cancelRequested else { return false }
    switch progress.origin {
    case .thisSession: return activeRuns[key] != nil
    case .earlierSession: return true
    }
  }

  /// The request is recorded before it is sent, so the control is disabled for the whole round trip.
  public func cancelCreate(_ name: MachineName) {
    let key = name.key
    guard canCancelCreate(name), let origin = operations[key]?.origin else { return }
    operations[key]?.cancelRequested = true

    switch origin {
    case .thisSession:
      guard let run = activeRuns[key] else { return }
      cancelReplies[key] = Task { [self] in
        let accepted = await run.terminate()
        if !accepted, activeRuns[key] != nil { operations[key]?.cancelRequested = false }
        return accepted
      }
    case .earlierSession(let runID):
      cancelReplies[key] = Task { [self] in
        let accepted = await cli.terminateEarlierRun(runID: runID)
        settleEarlierSessionReply(accepted: accepted, name: name, runID: runID)
        return accepted
      }
    }
  }

  private func settleEarlierSessionReply(accepted: Bool, name: MachineName, runID: UUID) {
    if accepted {
      acceptedEarlierSessionCancels[runID] = name
      earlierQueryPending = true
    } else if operations[name.key]?.origin == .earlierSession(runID: runID) {
      operations[name.key]?.cancelRequested = false
    }
  }

  /// 128 plus SIGTERM, or SIGKILL when the child ignored the first signal.
  private static let stoppedBySignalCodes: Set<Int32> = [143, 137]

  /// A create counts as cancelled only when the stop was accepted, the child died of that signal and no row is left. A
  /// create that failed by itself just as the user pressed Cancel exits with its own code and stays a failure.
  func endOfOperation(
    _ command: MachineCommand, cause: MachineFailureCause?, cancelAccepted: Bool
  ) -> MachineOperationEnd {
    guard let cause else { return .succeeded }
    if case .create = command, cancelAccepted, case .exited(let code) = cause,
      Self.stoppedBySignalCodes.contains(code), listingShowsNo(command.name)
    {
      return .cancelled
    }
    return .failed(cause)
  }

  private func listingShowsNo(_ name: MachineName) -> Bool {
    guard listError == nil, let listing else { return false }
    return !listing.machines.contains { $0.name.key == name.key }
  }

  /// No exit event reaches this session for an earlier session's create, so the end is when the run leaves the agent's list.
  func resolveEarlierSessionCancels(active: [ActiveMachineOperation]) async {
    let running = Set(active.map(\.runID))
    let ended = acceptedEarlierSessionCancels.filter { !running.contains($0.key) }
    guard !ended.isEmpty else { return }
    for runID in ended.keys { acceptedEarlierSessionCancels[runID] = nil }

    await readAfterOperation()
    for name in ended.values where operations[name.key] == nil && listingShowsNo(name) {
      notice = .createCancelled(name)
    }
  }
}
