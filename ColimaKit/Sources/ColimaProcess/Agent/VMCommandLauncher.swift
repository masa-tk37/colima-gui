import ColimaCore

package protocol VMCommandLauncher: Sendable {
  func run(_ command: VMCommand) async -> VMCommandRun
}

package struct LocalVMCommandLauncher: VMCommandLauncher {
  private let invocation: ColimaInvocation
  private let runner: ProcessRunner

  package init(
    invocation: ColimaInvocation = ColimaInvocation(), runner: ProcessRunner = ProcessRunner()
  ) {
    self.invocation = invocation
    self.runner = runner
  }

  package func run(_ command: VMCommand) async -> VMCommandRun {
    await runner.run(invocation.make(command.arguments, timeout: nil))
  }
}
