import Foundation

public enum VMOperationKind: Sendable, Equatable {
  case start, stop, restart, create, recreate
}

public enum VMOperationStage: Sendable, Equatable {
  case preflight, starting, stopping, deleting, creating

  /// Stages that wait on a long-running `colima` child process; the others finish quickly or must not be interrupted.
  fileprivate var runsAbortableChildProcess: Bool {
    switch self {
    case .starting, .stopping, .creating: true
    case .preflight, .deleting: false
    }
  }
}

public enum VMFailureCause: Sendable, Equatable {
  case exited(code: Int32)
  case launchFailed(reason: String)
  case missingExecutables(VMType, [String])
  case stillPresentAfterDelete
  /// The delete command succeeded but `list` could not be read, so absence is unproven and the create does not run.
  case deleteNotConfirmed
  /// The stop command succeeded but the VM was not read back as stopped, so a restart does not go on to start it.
  case stopNotConfirmed
  case aborted
}

/// `id` tells one failure from the next, so a screen can hide a failure the user has seen and still show a new one.
public struct VMOperationFailure: Sendable, Equatable, Identifiable {
  public static let outputTailLimit = 50

  public let id = UUID()
  public let kind: VMOperationKind
  public let stage: VMOperationStage
  public let cause: VMFailureCause
  public let outputTail: [String]

  public init(
    kind: VMOperationKind, stage: VMOperationStage, cause: VMFailureCause, outputLines: [String]
  ) {
    self.kind = kind
    self.stage = stage
    self.cause = cause
    self.outputTail = Array(outputLines.suffix(Self.outputTailLimit))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.stage == rhs.stage && lhs.cause == rhs.cause
      && lhs.outputTail == rhs.outputTail
  }
}

public struct VMOperationProgress: Sendable, Equatable {
  public static let abortDelay: TimeInterval = 180

  public let kind: VMOperationKind
  public private(set) var stage: VMOperationStage
  public let startedAt: Date
  public private(set) var stageStartedAt: Date
  public private(set) var lastOutputAt: Date?

  public init(kind: VMOperationKind, stage: VMOperationStage, startedAt: Date, stageStartedAt: Date)
  {
    self.kind = kind
    self.stage = stage
    self.startedAt = startedAt
    self.stageStartedAt = stageStartedAt
  }

  public mutating func advance(to stage: VMOperationStage, at now: Date) {
    self.stage = stage
    stageStartedAt = now
  }

  /// The lines themselves go to the controller's `latestRecord`.
  public mutating func noteOutput(at now: Date) {
    lastOutputAt = now
  }

  public func isAbortAvailable(at now: Date) -> Bool {
    stage.runsAbortableChildProcess && now.timeIntervalSince(stageStartedAt) >= Self.abortDelay
  }
}

public enum VMDisplayState: Sendable, Equatable {
  case running, stopped, starting, stopping

  /// Absent and unknown VMs read as stopped; the menu's status text tells them apart.
  public init(observation: VMObservation, activeOperation: VMOperationProgress?) {
    if let activeOperation {
      self = Self.state(of: activeOperation)
      return
    }
    switch observation {
    case .present(let instance) where instance.runState.isRunning:
      self = .running
    case .present, .absent, .unknown:
      self = .stopped
    }
  }

  private static func state(of operation: VMOperationProgress) -> VMDisplayState {
    switch operation.stage {
    case .starting, .creating:
      .starting
    case .stopping, .deleting:
      .stopping
    case .preflight:
      // Create begins on colima's start side, recreate by tearing down; the other kinds never enter preflight.
      operation.kind == .create || operation.kind == .start ? .starting : .stopping
    }
  }
}
