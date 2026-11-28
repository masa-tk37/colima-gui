import ColimaCore
import Foundation

@MainActor
struct MachineOperationPresentation: Equatable {
  enum Status: Equatable {
    case idle, running, earlierSession, succeeded, failed, cancelled
  }

  enum CancelControl: Equatable {
    case hidden
    case enabled
    case disabled
    case requested
  }

  let status: Status
  let kind: MachineOperationKind?
  let startedAt: Date?
  let endedAt: Date?
  let cancel: CancelControl
  let failure: MachineOperationFailure?
  let showsOutput: Bool

  var showsFailure: Bool { failure != nil }
  var showsEarlierSessionNotice: Bool { status == .earlierSession }
  var isEmpty: Bool { status == .idle }

  init(
    progress: MachineOperationProgress?, record: MachineOperationRecord?, failure: MachineOperationFailure?,
    canCancel: Bool
  ) {
    guard let progress else {
      cancel = .hidden
      self.failure = failure
      kind = record?.kind ?? failure?.kind
      startedAt = record?.startedAt
      endedAt = record?.endedAt
      showsOutput = record != nil
      status = Self.status(of: record, failure: failure)
      return
    }
    kind = progress.kind
    self.failure = nil
    endedAt = nil
    cancel = Self.cancelControl(for: progress, canCancel: canCancel)
    switch progress.origin {
    case .thisSession(let startedAt):
      status = .running
      self.startedAt = startedAt
      showsOutput = record != nil
    case .earlierSession:
      status = .earlierSession
      startedAt = nil
      showsOutput = false
    }
  }

  private static func status(of record: MachineOperationRecord?, failure: MachineOperationFailure?) -> Status {
    switch record?.outcome {
    case .succeeded?: .succeeded
    case .failed?: .failed
    case .cancelled?: .cancelled
    case nil: failure != nil ? .failed : (record == nil ? .idle : .running)
    }
  }

  private static func cancelControl(for progress: MachineOperationProgress, canCancel: Bool) -> CancelControl {
    guard progress.kind == .create else { return .hidden }
    if progress.cancelRequested { return .requested }
    return canCancel ? .enabled : .disabled
  }

  func elapsedSeconds(at now: Date) -> Int? {
    guard let startedAt else { return nil }
    return max(0, Int((endedAt ?? now).timeIntervalSince(startedAt)))
  }
}
