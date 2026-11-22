import ColimaCore
import ColimaProcess
import Foundation
import Synchronization

extension AgentClient {
  public static func live() -> AgentClient {
    AgentClient(
      makeConnection: {
        let connection = NSXPCConnection(machServiceName: AgentXPC.serviceName)
        connection.setCodeSigningRequirement("identifier \"\(AgentXPC.serviceName)\"")
        return connection
      },
      registration: { AgentRegistration.registerIfNeeded() },
      acceptTimeout: .seconds(30)
    )
  }

  public enum UpdateReadiness: Sendable, Equatable {
    case idle
    case busy
    /// No answer: the agent is not running a protocol this app speaks, so there is nothing to coordinate with.
    case unreachable
  }
}

final class CallbackReceiver: NSObject, ColimaAgentClientProtocol, Sendable {
  private let deliver: @Sendable (UUID, ProcessEvent) -> Void

  init(deliver: @escaping @Sendable (UUID, ProcessEvent) -> Void) {
    self.deliver = deliver
  }

  func output(runID: UUID, line: String) { deliver(runID, .output(line)) }
  func exited(runID: UUID, code: Int32) { deliver(runID, .exited(code: code)) }
  func launchFailed(runID: UUID, reason: String) { deliver(runID, .launchFailed(reason: reason)) }
}

/// The reply, the error handler and the deadline all race to resume; only the first one counts.
final class ResumeOnce<Value: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<Value, Never>?>

  init(_ continuation: CheckedContinuation<Value, Never>) {
    self.continuation = Mutex(continuation)
  }

  func resume(_ value: Value) {
    let pending = continuation.withLock { stored in
      defer { stored = nil }
      return stored
    }
    pending?.resume(returning: value)
  }
}
