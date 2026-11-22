#if DEBUG
  import ColimaCore
  import Foundation
  import Synchronization

  enum PreviewRunScript: Sendable {
    /// Stays open until `terminate` (exit code 143) or `PreviewColimaCLI.finishRun(code:)`.
    case hang
    case exits(code: Int32, lines: [String])
  }

  final class PreviewColimaCLI: ColimaCLI {
    struct Config: Sendable {
      var toolchain = PreviewColimaCLI.installedToolchain
      var observation: Result<VMObservation, ColimaCLIError> = .success(.absent)
      var runs: [PreviewRunScript] = []
      var usageFailure: ColimaCLIError?
    }

    static let installedToolchain = ToolchainStatus(
      colima: .found(path: "/opt/homebrew/bin/colima"),
      installedExecutables: ["qemu-img", "qemu-system-aarch64", "krunkit"]
    )

    private final class Process: Sendable {
      private let isFinished = Mutex(false)
      let events: AsyncStream<ProcessEvent>
      private let continuation: AsyncStream<ProcessEvent>.Continuation

      init() {
        (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
      }

      func send(_ line: String) {
        guard !isFinished.withLock({ $0 }) else { return }
        continuation.yield(.output(line))
      }

      func finish(code: Int32) {
        let wasOpen = isFinished.withLock { finished in
          defer { finished = true }
          return !finished
        }
        guard wasOpen else { return }
        continuation.yield(.exited(code: code))
        continuation.finish()
      }
    }

    private struct State {
      var config = Config()
      var processes: [Process] = []
      var usageSamples = 0
    }

    private let state = Mutex(State())

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

    func preflight() async -> ToolchainStatus {
      state.withLock { $0.config.toolchain }
    }

    func listDefault() async throws(ColimaCLIError) -> VMObservation {
      if Task.isCancelled { throw .cancelled }
      return try state.withLock { $0.config.observation }.get()
    }

    func run(_ command: VMCommand) async -> VMCommandRun {
      let process = Process()
      let script = state.withLock { state -> PreviewRunScript in
        state.processes.append(process)
        return state.config.runs.isEmpty ? .hang : state.config.runs.removeFirst()
      }
      if case .exits(let code, let lines) = script {
        lines.forEach(process.send)
        process.finish(code: code)
      }
      return VMCommandRun(
        events: process.events,
        terminate: {
          process.finish(code: 143)
          return true
        })
    }

    /// Each call advances the counters, so consecutive samples differ the way a busy VM's do; a constant answer
    /// would make every difference zero and every sample a gap.
    func sampleUsage() async throws(ColimaCLIError) -> ProcSnapshot {
      if Task.isCancelled { throw .cancelled }
      let (failure, index) = state.withLock { state -> (ColimaCLIError?, Int) in
        defer { state.usageSamples += 1 }
        return (state.config.usageFailure, state.usageSamples)
      }
      if let failure { throw failure }
      return Self.snapshot(index: index)
    }

    private static func snapshot(index: Int) -> ProcSnapshot {
      let busyPerRound = [20, 35, 50, 30, 45, 25]
      let busy = (0...index).reduce(0) { $0 + busyPerRound[$1 % busyPerRound.count] }
      let idle = (index + 1) * 100 - busy
      let availableKiB = 2_400_000 - (index % 8) * 20_000
      let text = """
        cpu  \(busy) 0 0 \(idle) 0 0 0 0 0 0
        MemTotal:        4000000 kB
        MemAvailable:    \(availableKiB) kB
        """
      do {
        return try ProcSnapshot.parse(text)
      } catch {
        preconditionFailure("the preview /proc text is malformed: \(error)")
      }
    }
  }
#endif
