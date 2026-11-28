import ColimaCore
import ColimaProcess
import Foundation

protocol MachineAgent: MachineCommandLauncher {
  func activeRuns() async -> [AgentRunSummary]?
  func terminateEarlierRun(runID: UUID) async -> Bool
}

extension AgentClient: MachineAgent {}

/// Machine commands go through `agent` so limactl's long-lived descendants never join the app's process
/// coalition; the short reads below stay in the app.
public struct LimaCommandLine: LimaCLI {
  private let invocation: LimaInvocation
  private let runner: ProcessRunner
  private let agent: any MachineAgent
  private let readTimeout: Duration

  public init(agent: AgentClient) {
    self.init(invocation: LimaInvocation(), runner: ProcessRunner(), agent: agent)
  }

  /// A hung `limactl list` (a wedged host agent) must not hold the machine list or a create behind it forever.
  init(
    invocation: LimaInvocation, runner: ProcessRunner, agent: any MachineAgent, readTimeout: Duration = .seconds(30)
  ) {
    self.invocation = invocation
    self.runner = runner
    self.agent = agent
    self.readTimeout = readTimeout
  }

  public var limaHomeUTF8Count: Int { invocation.limaHomeUTF8Count }

  public func preflight() async -> LimaToolchain {
    let path = invocation.limactlPath
    return limactlIsInstalled ? .found(path: path) : .missing(searched: [path])
  }

  public func listInstances() async throws(LimaCLIError) -> LimaListing {
    let output = try await collect(["list", "--json"]).limaStdout()
    return LimaListDecoder.decode(output)
  }

  public func listTemplates() async throws(LimaCLIError) -> [MachineTemplate] {
    let output = try await collect(["create", "--list-templates"]).limaStdout()
    let ids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    return MachineTemplate.linuxTemplates(from: ids)
  }

  public func run(_ command: MachineCommand) async -> VMCommandRun {
    let operation = command.kind.rawValue
    let instance = command.name.instanceName
    guard limactlIsInstalled else {
      let reason = String(localized: "limactl was not found at \(invocation.limactlPath).", bundle: #bundle)
      ColimaLog.machine.error(
        "limactl \(operation, privacy: .public) \(instance, privacy: .public) not started: limactl is missing")
      return VMCommandRun(
        events: AsyncStream { continuation in
          continuation.yield(.launchFailed(reason: reason))
          continuation.finish()
        },
        terminate: { false })
    }

    ColimaLog.machine.info("limactl \(operation, privacy: .public) \(instance, privacy: .public) started")
    let run = await agent.run(command)
    // Relaying through a task of our own logs the end even when nobody consumes `events`.
    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    Task {
      for await event in run.events {
        switch event {
        case .exited(let code):
          ColimaLog.machine.info(
            "limactl \(operation, privacy: .public) \(instance, privacy: .public) exited with code \(code)")
        case .launchFailed(let reason):
          ColimaLog.machine.error(
            "limactl \(operation, privacy: .public) \(instance, privacy: .public) failed to launch: \(reason, privacy: .public)"
          )
        case .output:
          break
        }
        continuation.yield(event)
      }
      continuation.finish()
    }
    return VMCommandRun(events: events, terminate: run.terminate)
  }

  public func activeOperations() async -> [ActiveMachineOperation]? {
    guard let runs = await agent.activeRuns() else { return nil }
    return runs.compactMap { summary in
      guard case .machine(let command) = summary.command else { return nil }
      return ActiveMachineOperation(runID: summary.runID, name: command.name, kind: command.kind)
    }
  }

  public func terminateEarlierRun(runID: UUID) async -> Bool {
    await agent.terminateEarlierRun(runID: runID)
  }

  private var limactlIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: invocation.limactlPath)
  }

  private func collect(_ arguments: [String]) async throws(LimaCLIError) -> CollectedRun {
    guard limactlIsInstalled else { throw .limactlMissing }
    try? invocation.prepareWorkingDirectory()
    return await runner.runCollecting(invocation.make(arguments, timeout: readTimeout))
  }
}

extension CollectedRun {
  fileprivate func limaStdout() throws(LimaCLIError) -> [UInt8] {
    switch termination {
    case .exited(code: 0):
      return stdout
    case .exited(let code):
      let stderrLines = Self.tail(stderrText)
      throw .nonZeroExit(code: code, output: stderrLines.isEmpty ? Self.tail(stdoutText) : stderrLines)
    case .timedOut:
      throw .launchFailed(reason: String(localized: "limactl did not respond in time.", bundle: #bundle))
    case .cancelled:
      throw .cancelled
    case .launchFailed(let reason):
      throw .launchFailed(reason: reason)
    }
  }
}
