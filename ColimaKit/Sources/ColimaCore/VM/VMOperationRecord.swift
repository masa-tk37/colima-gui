import Foundation
import Observation

public enum VMOperationOutcome: Sendable, Equatable {
  case succeeded
  case failed(VMOperationFailure)
}

/// A class so that appending a line notifies only the views reading `lines`, not everything that reads the controller's `latestRecord`.
@MainActor @Observable
public final class VMOperationRecord: Identifiable {
  public static let lineLimit = 2_000

  public let id = UUID()
  public let kind: VMOperationKind
  public let startedAt: Date
  public private(set) var endedAt: Date?
  public private(set) var outcome: VMOperationOutcome?
  public private(set) var lines: [OutputLine] = []
  @ObservationIgnored private var nextLineNumber = 0

  /// `number` keeps a line's identity once older lines are dropped at `lineLimit`.
  public struct OutputLine: Sendable, Equatable, Identifiable {
    public let number: Int
    public let text: String
    public var id: Int { number }
  }

  public init(kind: VMOperationKind, startedAt: Date) {
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

  func end(_ outcome: VMOperationOutcome, at date: Date) {
    self.outcome = outcome
    endedAt = date
  }
}
