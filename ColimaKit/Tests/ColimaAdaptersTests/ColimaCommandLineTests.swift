import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

private func fixture(_ name: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  return try String(contentsOf: url, encoding: .utf8)
}

private func collected(
  stdout: String = "",
  stderr: String = "",
  _ termination: ProcessTermination
) -> CollectedRun {
  CollectedRun(stdout: Array(stdout.utf8), stderr: Array(stderr.utf8), termination: termination)
}

private func lines(_ count: Int, prefix: String = "line") -> String {
  (1...count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
}

private func createSpec(type: VMType = .vz) throws -> VMCreateSpec {
  let input = SettingsFormInput(cpus: "4", memoryGiB: "8", diskGiB: "100", vmType: type)
  return try VMSettingsValidator.validate(input, diskFloorGiB: nil).get()
}

@Suite("CollectedRun から ColimaCLIError への変換")
struct CollectedRunMappingTests {
  @Test func zeroExitReturnsStdout() throws {
    let run = collected(stdout: "payload\n", stderr: "warning\n", .exited(code: 0))
    #expect(try run.successfulStdout() == Array("payload\n".utf8))
  }

  @Test func nonZeroExitKeepsLastFiftyStderrLines() {
    let run = collected(
      stdout: lines(80, prefix: "out"), stderr: lines(60, prefix: "err"), .exited(code: 3))
    let expected = (11...60).map { "err \($0)" }
    #expect(throws: ColimaCLIError.nonZeroExit(code: 3, output: expected)) {
      try run.successfulStdout()
    }
  }

  @Test func nonZeroExitFallsBackToLastFiftyStdoutLinesWhenStderrIsEmpty() {
    let run = collected(stdout: lines(55, prefix: "out"), .exited(code: 1))
    let expected = (6...55).map { "out \($0)" }
    #expect(throws: ColimaCLIError.nonZeroExit(code: 1, output: expected)) {
      try run.successfulStdout()
    }
  }

  @Test func nonZeroExitWithNoOutputHasEmptyLines() {
    #expect(throws: ColimaCLIError.nonZeroExit(code: 2, output: [])) {
      try collected(.exited(code: 2)).successfulStdout()
    }
  }

  @Test func shortStderrIsKeptWhole() {
    let run = collected(stdout: "ignored\n", stderr: "first\r\nsecond", .exited(code: 4))
    #expect(throws: ColimaCLIError.nonZeroExit(code: 4, output: ["first", "second"])) {
      try run.successfulStdout()
    }
  }

  @Test func timedOutMapsToTimedOut() {
    #expect(throws: ColimaCLIError.timedOut) { try collected(.timedOut).successfulStdout() }
  }

  @Test func cancelledMapsToCancelled() {
    #expect(throws: ColimaCLIError.cancelled) { try collected(.cancelled).successfulStdout() }
  }

  @Test func launchFailedKeepsReason() {
    #expect(throws: ColimaCLIError.launchFailed(reason: "no such file")) {
      try collected(.launchFailed(reason: "no such file")).successfulStdout()
    }
  }
}

@Suite("ColimaCommandLine", .serialized)
struct ColimaCommandLineTests {
  @Test func preflightReportsOnlyTheHomebrewPathWhenColimaIsMissing() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }

    let status = await bin.commandLine().preflight()
    #expect(status.colima == .missing(searched: [bin.colimaPath]))
  }

  @Test func preflightFindsColimaAndLooksUpVMTypeExecutablesInTheSameDirectory() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("exit 0")
    try bin.install("qemu-img")

    let status = await bin.commandLine().preflight()
    #expect(status.colima == .found(path: bin.colimaPath))
    #expect(status.missingExecutables(for: .vz).isEmpty)
    #expect(status.missingExecutables(for: .qemu) == ["qemu-system-aarch64"])
    #expect(status.missingExecutables(for: .krunkit) == ["krunkit"])
  }

  @Test func preflightTreatsANonExecutableFileAsMissing() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("exit 0")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bin.colimaPath)

    let status = await bin.commandLine().preflight()
    #expect(status.colima == .missing(searched: [bin.colimaPath]))
  }

  @Test func listDefaultRunsListJSONWithoutOtherArguments() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    let json = try fixture("colima-list-running.json")
    try bin.installColima(
      """
      if [ "$*" != "list --json" ]; then echo "unexpected: $*" >&2; exit 9; fi
      cat <<'JSON'
      \(json)
      JSON
      """)

    let observation = try await bin.commandLine().listDefault()
    #expect(
      observation
        == .present(
          VMInstance(
            runState: .running, arch: "aarch64", cpus: 10,
            memoryBytes: 8_589_934_592, diskBytes: 107_374_182_400, runtime: "docker"
          )))
  }

  @Test func listDefaultWithEmptyOutputIsAbsent() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("exit 0")

    #expect(try await bin.commandLine().listDefault() == .absent)
  }

  @Test func listDefaultMapsUndecodableOutput() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("echo 'not json'")

    let error = await #expect(throws: ColimaCLIError.self) {
      try await bin.commandLine().listDefault()
    }
    guard case .undecodable = error else {
      Issue.record("expected undecodable, got \(String(describing: error))")
      return
    }
  }

  @Test func listDefaultMapsNonZeroExitWithStderrTail() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("echo out; echo boom >&2; exit 5")

    await #expect(throws: ColimaCLIError.nonZeroExit(code: 5, output: ["boom"])) {
      try await bin.commandLine().listDefault()
    }
  }

  @Test func listDefaultThrowsColimaMissingWhenTheExecutableIsAbsent() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }

    await #expect(throws: ColimaCLIError.colimaMissing) {
      try await bin.commandLine().listDefault()
    }
  }

  @Test func listDefaultMapsLaunchFailure() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.install("colima", script: "#!/nonexistent/interpreter\n")

    let error = await #expect(throws: ColimaCLIError.self) {
      try await bin.commandLine().listDefault()
    }
    guard case .launchFailed = error else {
      Issue.record("expected launchFailed, got \(String(describing: error))")
      return
    }
  }

  @Test func listDefaultCancellationThrowsCancelled() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("exec sleep 30")
    let commandLine = bin.commandLine()

    let task = Task { try await commandLine.listDefault() }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()

    await #expect(throws: ColimaCLIError.cancelled) { try await task.value }
  }

  @Test func sampleUsageRunsSSHCatAndParsesTheCombinedOutput() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    let proc = try fixture("proc-sample-1.txt")
    try bin.installColima(
      """
      if [ "$*" != "ssh -- cat /proc/stat /proc/meminfo" ]; then echo "unexpected: $*" >&2; exit 9; fi
      cat <<'PROC'
      \(proc)
      PROC
      """)

    let snapshot = try await bin.commandLine().sampleUsage()
    #expect(snapshot == (try ProcSnapshot.parse(proc)))
  }

  @Test func sampleUsageMapsUnparsableOutputToUndecodable() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("echo 'MemTotal: 1 kB'")

    let error = await #expect(throws: ColimaCLIError.self) {
      try await bin.commandLine().sampleUsage()
    }
    guard case .undecodable = error else {
      Issue.record("expected undecodable, got \(String(describing: error))")
      return
    }
  }

  @Test func sampleUsageTimesOutAndTerminatesTheChild() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("exec sleep 30")

    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: ColimaCLIError.timedOut) {
      try await bin.commandLine(usageTimeout: .milliseconds(300)).sampleUsage()
    }
    #expect(clock.now - start < .seconds(10))
  }

  @Test func runPassesTheVMCommandArgumentsAndStreamsOutput() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima(#"for a in "$@"; do echo "arg:$a"; done; echo oops >&2; exit 7"#)

    let spec = try createSpec(type: .krunkit)
    for command in [VMCommand.start, .stop, .delete, .create(spec)] {
      let events = await collectEvents(await bin.commandLine().run(command))
      let echoed = events.compactMap { event -> String? in
        if case .output(let line) = event, line.hasPrefix("arg:") {
          return String(line.dropFirst(4))
        }
        return nil
      }
      #expect(echoed == command.arguments)
      #expect(events.contains(.output("oops")))
      #expect(events.last == .exited(code: 7))
    }
  }

  @Test func runReportsLaunchFailureAsAnEvent() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }

    let events = await collectEvents(await bin.commandLine().run(.start))
    guard case .launchFailed = events.last else {
      Issue.record("expected launchFailed, got \(events)")
      return
    }
  }

  @Test func runTerminateEndsTheChild() async throws {
    let bin = try FakeBin()
    defer { bin.remove() }
    try bin.installColima("echo started; exec sleep 30")

    let run = await bin.commandLine().run(.start)
    var iterator = run.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started"))
    #expect(await run.terminate())
    var last: ProcessEvent?
    while let event = await iterator.next() { last = event }
    #expect(last == .exited(code: 143))
  }
}
