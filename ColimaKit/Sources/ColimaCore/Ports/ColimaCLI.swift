public protocol ColimaCLI: Sendable {
  func preflight() async -> ToolchainStatus
  /// Runs `colima list --json`; `.absent` when no row is named `default`.
  func listDefault() async throws(ColimaCLIError) -> VMObservation
  func run(_ command: VMCommand) async -> VMCommandRun
  func sampleUsage() async throws(ColimaCLIError) -> ProcSnapshot
}

public struct VMCommandRun: Sendable {
  /// Always ends with `.exited` or `.launchFailed`, also after `terminate`.
  public let events: AsyncStream<ProcessEvent>
  /// The only way to stop the child: SIGTERM, then SIGKILL after 10 s. Cancelling the task that consumes `events` does not.
  /// Returns whether the stop was accepted; false when the child already ended or the runner is unreachable.
  public let terminate: @Sendable () async -> Bool

  public init(events: AsyncStream<ProcessEvent>, terminate: @escaping @Sendable () async -> Bool) {
    self.events = events
    self.terminate = terminate
  }
}

public enum ProcessEvent: Sendable, Equatable {
  /// One line; stdout and stderr interleaved in arrival order.
  case output(String)
  case exited(code: Int32)
  case launchFailed(reason: String)
}

public enum ColimaCLIError: Error, Equatable {
  case colimaMissing
  case launchFailed(reason: String)
  /// The last 50 stderr lines, or the stdout lines when stderr is empty.
  case nonZeroExit(code: Int32, output: [String])
  case undecodable(detail: String)
  case timedOut
  case cancelled
}
