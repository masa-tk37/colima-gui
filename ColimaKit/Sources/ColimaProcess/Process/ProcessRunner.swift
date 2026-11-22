import ColimaCore
import Foundation

package struct ProcessInvocation: Sendable {
  package let executable: String
  package let arguments: [String]
  package let environment: [String: String]
  package let workingDirectory: String
  package let timeout: Duration?

  package init(
    executable: String, arguments: [String], environment: [String: String],
    workingDirectory: String, timeout: Duration?
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.timeout = timeout
  }
}

package enum ProcessTermination: Sendable, Equatable {
  case exited(code: Int32)
  case timedOut
  case cancelled
  case launchFailed(reason: String)
}

package struct CollectedRun: Sendable {
  package let stdout: [UInt8]
  package let stderr: [UInt8]
  package let termination: ProcessTermination

  package init(stdout: [UInt8], stderr: [UInt8], termination: ProcessTermination) {
    self.stdout = stdout
    self.stderr = stderr
    self.termination = termination
  }

  package var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  package var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

package actor ProcessRunner {
  private let pipeEOFGrace: Duration
  private let killGrace: Duration

  /// `pipeEOFGrace` bounds how long a grandchild holding the pipes can delay the result after the child exits.
  package init(pipeEOFGrace: Duration = .seconds(5), killGrace: Duration = .seconds(10)) {
    self.pipeEOFGrace = pipeEOFGrace
    self.killGrace = killGrace
  }

  package func runCollecting(_ invocation: ProcessInvocation) async -> CollectedRun {
    if Task.isCancelled {
      return CollectedRun(stdout: [], stderr: [], termination: .cancelled)
    }

    let child: ChildProcess
    switch launch(invocation) {
    case .success(let launched): child = launched
    case .failure(let reason):
      return CollectedRun(
        stdout: [], stderr: [], termination: .launchFailed(reason: reason.message))
    }

    let timer = invocation.timeout.map { timeout in
      Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        child.stop(.timedOut)
      }
    }
    defer { timer?.cancel() }

    let collector = Task { await Self.collect(child.events) }
    let run = await withTaskCancellationHandler {
      await collector.value
    } onCancel: {
      child.stop(.cancelled)
    }

    ColimaLog.process.debug(
      "finished \(invocation.executable, privacy: .public): \(String(describing: run.termination), privacy: .public)"
    )
    return run
  }

  /// Neither the calling task nor the consumer of `events` owns the child: only `terminate` ends it.
  /// Cancelling the consumer drops the remaining events, and the child keeps running.
  package func run(_ invocation: ProcessInvocation) -> VMCommandRun {
    let child: ChildProcess
    switch launch(invocation) {
    case .success(let launched):
      child = launched
    case .failure(let reason):
      let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
      continuation.yield(.launchFailed(reason: reason.message))
      continuation.finish()
      return VMCommandRun(events: events, terminate: { false })
    }

    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    Task { await Self.pump(child.events, into: continuation, executable: invocation.executable) }
    return VMCommandRun(
      events: events,
      terminate: {
        ColimaLog.process.debug(
          "terminate requested for \(invocation.executable, privacy: .public)")
        return child.stop(.cancelled)
      })
  }

  private struct LaunchFailure: Error {
    let message: String
  }

  private func launch(_ invocation: ProcessInvocation) -> Result<ChildProcess, LaunchFailure> {
    let child = ChildProcess(
      invocation: invocation, pipeEOFGrace: pipeEOFGrace, killGrace: killGrace)
    do {
      try child.launch()
    } catch {
      ColimaLog.process.error(
        "launch failed: \(invocation.executable, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return .failure(LaunchFailure(message: error.localizedDescription))
    }
    ColimaLog.process.debug(
      "launched \(invocation.executable, privacy: .public) with \(invocation.arguments.count) arguments"
    )
    return .success(child)
  }

  private static func pump(
    _ events: AsyncStream<ChildEvent>,
    into continuation: AsyncStream<ProcessEvent>.Continuation,
    executable: String
  ) async {
    var stdout = LineAssembler()
    var stderr = LineAssembler()

    for await event in events {
      switch event {
      case .output(.stdout, let data):
        for line in stdout.append(data) { continuation.yield(.output(line)) }
      case .output(.stderr, let data):
        for line in stderr.append(data) { continuation.yield(.output(line)) }
      case .finished(let exit):
        if let tail = stdout.finish() { continuation.yield(.output(tail)) }
        if let tail = stderr.finish() { continuation.yield(.output(tail)) }
        ColimaLog.process.debug("exited \(executable, privacy: .public) with code \(exit.code)")
        continuation.yield(.exited(code: exit.code))
      }
    }
    continuation.finish()
  }

  private static func collect(_ events: AsyncStream<ChildEvent>) async -> CollectedRun {
    var stdout = [UInt8]()
    var stderr = [UInt8]()
    var termination = ProcessTermination.launchFailed(
      reason: "the child ended without a termination status")

    for await event in events {
      switch event {
      case .output(.stdout, let data):
        stdout.append(contentsOf: data)
      case .output(.stderr, let data):
        stderr.append(contentsOf: data)
      case .finished(let exit):
        switch exit.stopReason {
        case .timedOut: termination = .timedOut
        case .cancelled: termination = .cancelled
        case nil: termination = .exited(code: exit.code)
        }
      }
    }
    return CollectedRun(stdout: stdout, stderr: stderr, termination: termination)
  }
}
