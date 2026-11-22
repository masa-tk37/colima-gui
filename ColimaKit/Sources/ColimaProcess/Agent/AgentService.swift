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
package final class AgentService: NSObject, NSXPCListenerDelegate, ColimaAgentProtocol, Sendable {
  private struct ActiveRun {
    let id: UUID
    var terminate: (@Sendable () async -> Bool)?
    var client: ClientProxy?
    let connection: ObjectIdentifier
  }

  private struct State {
    var run: ActiveRun?
    var acceptingRuns = true
    var holdGeneration = 0
  }

  private let state = Mutex(State())
  private let launcher: any VMCommandLauncher
  private let peerRequirement: @Sendable () -> PeerRequirement
  /// True while a colima command started outside this agent instance (an earlier agent, a terminal) is running.
  private let foreignCommandIsRunning: @Sendable () async -> Bool
  private let updateHold: Duration

  package init(
    launcher: any VMCommandLauncher,
    peerRequirement: @escaping @Sendable () -> PeerRequirement,
    foreignCommandIsRunning: @escaping @Sendable () async -> Bool,
    updateHold: Duration = .seconds(30)
  ) {
    self.launcher = launcher
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
      let command = try? JSONDecoder().decode(VMCommand.self, from: command)
    else {
      reply(AgentStartReply.undecodableCommand.rawValue)
      return
    }
    let client = (connection.remoteObjectProxy as? any ColimaAgentClientProtocol).map(
      ClientProxy.init)
    let claim = state.withLock { state -> AgentStartReply in
      guard state.acceptingRuns else { return .updating }
      guard state.run == nil else { return .busy }
      state.run = ActiveRun(id: runID, client: client, connection: ObjectIdentifier(connection))
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
      state.run?.id == runID ? state.run?.terminate : nil
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
      guard state.run == nil else { return nil }
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

  private func launch(runID: UUID, command: VMCommand, reply: @escaping @Sendable (Int) -> Void)
    async
  {
    if await foreignCommandIsRunning() {
      state.withLock { $0.run = nil }
      reply(AgentStartReply.busy.rawValue)
      return
    }
    let run = await launcher.run(command)
    state.withLock { $0.run?.terminate = run.terminate }
    reply(AgentStartReply.accepted.rawValue)

    for await event in run.events {
      let client = state.withLock { $0.run?.client?.proxy }
      switch event {
      case .output(let line): client?.output(runID: runID, line: line)
      case .exited(let code): client?.exited(runID: runID, code: code)
      case .launchFailed(let reason): client?.launchFailed(runID: runID, reason: reason)
      }
    }
    state.withLock { $0.run = nil }
  }

  private func detach(connection: ObjectIdentifier) {
    state.withLock { state in
      if state.run?.connection == connection { state.run?.client = nil }
    }
  }
}

/// NSXPC proxies are safe to message from any thread; the protocol type just cannot say so.
private struct ClientProxy: @unchecked Sendable {
  let proxy: any ColimaAgentClientProtocol
}
