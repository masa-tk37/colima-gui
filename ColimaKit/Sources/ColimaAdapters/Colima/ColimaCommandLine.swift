import ColimaCore
import ColimaProcess
import Foundation

/// VM commands go through `vmCommands` (the background agent in the app) so colima's long-lived descendants never
/// join the app's process coalition; the short reads below stay in the app.
public struct ColimaCommandLine: ColimaCLI {
  private let invocation: ColimaInvocation
  private let runner: ProcessRunner
  private let vmCommands: any VMCommandLauncher
  private let usageTimeout: Duration

  public init(agent: AgentClient) {
    self.init(
      invocation: ColimaInvocation(),
      runner: ProcessRunner(),
      vmCommands: agent,
      usageTimeout: .seconds(2)
    )
  }

  init(
    invocation: ColimaInvocation, runner: ProcessRunner, vmCommands: any VMCommandLauncher,
    usageTimeout: Duration
  ) {
    self.invocation = invocation
    self.runner = runner
    self.vmCommands = vmCommands
    self.usageTimeout = usageTimeout
  }

  public func preflight() async -> ToolchainStatus {
    let colimaPath = invocation.colimaPath
    let colima: ToolchainStatus.ColimaLookup =
      isInstalled("colima") ? .found(path: colimaPath) : .missing(searched: [colimaPath])
    let required = Set(VMType.allCases.flatMap(\.requiredExecutables))
    return ToolchainStatus(colima: colima, installedExecutables: required.filter(isInstalled))
  }

  public func listDefault() async throws(ColimaCLIError) -> VMObservation {
    let output = try await collect(["list", "--json"], timeout: nil).successfulStdout()
    return try ColimaListDecoder.decode(output)
  }

  public func run(_ command: VMCommand) async -> VMCommandRun {
    let name = command.arguments.first ?? ""
    ColimaLog.vm.info("colima \(name, privacy: .public) started")

    let run = await vmCommands.run(command)
    // Relaying through a task of our own logs the end even when nobody consumes `events`.
    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    Task {
      for await event in run.events {
        switch event {
        case .exited(let code):
          ColimaLog.vm.info("colima \(name, privacy: .public) exited with code \(code)")
        case .launchFailed(let reason):
          ColimaLog.vm.error(
            "colima \(name, privacy: .public) failed to launch: \(reason, privacy: .public)")
        case .output:
          break
        }
        continuation.yield(event)
      }
      continuation.finish()
    }
    return VMCommandRun(events: events, terminate: run.terminate)
  }

  public func sampleUsage() async throws(ColimaCLIError) -> ProcSnapshot {
    let output = try await collect(
      ["ssh", "--", "cat", "/proc/stat", "/proc/meminfo"], timeout: usageTimeout
    )
    .successfulStdout()
    do {
      return try ProcSnapshot.parse(String(decoding: output, as: UTF8.self))
    } catch {
      throw .undecodable(detail: "/proc/stat and /proc/meminfo: \(error)")
    }
  }

  private func isInstalled(_ name: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: invocation.homebrewDirectory + "/" + name)
  }

  private func collect(_ arguments: [String], timeout: Duration?) async throws(ColimaCLIError)
    -> CollectedRun
  {
    guard isInstalled("colima") else { throw .colimaMissing }
    return await runner.runCollecting(invocation.make(arguments, timeout: timeout))
  }
}
