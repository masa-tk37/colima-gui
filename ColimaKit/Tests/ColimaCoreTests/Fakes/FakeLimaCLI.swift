import Foundation
import Testing
import Synchronization

@testable import ColimaCore

final class FakeMachineProcess: Sendable {
  let command: MachineCommand

  private struct State {
    var isFinished = false
    var terminateCount = 0
  }

  private let state = Mutex(State())
  private let continuation: AsyncStream<ProcessEvent>.Continuation
  private let exitCodeOnTerminate: Int32
  private let acceptsTerminate: Bool
  private let endsOnTerminate: Bool
  let events: AsyncStream<ProcessEvent>

  init(
    command: MachineCommand, exitCodeOnTerminate: Int32, acceptsTerminate: Bool, endsOnTerminate: Bool = true
  ) {
    self.command = command
    self.exitCodeOnTerminate = exitCodeOnTerminate
    self.acceptsTerminate = acceptsTerminate
    self.endsOnTerminate = endsOnTerminate
    (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
  }

  static var placeholder: FakeMachineProcess {
    let name = try! MachineName.parse("timed-out", limaHomeUTF8Count: 0).get()
    return FakeMachineProcess(command: .start(name), exitCodeOnTerminate: 0, acceptsTerminate: false)
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

  /// A stream that closes with neither `.exited` nor `.launchFailed`, which a real runner never does.
  func endWithoutExit() {
    let wasOpen = state.withLock { state in
      defer { state.isFinished = true }
      return !state.isFinished
    }
    if wasOpen { continuation.finish() }
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
    guard endsOnTerminate else { return !isFinished }
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

final class FakeLimaCLI: LimaCLI {
  enum Call: Equatable {
    case preflight
    case listInstances
    case listTemplates
    case run(MachineCommand)
    case activeOperations
    case terminateEarlierRun(UUID)
  }

  struct Config: Sendable {
    var limaHomeUTF8Count = 21
    var toolchain = LimaToolchain.found(path: "/opt/homebrew/bin/limactl")
    /// `listInstances`, `activeOperations` and `terminateEarlierRun` are each consumed one entry per call; the last entry repeats.
    var listInstances: [Result<LimaListing, LimaCLIError>] = [
      .success(LimaListing(machines: [], unownedMachineKeys: []))
    ]
    var listTemplates: [Result<[MachineTemplate], LimaCLIError>] = [.success([])]
    var activeOperations: [[ActiveMachineOperation]?] = [nil]
    var terminateEarlierRun: [Bool] = [true]
    var scriptedRuns: [[ProcessEvent]] = []
    var exitCodeOnTerminate: Int32 = 143
    var acceptsTerminate = true
    /// False leaves the child running after an accepted `terminate`; the test ends it with `exit(code:)`.
    var terminateEndsProcess = true
    var beforeTerminateReturns: (@Sendable () async -> Void)?
    var beforePreflightReturns: (@Sendable () async -> Void)?
    var beforeListInstancesReturns: (@Sendable () async -> Void)?
    var beforeListTemplatesReturns: (@Sendable () async -> Void)?
    var beforeActiveOperationsReturns: (@Sendable () async -> Void)?
  }

  private struct State {
    var config = Config()
    var calls: [Call] = []
    var processes: [FakeMachineProcess] = []
    var listInstancesCount = 0
    var listTemplatesCount = 0
    var activeOperationsCount = 0
    var terminateEarlierRunCount = 0
    var nextWaiterID = 0
    var waiters: [(id: Int, index: Int, continuation: CheckedContinuation<FakeMachineProcess, Never>)] = []
  }

  private let state = Mutex(State())

  func configure(_ body: (inout Config) -> Void) {
    state.withLock { body(&$0.config) }
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var processes: [FakeMachineProcess] { state.withLock { $0.processes } }
  var limaHomeUTF8Count: Int { state.withLock { $0.config.limaHomeUTF8Count } }

  /// A run that never arrives records an issue after `timeout` and returns a placeholder, so a broken expectation fails the test instead of hanging it.
  func process(at index: Int, timeout: Duration = .seconds(15)) async -> FakeMachineProcess {
    await withCheckedContinuation { continuation in
      let (existing, waiterID) = state.withLock { state -> (FakeMachineProcess?, Int) in
        if index < state.processes.count { return (state.processes[index], -1) }
        let id = state.nextWaiterID
        state.nextWaiterID += 1
        state.waiters.append((id, index, continuation))
        return (nil, id)
      }
      if let existing {
        continuation.resume(returning: existing)
        return
      }
      Task {
        try? await Task.sleep(for: timeout)
        let expired = state.withLock { state -> Bool in
          guard let position = state.waiters.firstIndex(where: { $0.id == waiterID }) else { return false }
          state.waiters.remove(at: position)
          return true
        }
        guard expired else { return }
        Issue.record("no limactl run at index \(index) arrived within \(timeout)")
        continuation.resume(returning: FakeMachineProcess.placeholder)
      }
    }
  }

  func preflight() async -> LimaToolchain {
    let (toolchain, hook) = state.withLock { state in
      state.calls.append(.preflight)
      return (state.config.toolchain, state.config.beforePreflightReturns)
    }
    await hook?()
    return toolchain
  }

  func listInstances() async throws(LimaCLIError) -> LimaListing {
    let (result, hook) = state.withLock { state in
      state.calls.append(.listInstances)
      let results = state.config.listInstances
      defer { state.listInstancesCount += 1 }
      return (
        results[min(state.listInstancesCount, results.count - 1)],
        state.config.beforeListInstancesReturns
      )
    }
    await hook?()
    if Task.isCancelled { throw .cancelled }
    return try result.get()
  }

  func listTemplates() async throws(LimaCLIError) -> [MachineTemplate] {
    let (result, hook) = state.withLock { state in
      state.calls.append(.listTemplates)
      let results = state.config.listTemplates
      defer { state.listTemplatesCount += 1 }
      return (
        results[min(state.listTemplatesCount, results.count - 1)],
        state.config.beforeListTemplatesReturns
      )
    }
    await hook?()
    if Task.isCancelled { throw .cancelled }
    return try result.get()
  }

  func run(_ command: MachineCommand) async -> VMCommandRun {
    let (process, script, ready) = state.withLock { state in
      state.calls.append(.run(command))
      let process = FakeMachineProcess(
        command: command, exitCodeOnTerminate: state.config.exitCodeOnTerminate,
        acceptsTerminate: state.config.acceptsTerminate, endsOnTerminate: state.config.terminateEndsProcess)
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
    return VMCommandRun(
      events: process.events,
      terminate: { [self] in
        let accepted = process.terminate()
        await state.withLock { $0.config.beforeTerminateReturns }?()
        return accepted
      })
  }

  func activeOperations() async -> [ActiveMachineOperation]? {
    let (result, hook) = state.withLock { state in
      state.calls.append(.activeOperations)
      let results = state.config.activeOperations
      defer { state.activeOperationsCount += 1 }
      return (
        results[min(state.activeOperationsCount, results.count - 1)],
        state.config.beforeActiveOperationsReturns
      )
    }
    await hook?()
    return result
  }

  func terminateEarlierRun(runID: UUID) async -> Bool {
    let (accepted, hook) = state.withLock { state in
      state.calls.append(.terminateEarlierRun(runID))
      let results = state.config.terminateEarlierRun
      defer { state.terminateEarlierRunCount += 1 }
      return (results[min(state.terminateEarlierRunCount, results.count - 1)], state.config.beforeTerminateReturns)
    }
    await hook?()
    return accepted
  }
}
