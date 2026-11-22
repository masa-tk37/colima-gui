import Foundation

@testable import ColimaAdapters
@testable import ColimaProcess

struct FakeBin {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FakeBin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var colimaPath: String { directory.appendingPathComponent("colima").path }

  func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

  func install(_ name: String, script: String = "#!/bin/sh\nexit 0\n") throws {
    let url = directory.appendingPathComponent(name)
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func installColima(_ body: String) throws {
    try install("colima", script: "#!/bin/sh\n\(body)\n")
  }

  private var invocation: ColimaInvocation {
    ColimaInvocation(homebrewDirectory: directory.path, homeDirectory: directory.path)
  }

  private var runner: ProcessRunner {
    ProcessRunner(pipeEOFGrace: .milliseconds(500), killGrace: .seconds(2))
  }

  var launcher: LocalVMCommandLauncher {
    LocalVMCommandLauncher(invocation: invocation, runner: runner)
  }

  func commandLine(usageTimeout: Duration = .seconds(2)) -> ColimaCommandLine {
    ColimaCommandLine(
      invocation: invocation, runner: runner, vmCommands: launcher, usageTimeout: usageTimeout)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
