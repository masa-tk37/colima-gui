import ColimaCore
import Foundation
import Synchronization

package protocol MachineCommandLauncher: Sendable {
  func run(_ command: MachineCommand) async -> VMCommandRun
}

package struct LocalMachineCommandLauncher: MachineCommandLauncher {
  private let invocation: LimaInvocation
  private let runner: ProcessRunner

  package init(invocation: LimaInvocation = LimaInvocation(), runner: ProcessRunner = ProcessRunner()) {
    self.invocation = invocation
    self.runner = runner
  }

  package func run(_ command: MachineCommand) async -> VMCommandRun {
    // A failure here surfaces as the child's launch failure: the working directory is the child's cwd.
    try? invocation.prepareWorkingDirectory()
    guard case .create = command else {
      return await runner.run(invocation.make(command.arguments, timeout: nil))
    }
    return await runCreate(command)
  }

  /// A create that exits non-zero (failure or cancel) can leave a half-made instance, so the new directory is
  /// removed with `delete --force` before the exit event is delivered.
  private func runCreate(_ command: MachineCommand) async -> VMCommandRun {
    let directoryExistedBefore = FileManager.default.fileExists(
      atPath: invocation.instanceDirectory(for: command.name))
    let create = await runner.run(invocation.make(command.arguments, timeout: nil))
    let createIsRunning = Mutex(true)
    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)

    Task {
      for await event in create.events {
        switch event {
        case .exited(let code):
          createIsRunning.withLock { $0 = false }
          if code != 0, !directoryExistedBefore,
            FileManager.default.fileExists(atPath: invocation.instanceDirectory(for: command.name))
          {
            await cleanUp(command.name, into: continuation)
          }
        case .launchFailed:
          createIsRunning.withLock { $0 = false }
        default:
          break
        }
        continuation.yield(event)
      }
      continuation.finish()
    }

    return VMCommandRun(
      events: events,
      terminate: {
        guard createIsRunning.withLock({ $0 }) else { return false }
        return await create.terminate()
      })
  }

  private func cleanUp(_ name: MachineName, into continuation: AsyncStream<ProcessEvent>.Continuation) async {
    let arguments = MachineCommand.delete(name).arguments
    let cleanup = await runner.run(invocation.make(arguments, timeout: nil))
    for await event in cleanup.events {
      switch event {
      case .output: continuation.yield(event)
      case .launchFailed(let reason): continuation.yield(.output(reason))
      case .exited: break
      }
    }
  }
}
