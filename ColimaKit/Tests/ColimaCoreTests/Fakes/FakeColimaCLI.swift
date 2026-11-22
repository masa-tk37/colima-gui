import Synchronization

@testable import ColimaCore

final class FakeProcess: Sendable {
  let command: VMCommand

  private struct State {
    var isFinished = false
    var terminateCount = 0
  }

  private let state = Mutex(State())
  private let continuation: AsyncStream<ProcessEvent>.Continuation
  private let exitCodeOnTerminate: Int32
  private let acceptsTerminate: Bool
  let events: AsyncStream<ProcessEvent>

  init(command: VMCommand, exitCodeOnTerminate: Int32, acceptsTerminate: Bool = true) {
    self.command = command
    self.exitCodeOnTerminate = exitCodeOnTerminate
    self.acceptsTerminate = acceptsTerminate
    (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
  }

  var terminateCount: Int { state.withLock { $0.terminateCount } }
  var isFinished: Bool { state.withLock { $0.isFinished } }

  func send(_ line: String) {
    let open = state.withLock { !$0.isFinished }
    if open { continuation.yield(.output(line)) }
  }

  func exit(code: Int32) {
    finish(with: .exited(code: code))
  }

  func failLaunch(reason: String) {
    finish(with: .launchFailed(reason: reason))
  }

  func play(_ events: [ProcessEvent]) {
    for event in events {
      switch event {
      case .output(let line): send(line)
      case .exited, .launchFailed: finish(with: event)
      }
    }
  }

  fileprivate func terminate() -> Bool {
    state.withLock { $0.terminateCount += 1 }
    guard acceptsTerminate else { return false }
    return finish(with: .exited(code: exitCodeOnTerminate))
  }

  @discardableResult
  private func finish(with event: ProcessEvent) -> Bool {
    let wasOpen = state.withLock { state in
      defer { state.isFinished = true }
      return !state.isFinished
    }
    guard wasOpen else { return false }
    continuation.yield(event)
    continuation.finish()
    return true
  }
}

final class FakeColimaCLI: ColimaCLI {
  enum Call: Equatable {
    case preflight
    case listDefault
    case run(VMCommand)
    case sampleUsage
  }

  struct Config: Sendable {
    var toolchain = ToolchainStatus(
      colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:])
    /// Consumed one per call; the last entry repeats.
    var listDefault: [Result<VMObservation, ColimaCLIError>] = [.success(.absent)]
    var sampleUsage: [Result<ProcSnapshot, ColimaCLIError>] = [
      .failure(.undecodable(detail: "FakeColimaCLI.sampleUsage is not configured"))
    ]
    var scriptedRuns: [[ProcessEvent]] = []
    var exitCodeOnTerminate: Int32 = 143
    var acceptsTerminate = true
    var beforeListDefaultReturns: (@Sendable () async -> Void)?
    var beforePreflightReturns: (@Sendable () async -> Void)?
    var beforeSampleUsageReturns: (@Sendable () async -> Void)?
    /// The real CLI returns a finished sample even when the caller was cancelled meanwhile.
    var sampleUsageHonorsCancellation = true
  }

  private struct State {
    var config = Config()
    var calls: [Call] = []
    var processes: [FakeProcess] = []
    var listDefaultCount = 0
    var sampleUsageCount = 0
    var waiters: [(index: Int, continuation: CheckedContinuation<FakeProcess, Never>)] = []
  }

  private let state = Mutex(State())

  func configure(_ body: (inout Config) -> Void) {
    state.withLock { body(&$0.config) }
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var processes: [FakeProcess] { state.withLock { $0.processes } }

  func process(at index: Int) async -> FakeProcess {
    await withCheckedContinuation { continuation in
      let existing = state.withLock { state -> FakeProcess? in
        if index < state.processes.count { return state.processes[index] }
        state.waiters.append((index, continuation))
        return nil
      }
      if let existing { continuation.resume(returning: existing) }
    }
  }

  func preflight() async -> ToolchainStatus {
    let (status, hook) = state.withLock { state in
      state.calls.append(.preflight)
      return (state.config.toolchain, state.config.beforePreflightReturns)
    }
    await hook?()
    return status
  }

  func listDefault() async throws(ColimaCLIError) -> VMObservation {
    let (result, hook) = state.withLock { state in
      state.calls.append(.listDefault)
      let results = state.config.listDefault
      defer { state.listDefaultCount += 1 }
      return (
        results[min(state.listDefaultCount, results.count - 1)],
        state.config.beforeListDefaultReturns
      )
    }
    await hook?()
    if Task.isCancelled { throw .cancelled }
    return try result.get()
  }

  func run(_ command: VMCommand) async -> VMCommandRun {
    let (process, script, ready) = state.withLock { state in
      state.calls.append(.run(command))
      let process = FakeProcess(
        command: command, exitCodeOnTerminate: state.config.exitCodeOnTerminate,
        acceptsTerminate: state.config.acceptsTerminate)
      state.processes.append(process)
      let script = state.config.scriptedRuns.isEmpty ? nil : state.config.scriptedRuns.removeFirst()
      let ready = state.waiters.filter { $0.index < state.processes.count }
      state.waiters.removeAll { $0.index < state.processes.count }
      return (process, script, ready)
    }
    if let script { process.play(script) }
    for waiter in ready {
      waiter.continuation.resume(returning: state.withLock { $0.processes[waiter.index] })
    }
    return VMCommandRun(events: process.events, terminate: { process.terminate() })
  }

  func sampleUsage() async throws(ColimaCLIError) -> ProcSnapshot {
    let (result, hook, honorsCancellation) = state.withLock { state in
      state.calls.append(.sampleUsage)
      let results = state.config.sampleUsage
      defer { state.sampleUsageCount += 1 }
      return (
        results[min(state.sampleUsageCount, results.count - 1)],
        state.config.beforeSampleUsageReturns,
        state.config.sampleUsageHonorsCancellation
      )
    }
    await hook?()
    if honorsCancellation, Task.isCancelled { throw .cancelled }
    return try result.get()
  }
}
