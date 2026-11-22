import ColimaCore
import ColimaProcess
import Foundation
import ServiceManagement
import Synchronization

/// Every run ends with exactly one terminal event, whichever arrives first:
/// the agent's own `exited`/`launchFailed`, a rejected `start`, a lost connection, or no answer to `start` in time.
public final class AgentClient: VMCommandLauncher, Sendable {
  private struct PendingRun {
    let continuation: AsyncStream<ProcessEvent>.Continuation
    let generation: Int
    var accepted = false

      var lostEvent: ProcessEvent {
      .launchFailed(reason: accepted ? AgentMessages.helperStopped : AgentMessages.resultUnknown)
    }
  }

  private struct Link {
    let connection: NSXPCConnection
    let generation: Int
  }

  private struct State {
    var link: Link?
    var nextGeneration = 0
    var runs: [UUID: PendingRun] = [:]
  }

  private let state = Mutex(State())
  private let makeConnection: @Sendable () -> NSXPCConnection
  private let registration: @Sendable () -> AgentRegistration
  private let acceptTimeout: Duration

  init(
    makeConnection: @escaping @Sendable () -> NSXPCConnection,
    registration: @escaping @Sendable () -> AgentRegistration,
    acceptTimeout: Duration
  ) {
    self.makeConnection = makeConnection
    self.registration = registration
    self.acceptTimeout = acceptTimeout
  }

  package func run(_ command: VMCommand) async -> VMCommandRun {
    let runID = UUID()
    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    // The run keeps the client alive: callbacks reach it only through weak references held by the connection.
    let run = VMCommandRun(events: events, terminate: { await self.terminate(runID) })

    let fail = { (reason: String) -> VMCommandRun in
      continuation.yield(.launchFailed(reason: reason))
      continuation.finish()
      return run
    }
    if let refusal = AgentMessages.refusal(for: registration()) { return fail(refusal) }
    guard let payload = try? JSONEncoder().encode(command) else {
      return fail(AgentMessages.rejected(.undecodableCommand))
    }

    let link = currentLink()
    let version = await call(link.connection, onError: nil) { proxy, reply in
      proxy.hello { reply($0) }
    }
    guard let version else { return fail(AgentMessages.helperStopped) }
    guard version == AgentXPC.protocolVersion else { return fail(AgentMessages.versionMismatch) }

    state.withLock {
      $0.runs[runID] = PendingRun(continuation: continuation, generation: link.generation)
    }
    let proxy =
      link.connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
        self?.finish(runID) { $0.lostEvent }
      } as? any ColimaAgentProtocol
    proxy?.start(runID: runID, command: payload) { [weak self] raw in
      self?.startReplied(runID, reply: AgentStartReply(rawValue: raw) ?? .undecodableCommand)
    }
    Task {
      try? await Task.sleep(for: acceptTimeout)
      expireIfUnaccepted(runID)
    }
    return run
  }

  public func prepareForUpdate() async -> UpdateReadiness {
    await call(currentLink().connection, onError: .unreachable) { proxy, reply in
      proxy.prepareForUpdate { reply($0 ? .idle : .busy) }
    }
  }

  private func terminate(_ runID: UUID) async -> Bool {
    let connection = state.withLock { state -> NSXPCConnection? in
      guard let run = state.runs[runID], let link = state.link, link.generation == run.generation
      else { return nil }
      return link.connection
    }
    guard let connection else { return false }
    return await call(connection, onError: false) { proxy, reply in
      proxy.terminate(runID: runID) { reply($0) }
    }
  }

  private func currentLink() -> Link {
    state.withLock { state in
      if let link = state.link { return link }
      let generation = state.nextGeneration
      state.nextGeneration += 1
      let connection = makeConnection()
      connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
      connection.exportedInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
      connection.exportedObject = CallbackReceiver { [weak self] runID, event in
        self?.deliver(runID, event)
      }
      connection.interruptionHandler = { [weak self] in self?.connectionLost(generation) }
      connection.invalidationHandler = { [weak self] in self?.connectionLost(generation) }
      connection.resume()
      let link = Link(connection: connection, generation: generation)
      state.link = link
      return link
    }
  }

  /// The agent may have died mid-run; whatever it was doing to the VM may still be under way, so runs fail rather than retry.
  private func connectionLost(_ generation: Int) {
    let (lost, connection) = state.withLock { state in
      let lost = state.runs.values.filter { $0.generation == generation }
        .map { ($0.continuation, $0.lostEvent) }
      state.runs = state.runs.filter { $0.value.generation != generation }
      guard state.link?.generation == generation else { return (lost, nil as NSXPCConnection?) }
      defer { state.link = nil }
      return (lost, state.link?.connection)
    }
    for (continuation, event) in lost {
      continuation.yield(event)
      continuation.finish()
    }
    connection?.invalidate()
  }

  /// Falls back after `acceptTimeout` too: an agent that never answers (a stale build, a hung process) gets no error.
  private func call<Reply: Sendable>(
    _ connection: NSXPCConnection,
    onError fallback: Reply,
    _ body:
      @escaping @Sendable (any ColimaAgentProtocol, @escaping @Sendable (Reply) -> Void) -> Void
  ) async -> Reply {
    let timeout = acceptTimeout
    return await withCheckedContinuation { continuation in
      let once = ResumeOnce(continuation)
      Task {
        try? await Task.sleep(for: timeout)
        once.resume(fallback)
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(fallback) }
      guard let proxy = proxy as? any ColimaAgentProtocol else {
        once.resume(fallback)
        return
      }
      body(proxy) { once.resume($0) }
    }
  }

  private func deliver(_ runID: UUID, _ event: ProcessEvent) {
    guard case .output = event else {
      finish(runID, with: event)
      return
    }
    state.withLock { state in
      guard state.runs[runID] != nil else { return }
      state.runs[runID]?.accepted = true
      state.runs[runID]?.continuation.yield(event)
    }
  }

  private func startReplied(_ runID: UUID, reply: AgentStartReply) {
    guard reply == .accepted else {
      finish(runID, with: .launchFailed(reason: AgentMessages.rejected(reply)))
      return
    }
    state.withLock { $0.runs[runID]?.accepted = true }
  }

  private func expireIfUnaccepted(_ runID: UUID) {
    let unaccepted = state.withLock { $0.runs[runID].map { !$0.accepted } ?? false }
    if unaccepted { finish(runID, with: .launchFailed(reason: AgentMessages.resultUnknown)) }
  }

  private func finish(_ runID: UUID, with event: ProcessEvent) {
    finish(runID) { _ in event }
  }

  /// Yields under the lock so a terminal event can never overtake an output line of the same run.
  private func finish(_ runID: UUID, with makeEvent: (PendingRun) -> ProcessEvent) {
    state.withLock { state in
      guard let run = state.runs.removeValue(forKey: runID) else { return }
      run.continuation.yield(makeEvent(run))
      run.continuation.finish()
    }
  }
}
