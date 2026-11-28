#if DEBUG
  import ColimaCore
  import Foundation
  import Synchronization

  final class PreviewLimaCLI: LimaCLI {
    struct Config: Sendable {
      var toolchain = PreviewLimaCLI.installedToolchain
      var listing: Result<LimaListing, LimaCLIError> = .success(PreviewMachineData.emptyListing)
      var templates = PreviewMachineData.templates
      var earlierOperations: [ActiveMachineOperation]? = []
      var runs: [PreviewRunScript] = []
      var terminateEndsRun = true
      var earlierRunStopAccepted = true
    }

    static let installedToolchain = LimaToolchain.found(path: "/opt/homebrew/bin/limactl")

    private struct State {
      var config = Config()
      var processes: [PreviewRunProcess] = []
    }

    private let state = Mutex(State())

    var limaHomeUTF8Count: Int { PreviewMachineData.limaHomeUTF8Count }

    func configure(_ body: (inout Config) -> Void) {
      state.withLock { body(&$0.config) }
    }

    var runCount: Int { state.withLock { $0.processes.count } }

    func emit(_ line: String) {
      state.withLock { $0.processes.last }?.send(line)
    }

    func finishRun(code: Int32) {
      state.withLock { $0.processes.last }?.finish(code: code)
    }

    func preflight() async -> LimaToolchain {
      state.withLock { $0.config.toolchain }
    }

    func listInstances() async throws(LimaCLIError) -> LimaListing {
      if Task.isCancelled { throw .cancelled }
      return try state.withLock { $0.config.listing }.get()
    }

    func listTemplates() async throws(LimaCLIError) -> [MachineTemplate] {
      if Task.isCancelled { throw .cancelled }
      return state.withLock { $0.config.templates }
    }

    func run(_ command: MachineCommand) async -> VMCommandRun {
      let process = PreviewRunProcess()
      let (script, endsOnTerminate) = state.withLock { state -> (PreviewRunScript, Bool) in
        state.processes.append(process)
        let script = state.config.runs.isEmpty ? .hang : state.config.runs.removeFirst()
        return (script, state.config.terminateEndsRun)
      }
      if case .exits(let code, let lines) = script {
        lines.forEach(process.send)
        process.finish(code: code)
      }
      return VMCommandRun(
        events: process.events,
        terminate: {
          if endsOnTerminate { process.finish(code: 143) }
          return true
        })
    }

    func activeOperations() async -> [ActiveMachineOperation]? {
      state.withLock { $0.config.earlierOperations }
    }

    func terminateEarlierRun(runID: UUID) async -> Bool {
      state.withLock { $0.config.earlierRunStopAccepted }
    }
  }

  final class PreviewTerminalLauncher: TerminalLauncher {
    struct Config: Sendable {
      var availability = TerminalAvailability.available
      var openShell: Result<Void, ShellLaunchError> = .success(())
      var customApplication: CustomTerminalApp?
    }

    private let state = Mutex(Config())

    func configure(_ body: (inout Config) -> Void) {
      state.withLock { body(&$0) }
    }

    func availability(of choice: TerminalChoice) async -> TerminalAvailability {
      state.withLock { $0.availability }
    }

    func application(at url: URL) async -> CustomTerminalApp? {
      state.withLock { $0.customApplication }
    }

    func openShell(for name: MachineName, in choice: TerminalChoice) async -> Result<Void, ShellLaunchError> {
      state.withLock { $0.openShell }
    }
  }
#endif
