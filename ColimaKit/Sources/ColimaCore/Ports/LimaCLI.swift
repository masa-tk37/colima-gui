import Foundation

public protocol LimaCLI: Sendable {
  /// UTF-8 length of the resolved `~/.lima` path; it bounds machine names.
  var limaHomeUTF8Count: Int { get }
  func preflight() async -> LimaToolchain
  func listInstances() async throws(LimaCLIError) -> LimaListing
  func listTemplates() async throws(LimaCLIError) -> [MachineTemplate]
  /// Same contract as `ColimaCLI.run`: `events` always ends with `.exited` or `.launchFailed`.
  func run(_ command: MachineCommand) async -> VMCommandRun
  /// `nil` when the agent is unreachable or predates the machine operations.
  func activeOperations() async -> [ActiveMachineOperation]?
  /// Stops a run this app session did not start; true when the agent accepted the stop.
  func terminateEarlierRun(runID: UUID) async -> Bool
}

public enum LimaToolchain: Sendable, Equatable {
  case found(path: String)
  case missing(searched: [String])
}

public enum LimaCLIError: Error, Equatable {
  case limactlMissing
  case launchFailed(reason: String)
  /// The last 50 stderr lines, or the stdout lines when stderr is empty.
  case nonZeroExit(code: Int32, output: [String])
  case cancelled
}

public struct ActiveMachineOperation: Sendable, Equatable {
  public let runID: UUID
  public let name: MachineName
  public let kind: MachineOperationKind

  public init(runID: UUID, name: MachineName, kind: MachineOperationKind) {
    self.runID = runID
    self.name = name
    self.kind = kind
  }
}
