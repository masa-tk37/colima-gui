import Foundation
import Synchronization

enum OutputChannel: Sendable, Equatable {
  case stdout
  case stderr
}

enum StopReason: Sendable, Equatable {
  case timedOut
  case cancelled
}

struct ChildExit: Sendable, Equatable {
  /// `128 + signal` for a child killed by a signal, matching the shell convention.
  let code: Int32
  let stopReason: StopReason?
}

enum ChildEvent: Sendable {
  case output(OutputChannel, Data)
  /// Always the last event. Delivered once the process has exited and both pipes reached EOF,
  /// or `pipeEOFGrace` after the exit, whichever comes first.
  case finished(ChildExit)
}

/// Consumers must iterate `events` from a task that is not cancelled with the caller:
/// an `AsyncStream` iterator ends early on cancellation, which would drop the final event.
final class ChildProcess: @unchecked Sendable {
  let events: AsyncStream<ChildEvent>

  private struct State {
    var launched = false
    var stopReason: StopReason?
    var exitCode: Int32?
    var openPipes = 2
    var finished = false
    var killTask: Task<Void, Never>?
    var graceTask: Task<Void, Never>?
  }

  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let state = Mutex(State())
  private let continuation: AsyncStream<ChildEvent>.Continuation
  private let pipeEOFGrace: Duration
  private let killGrace: Duration
  private let readers = Mutex<[PipeReader]>([])

  init(invocation: ProcessInvocation, pipeEOFGrace: Duration, killGrace: Duration) {
    (events, continuation) = AsyncStream.makeStream(of: ChildEvent.self)
    self.pipeEOFGrace = pipeEOFGrace
    self.killGrace = killGrace

    process.executableURL = URL(fileURLWithPath: invocation.executable)
    process.arguments = invocation.arguments
    process.environment = invocation.environment
    process.currentDirectoryURL = URL(
      fileURLWithPath: invocation.workingDirectory, isDirectory: true)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] process in
      self?.processExited(process)
    }
  }

  func launch() throws {
    try process.run()
    state.withLock { $0.launched = true }
    let stdoutReader = makeReader(stdoutPipe, channel: .stdout)
    let stderrReader = makeReader(stderrPipe, channel: .stderr)
    readers.withLock { $0 = [stdoutReader, stderrReader] }
  }

  @discardableResult
  func stop(_ reason: StopReason) -> Bool {
    let shouldSignal = state.withLock { state -> Bool in
      guard state.launched, state.exitCode == nil else { return false }
      if state.stopReason == nil { state.stopReason = reason }
      return true
    }
    guard shouldSignal else { return false }

    process.terminate()
    let killGrace = killGrace
    let task = Task { [weak self] in
      try? await Task.sleep(for: killGrace)
      guard !Task.isCancelled else { return }
      self?.killIfStillRunning()
    }
    state.withLock { $0.killTask = task }
    return true
  }

  private func makeReader(_ pipe: Pipe, channel: OutputChannel) -> PipeReader {
    PipeReader(
      readEnd: pipe.fileHandleForReading,
      queue: DispatchQueue(label: "cc.tk37.ColimaGUI.pipe.\(channel)"),
      onData: { [continuation] data in continuation.yield(.output(channel, data)) },
      onEnd: { [weak self] in self?.pipeReachedEOF() }
    )
  }

  private func killIfStillRunning() {
    let running = state.withLock { $0.exitCode == nil }
    if running, process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }

  private func processExited(_ process: Process) {
    let code =
      process.terminationReason == .uncaughtSignal
      ? 128 + process.terminationStatus
      : process.terminationStatus
    let grace = pipeEOFGrace
    let task = Task { [weak self] in
      try? await Task.sleep(for: grace)
      guard !Task.isCancelled else { return }
      self?.finishIfNeeded(force: true)
    }
    state.withLock {
      $0.exitCode = code
      $0.graceTask = task
    }
    finishIfNeeded(force: false)
  }

  private func pipeReachedEOF() {
    state.withLock { $0.openPipes -= 1 }
    finishIfNeeded(force: false)
  }

  private func finishIfNeeded(force: Bool) {
    let result = state.withLock { state -> (ChildExit, [Task<Void, Never>])? in
      guard !state.finished, let code = state.exitCode, force || state.openPipes == 0 else {
        return nil
      }
      state.finished = true
      let tasks = [state.killTask, state.graceTask].compactMap { $0 }
      return (ChildExit(code: code, stopReason: state.stopReason), tasks)
    }
    guard let (exit, tasks) = result else { return }

    for task in tasks { task.cancel() }
    for reader in readers.withLock({ $0 }) { reader.cancel() }
    continuation.yield(.finished(exit))
    continuation.finish()
  }
}
