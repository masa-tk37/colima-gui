import Foundation
import Observation

public enum MachineOperationKind: String, Sendable, Codable {
  case create, start, stop, delete, edit
}

public enum MachineOperationOrigin: Sendable, Equatable {
  case thisSession(startedAt: Date)
  case earlierSession(runID: UUID)
}

public struct MachineOperationProgress: Sendable, Equatable {
  public let kind: MachineOperationKind
  public let origin: MachineOperationOrigin
  public internal(set) var cancelRequested: Bool

  public init(kind: MachineOperationKind, origin: MachineOperationOrigin) {
    self.kind = kind
    self.origin = origin
    cancelRequested = false
  }
}

public enum MachineFailureCause: Sendable, Equatable {
  case exited(code: Int32)
  case launchFailed(reason: String)
}

public struct MachineOperationFailure: Sendable, Equatable, Identifiable {
  public static let outputTailLimit = 50

  public let id = UUID()
  public let name: MachineName
  public let kind: MachineOperationKind
  public let cause: MachineFailureCause
  public let outputTail: [String]

  public init(
    name: MachineName, kind: MachineOperationKind, cause: MachineFailureCause, outputLines: [String]
  ) {
    self.name = name
    self.kind = kind
    self.cause = cause
    self.outputTail = Array(outputLines.suffix(Self.outputTailLimit))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.kind == rhs.kind && lhs.cause == rhs.cause
      && lhs.outputTail == rhs.outputTail
  }
}

public enum MachineOperationOutcome: Sendable, Equatable {
  case succeeded
  case failed(MachineOperationFailure)
  case cancelled
}

public enum MachineNotice: Sendable, Equatable {
  case editSaved(MachineName)
  case createCancelled(MachineName)
}

/// A class so that appending a line notifies only the views reading `lines`, not everything that reads the controller's `records`.
@MainActor @Observable
public final class MachineOperationRecord: Identifiable {
  public static let lineLimit = 2_000

  public let id = UUID()
  public let kind: MachineOperationKind
  public let startedAt: Date
  public private(set) var endedAt: Date?
  public private(set) var outcome: MachineOperationOutcome?
  public private(set) var lines: [OutputLine] = []
  @ObservationIgnored private var nextLineNumber = 0

  /// `number` keeps a line's identity once older lines are dropped at `lineLimit`.
  public struct OutputLine: Sendable, Equatable, Identifiable {
    public let number: Int
    public let text: String
    public var id: Int { number }
  }

  public init(kind: MachineOperationKind, startedAt: Date) {
    self.kind = kind
    self.startedAt = startedAt
  }

  public var texts: [String] { lines.map(\.text) }

  func append(_ text: String) {
    lines.append(OutputLine(number: nextLineNumber, text: text))
    nextLineNumber += 1
    if lines.count > Self.lineLimit {
      lines.removeFirst(lines.count - Self.lineLimit)
    }
  }

  func end(_ outcome: MachineOperationOutcome, at date: Date) {
    self.outcome = outcome
    endedAt = date
  }
}
