public struct BatchOutcome<Item: Sendable & Hashable>: Sendable, Equatable {
  public let succeeded: [Item]
  public let failed: [Item: String]

  public init(succeeded: [Item], failed: [Item: String]) {
    self.succeeded = succeeded
    self.failed = failed
  }
}

public enum PruneRequestResult: Sendable, Equatable {
  case confirmationRequested, nothingToPrune
}

public struct PruneReport: Sendable, Equatable {
  public let deletedCount: Int
  public let estimatedReclaimedBytes: Int64
  public let unknownSizeCount: Int
  /// Volume name to engine error message.
  public let failures: [String: String]

  public init(deletedSizes: [Int64?], failures: [String: String]) {
    deletedCount = deletedSizes.count
    estimatedReclaimedBytes = deletedSizes.reduce(0) { $0 + ($1 ?? 0) }
    unknownSizeCount = deletedSizes.count { $0 == nil }
    self.failures = failures
  }
}
