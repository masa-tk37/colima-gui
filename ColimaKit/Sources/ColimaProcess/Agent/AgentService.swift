import ColimaCore
import Foundation
import Synchronization

package enum PeerRequirement: Sendable {
  /// Only for in-process tests over an anonymous listener.
  case unchecked
  case required(String)
  case unavailable(reason: String)
}

/// A run outlives the connection that started it:
/// the agent keeps reading the child's pipes, since a closed pipe would end colima with SIGPIPE.
/// Each target (the colima VM, one machine) holds at most one run; different targets never wait on each other.
package final class AgentService: NSObject, NSXPCListenerDelegate, ColimaAgentProtocol, Sendable {
  private struct ActiveRun {
    let command: AgentCommand
    var terminate: (@Sendable () async -> Bool)?
    var client: ClientProxy?
    let connection: ObjectIdentifier
  }

  private struct State {
    var runs: [UUID: ActiveRun] = [:]
    var acceptingRuns = true
    var holdGeneration = 0
  }

  private let state = Mutex(State())
  private let vmLauncher: any VMCommandLauncher
  private let machineLauncher: any MachineCommandLauncher
  private let peerRequirement: @Sendable () -> PeerRequirement
  private let foreignCommandIsRunning: @Sendable (AgentTarget) async -> Bool
  private let updateHold: Duration

  package init(
    vmLauncher: any VMCommandLauncher,
    machineLauncher: any MachineCommandLauncher,
    peerRequirement: @escaping @Sendable () -> PeerRequirement,
    foreignCommandIsRunning: @escaping @Sendable (AgentTarget) async -> Bool,
    updateHold: Duration = .seconds(30)
  ) {
    self.vmLauncher = vmLauncher
    self.machineLauncher = machineLauncher
    self.peerRequirement = peerRequirement
    self.foreignCommandIsRunning = foreignCommandIsRunning
    self.updateHold = updateHold
  }

  package func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    switch peerRequirement() {
    case .unchecked:
      break
    case .required(let requirement):
      connection.setCodeSigningRequirement(requirement)
    case .unavailable(let reason):
      ColimaLog.process.error("agent rejected a connection: \(reason, privacy: .public)")
      return false
    }
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedObject = self
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    let id = ObjectIdentifier(connection)
    connection.invalidationHandler = { [weak self] in self?.detach(connection: id) }
    connection.resume()
    return true
  }

  package func hello(reply: @escaping @Sendable (Int) -> Void) {
    reply(AgentXPC.protocolVersion)
  }

  package func start(runID: UUID, command: Data, reply: @escaping @Sendable (Int) -> Void) {
    guard let connection = NSXPCConnection.current(),
      let command = try? JSONDecoder().decode(AgentCommand.self, from: command)
    else {
      reply(AgentStartReply.undecodableCommand.rawValue)
      return
    }
    let client = (connection.remoteObjectProxy as? any ColimaAgentClientProtocol).map(
      ClientProxy.init)
    let claim = state.withLock { state -> AgentStartReply in
      guard state.acceptingRuns else { return .updating }
      guard !state.runs.values.contains(where: { $0.command.target == command.target }) else { return .busy }
      state.runs[runID] = ActiveRun(
        command: command, client: client, connection: ObjectIdentifier(connection))
      return .accepted
    }
    guard claim == .accepted else {
      reply(claim.rawValue)
      return
    }
    Task { await self.launch(runID: runID, command: command, reply: reply) }
  }

  package func terminate(runID: UUID, reply: @escaping @Sendable (Bool) -> Void) {
    let terminate = state.withLock { state in
      state.runs[runID]?.terminate
    }
    guard let terminate else {
      reply(false)
      return
    }
    Task { reply(await terminate()) }
  }

  /// The pause lapses after `updateHold`: an app whose unregister fails must not leave the agent refusing every run.
  package func prepareForUpdate(reply: @escaping @Sendable (Bool) -> Void) {
    let hold = state.withLock { state -> Int? in
      guard state.runs.isEmpty else { return nil }
      state.acceptingRuns = false
      state.holdGeneration += 1
      return state.holdGeneration
    }
    reply(hold != nil)
    guard let hold else { return }
    let updateHold = updateHold
    Task {
      try? await Task.sleep(for: updateHold)
      state.withLock { state in
        if state.holdGeneration == hold { state.acceptingRuns = true }
      }
    }
  }

  package func activeRuns(reply: @escaping @Sendable (Data) -> Void) {
    let summaries = state.withLock { state in
      state.runs.map { AgentRunSummary(runID: $0.key, command: $0.value.command) }
    }
    // Encoding plain Codable values cannot fail; an empty list is the safe reading if it ever did.
    reply((try? JSONEncoder().encode(summaries)) ?? Data("[]".utf8))
  }

  private func launch(
    runID: UUID, command: AgentCommand, reply: @escaping @Sendable (Int) -> Void
  ) async {
    if await foreignCommandIsRunning(command.target) {
      _ = state.withLock { $0.runs.removeValue(forKey: runID) }
      reply(AgentStartReply.busy.rawValue)
      return
    }
    let run =
      switch command {
      case .colima(let command): await vmLauncher.run(command)
      case .machine(let command): await machineLauncher.run(command)
      }
    state.withLock { $0.runs[runID]?.terminate = run.terminate }
    reply(AgentStartReply.accepted.rawValue)

    for await event in run.events {
      let client = state.withLock { $0.runs[runID]?.client?.proxy }
      switch event {
      case .output(let line): client?.output(runID: runID, line: line)
      case .exited(let code): client?.exited(runID: runID, code: code)
      case .launchFailed(let reason): client?.launchFailed(runID: runID, reason: reason)
      }
    }
    _ = state.withLock { $0.runs.removeValue(forKey: runID) }
  }

  private func detach(connection: ObjectIdentifier) {
    state.withLock { state in
      for (runID, run) in state.runs where run.connection == connection {
        state.runs[runID]?.client = nil
      }
    }
  }
}

/// NSXPC proxies are safe to message from any thread; the protocol type just cannot say so.
private struct ClientProxy: @unchecked Sendable {
  let proxy: any ColimaAgentClientProtocol
}
