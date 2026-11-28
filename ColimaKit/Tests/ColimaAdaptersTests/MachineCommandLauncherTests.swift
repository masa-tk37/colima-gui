import ColimaCore
import Foundation
import Testing

@testable import ColimaProcess

private struct FakeLima {
  let root: URL
  let invocation: LimaInvocation

  var home: String { root.appendingPathComponent("home").path }
  var instanceDirectory: String { home + "/.lima/cg-dev" }
  var callsPath: String { root.appendingPathComponent("calls.log").path }

  init(create: String, delete: String = "echo deleted; rm -rf \"$LIMA_HOME/cg-dev\"", other: String = "exit 0") throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MachineCommandLauncherTests-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin")
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    self.root = root
    invocation = LimaInvocation(homebrewDirectory: bin.path, homeDirectory: home.path)

    let script = """
      #!/bin/sh
      echo "$*" >> "\(root.path)/calls.log"
      case "$1" in
      create)
      \(create)
        ;;
      delete)
      \(delete)
        ;;
      *)
      \(other)
        ;;
      esac
      """
    let path = bin.appendingPathComponent("limactl").path
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  func launcher() -> LocalMachineCommandLauncher {
    LocalMachineCommandLauncher(invocation: invocation, runner: ProcessRunner(killGrace: .seconds(5)))
  }

  func calls() -> [String] {
    ((try? String(contentsOfFile: callsPath, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func directoryExists() -> Bool {
    FileManager.default.fileExists(atPath: instanceDirectory)
  }

  func makeInstanceDirectory() throws {
    try FileManager.default.createDirectory(atPath: instanceDirectory, withIntermediateDirectories: true)
  }

  func exists(_ marker: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path)
  }

  func waitFor(_ marker: String, timeout: Duration = .seconds(20)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if exists(marker) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(marker)")
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func decode(_ json: String) throws -> MachineCommand {
  try JSONDecoder().decode(MachineCommand.self, from: Data(json.utf8))
}

private let createCommand =
  #"{"kind":"create","name":"dev","template":"ubuntu-24.04","cpus":2,"memoryGiB":4,"diskGiB":100,"mounts":[]}"#

private func lines(_ events: [ProcessEvent]) -> [String] {
  events.compactMap { if case .output(let line) = $0 { line } else { nil } }
}

private func exitCode(_ events: [ProcessEvent]) -> Int32? {
  if case .exited(let code) = events.last { code } else { nil }
}

struct MachineCommandLauncherTests {
  @Test func aCommandRunsAsAChildAndReturnsItsOutputAndExit() async throws {
    let lima = try FakeLima(create: "exit 0", other: "echo hello; echo oops >&2; exit 4")
    defer { lima.remove() }

    let run = await lima.launcher().run(try decode(#"{"kind":"start","name":"dev"}"#))
    let events = await collectEvents(run)

    #expect(Set(lines(events)) == ["hello", "oops"])
    #expect(exitCode(events) == 4)
    #expect(lima.calls() == ["start --tty=false cg-dev"])
  }

  @Test func theChildGetsTheFakeLimaHomeAndRunsFromTheWorkingDirectory() async throws {
    let lima = try FakeLima(create: "exit 0", other: "echo \"$LIMA_HOME\"; pwd -P")
    defer { lima.remove() }

    let events = await collectEvents(await lima.launcher().run(try decode(#"{"kind":"stop","name":"dev"}"#)))

    let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    #expect(lines(events).first == lima.invocation.limaHome)
    #expect(lines(events).last.map(real) == real(lima.invocation.workingDirectory))
  }

  @Test func aSuccessfulCreateIsNotCleanedUp() async throws {
    let lima = try FakeLima(create: "mkdir -p \"$LIMA_HOME/cg-dev\"; echo made")
    defer { lima.remove() }

    let events = await collectEvents(await lima.launcher().run(try decode(createCommand)))

    #expect(lines(events) == ["made"])
    #expect(exitCode(events) == 0)
    #expect(lima.directoryExists())
    #expect(lima.calls().count == 1)
  }

  @Test func aFailedCreateDeletesTheNewDirectoryBeforeTheExitAndKeepsTheCreateCode() async throws {
    let lima = try FakeLima(create: "mkdir -p \"$LIMA_HOME/cg-dev\"; echo boom >&2; exit 3")
    defer { lima.remove() }

    let run = await lima.launcher().run(try decode(createCommand))
    var seen: [ProcessEvent] = []
    var directoryAtExit: Bool?
    for await event in run.events {
      seen.append(event)
      if case .exited = event { directoryAtExit = lima.directoryExists() }
    }

    #expect(lines(seen) == ["boom", "deleted"])
    #expect(exitCode(seen) == 3)
    #expect(directoryAtExit == false)
    #expect(lima.calls().last == "delete --tty=false --force cg-dev")
    #expect(lima.calls().count == 2)
  }

  @Test func aFailedCreateThatLeftNoDirectoryRunsNoCleanup() async throws {
    let lima = try FakeLima(create: "echo rejected >&2; exit 1")
    defer { lima.remove() }

    let events = await collectEvents(await lima.launcher().run(try decode(createCommand)))

    #expect(exitCode(events) == 1)
    #expect(lima.calls().count == 1)
  }

  @Test func aDirectoryThatExistedBeforeTheCreateIsNeverDeleted() async throws {
    let lima = try FakeLima(create: "echo exists >&2; exit 1")
    defer { lima.remove() }
    try lima.makeInstanceDirectory()

    let events = await collectEvents(await lima.launcher().run(try decode(createCommand)))

    #expect(exitCode(events) == 1)
    #expect(lima.directoryExists())
    #expect(lima.calls().count == 1)
  }

  @Test func aFailedCleanupKeepsItsOutputAndTheCreateCode() async throws {
    let lima = try FakeLima(
      create: "mkdir -p \"$LIMA_HOME/cg-dev\"; exit 5", delete: "echo cannot-delete >&2; exit 1")
    defer { lima.remove() }

    let events = await collectEvents(await lima.launcher().run(try decode(createCommand)))

    #expect(lines(events) == ["cannot-delete"])
    #expect(exitCode(events) == 5)
    #expect(lima.directoryExists())
  }

  @Test func otherCommandsAreNeverCleanedUpAfterAFailure() async throws {
    let lima = try FakeLima(create: "exit 0", other: "mkdir -p \"$LIMA_HOME/cg-dev\"; exit 1")
    defer { lima.remove() }

    let events = await collectEvents(await lima.launcher().run(try decode(#"{"kind":"start","name":"dev"}"#)))

    #expect(exitCode(events) == 1)
    #expect(lima.directoryExists())
    #expect(lima.calls().count == 1)
  }

  @Test func terminatingARunningCreateCleansUpAndExitsNonZero() async throws {
    let lima = try FakeLima(create: "mkdir -p \"$LIMA_HOME/cg-dev\"; : > \"$LIMA_HOME/../../ready\"; exec sleep 60")
    defer { lima.remove() }

    let run = await lima.launcher().run(try decode(createCommand))
    try await lima.waitFor("ready")

    #expect(await run.terminate())
    let events = await collectEvents(run)

    #expect((exitCode(events) ?? 0) != 0)
    #expect(!lima.directoryExists())
    #expect(lima.calls().last == "delete --tty=false --force cg-dev")
  }

  @Test func terminateIsRefusedDuringTheCleanupAndTheCleanupFinishes() async throws {
    let lima = try FakeLima(
      create: "mkdir -p \"$LIMA_HOME/cg-dev\"; exit 7",
      delete: ": > \"$LIMA_HOME/../../deleting\"; sleep 1; rm -rf \"$LIMA_HOME/cg-dev\"; echo deleted")
    defer { lima.remove() }

    let run = await lima.launcher().run(try decode(createCommand))
    try await lima.waitFor("deleting")

    #expect(await run.terminate() == false)
    let events = await collectEvents(run)

    #expect(lines(events) == ["deleted"])
    #expect(exitCode(events) == 7)
    #expect(!lima.directoryExists())
  }

  @Test func terminateAfterTheExitReturnsFalse() async throws {
    let lima = try FakeLima(create: "exit 0")
    defer { lima.remove() }

    let run = await lima.launcher().run(try decode(createCommand))
    _ = await collectEvents(run)

    #expect(await run.terminate() == false)
  }

  @Test func aMissingLimactlEndsInLaunchFailedWithNoCleanup() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MachineCommandLauncherTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = LocalMachineCommandLauncher(
      invocation: LimaInvocation(
        homebrewDirectory: root.path + "/missing", homeDirectory: root.path + "/home"))

    let run = await launcher.run(try decode(createCommand))
    let events = await collectEvents(run)

    guard case .launchFailed = events.last else {
      Issue.record("expected launchFailed, got \(events)")
      return
    }
    #expect(await run.terminate() == false)
  }
}
