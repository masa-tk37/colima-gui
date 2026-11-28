import Foundation

package enum AgentXPC {
  package static let serviceName = "cc.tk37.ColimaGUI.agent"
  package static let plistName = "cc.tk37.ColimaGUI.agent.plist"
  package static let appIdentifier = "cc.tk37.ColimaGUI"
  /// Bumped whenever a message below changes shape, so a stale agent is detected instead of misread.
  package static let protocolVersion = 2
}

package enum AgentStartReply: Int, Sendable {
  case accepted = 0
  case busy
  case undecodableCommand
  case updating
}

@objc package protocol ColimaAgentProtocol {
  /// Has no side effect; replies with the agent's `AgentXPC.protocolVersion`.
  func hello(reply: @escaping @Sendable (Int) -> Void)
  /// `command` is a JSON-encoded `AgentCommand`; replies with an `AgentStartReply` raw value.
  func start(runID: UUID, command: Data, reply: @escaping @Sendable (Int) -> Void)
  /// Replies whether a running child was signaled.
  func terminate(runID: UUID, reply: @escaping @Sendable (Bool) -> Void)
  /// Replies true and stops accepting runs when idle; replies false and keeps accepting while a run is alive.
  func prepareForUpdate(reply: @escaping @Sendable (Bool) -> Void)
  /// Replies with a JSON `[AgentRunSummary]` of the runs alive now. Has no side effect and never replays output.
  func activeRuns(reply: @escaping @Sendable (Data) -> Void)
}

/// Exported by the app on the same connection; events for one run arrive in order.
@objc package protocol ColimaAgentClientProtocol {
  func output(runID: UUID, line: String)
  func exited(runID: UUID, code: Int32)
  func launchFailed(runID: UUID, reason: String)
}
