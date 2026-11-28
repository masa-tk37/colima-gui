import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

private func machine(_ name: String) throws -> MachineName {
  try MachineName.parse(name, limaHomeUTF8Count: 20).get()
}

private func lines(_ count: Int, prefix: String) -> String {
  (1...count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
}

private final class FakeMachineAgent: MachineAgent, Sendable {
  private struct Calls {
    var commands: [MachineCommand] = []
    var terminated: [UUID] = []
    var activeRunsAsked = 0
  }

  private let calls = Mutex(Calls())
  private let runs: [AgentRunSummary]?
  private let acceptsTermination: Bool
  private let events: [ProcessEvent]

  init(
    runs: [AgentRunSummary]? = [], acceptsTermination: Bool = true,
    events: [ProcessEvent] = [.output("hello"), .exited(code: 0)]
  ) {
    self.runs = runs
    self.acceptsTermination = acceptsTermination
    self.events = events
  }

  var commands: [MachineCommand] { calls.withLock { $0.commands } }
  var terminated: [UUID] { calls.withLock { $0.terminated } }
  var activeRunsAsked: Int { calls.withLock { $0.activeRunsAsked } }

  func run(_ command: MachineCommand) async -> VMCommandRun {
    calls.withLock { $0.commands.append(command) }
    let (stream, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    for event in events { continuation.yield(event) }
    continuation.finish()
    return VMCommandRun(events: stream, terminate: { true })
  }

  func activeRuns() async -> [AgentRunSummary]? {
    calls.withLock { $0.activeRunsAsked += 1 }
    return runs
  }

  func terminateEarlierRun(runID: UUID) async -> Bool {
    calls.withLock { $0.terminated.append(runID) }
    return acceptsTermination
  }
}

private struct FakeLimactl {
  let bin: FakeBin

  init() throws { bin = try FakeBin() }

  var home: String { bin.directory.path }
  var limactlPath: String { bin.path("limactl") }
  var log: URL { bin.directory.appendingPathComponent("invocation.log") }

  func install(_ body: String) throws {
    try bin.install("limactl", script: "#!/bin/sh\n\(body)\n")
  }

  func commandLine(
    agent: any MachineAgent = FakeMachineAgent(), readTimeout: Duration = .seconds(30)
  ) -> LimaCommandLine {
    LimaCommandLine(
      invocation: LimaInvocation(homebrewDirectory: bin.directory.path, homeDirectory: bin.directory.path),
      runner: ProcessRunner(pipeEOFGrace: .milliseconds(500), killGrace: .seconds(2)),
      agent: agent, readTimeout: readTimeout)
  }

  func remove() { bin.remove() }
}

private let ownedRow =
  #"{"name":"cg-dev","status":"Running","cpus":2,"memory":2147483648,"disk":10737418240,"config":{"env":{"COLIMAGUI_TEMPLATE":"ubuntu"}}}"#
private let usersRow = #"{"name":"mine","status":"Running","cpus":4}"#
private let unownedPrefixedRow = #"{"name":"CG-Theirs","status":"Stopped","config":{}}"#

@Suite("LimaCommandLine", .serialized)
struct LimaCommandLineTests {
  @Test func preflightReportsTheSearchedPathWhenLimactlIsMissing() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }

    #expect(await fake.commandLine().preflight() == .missing(searched: [fake.limactlPath]))
  }

  @Test func preflightFindsLimactl() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("exit 0")

    #expect(await fake.commandLine().preflight() == .found(path: fake.limactlPath))
  }

  @Test func preflightTreatsANonExecutableFileAsMissing() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("exit 0")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fake.limactlPath)

    #expect(await fake.commandLine().preflight() == .missing(searched: [fake.limactlPath]))
  }

  @Test func aHungReadFailsInsteadOfWaitingForever() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("sleep 30")
    let cli = fake.commandLine(readTimeout: .milliseconds(300))

    await #expect(throws: LimaCLIError.self) { _ = try await cli.listInstances() }
    do {
      _ = try await cli.listTemplates()
      Issue.record("a hung template read should throw")
    } catch {
      guard case .launchFailed = error else {
        Issue.record("expected launchFailed, got \(error)")
        return
      }
    }
  }

  @Test func limaHomeLengthIsThatOfTheResolvedHome() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    let invocation = LimaInvocation(homebrewDirectory: fake.home, homeDirectory: fake.home)

    #expect(fake.commandLine().limaHomeUTF8Count == invocation.limaHomeUTF8Count)
  }

  @Test func listInstancesRunsListJSONWithLimaHomeInTheWorkingDirectory() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install(
      """
      echo "$*" > '\(fake.log.path)'
      echo "LIMA_HOME=$LIMA_HOME" >> '\(fake.log.path)'
      echo "PWD=$(pwd -P)" >> '\(fake.log.path)'
      cat <<'ROWS'
      \(ownedRow)
      \(usersRow)
      \(unownedPrefixedRow)
      ROWS
      """)

    let listing = try await fake.commandLine().listInstances()

    let log = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
    let workingDirectory = try #require(realpath(fake.home + "/.colima-gui", nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    })
    #expect(log == ["list --json", "LIMA_HOME=\(fake.home)/.lima", "PWD=\(workingDirectory)"])
    #expect(listing.machines.map(\.name.instanceName) == ["cg-dev"])
    #expect(listing.machines.first?.runState == .running)
    #expect(listing.unownedMachineKeys == [try #require(MachineKey(unownedInstanceName: "cg-theirs"))])
  }

  @Test func listInstancesWithEmptyOutputAndZeroExitIsAnEmptyListing() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("echo 'WARN no instances' >&2; exit 0")

    let listing = try await fake.commandLine().listInstances()
    #expect(listing == LimaListing(machines: [], unownedMachineKeys: []))
  }

  @Test func listInstancesKeepsTheLastFiftyStderrLinesOfANonZeroExit() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    let stderr = lines(60, prefix: "err")
    try fake.install("echo out; cat >&2 <<'ERR'\n\(stderr)ERR\nexit 3")

    let expected = (11...60).map { "err \($0)" }
    await #expect(throws: LimaCLIError.nonZeroExit(code: 3, output: expected)) {
      try await fake.commandLine().listInstances()
    }
  }

  @Test func listInstancesFallsBackToStdoutWhenStderrIsEmpty() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("echo 'unable to load instance'; exit 1")

    await #expect(throws: LimaCLIError.nonZeroExit(code: 1, output: ["unable to load instance"])) {
      try await fake.commandLine().listInstances()
    }
  }

  @Test func listInstancesThrowsLimactlMissingWhenTheExecutableIsAbsent() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }

    await #expect(throws: LimaCLIError.limactlMissing) { try await fake.commandLine().listInstances() }
  }

  @Test func listInstancesMapsLaunchFailure() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.bin.install("limactl", script: "#!/nonexistent/interpreter\n")

    let error = await #expect(throws: LimaCLIError.self) { try await fake.commandLine().listInstances() }
    guard case .launchFailed = error else {
      Issue.record("expected launchFailed, got \(String(describing: error))")
      return
    }
  }

  @Test func cancellingTheTaskEndsTheListChild() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("echo $$ > '\(fake.log.path)'; exec sleep 30")
    let commandLine = fake.commandLine()

    let task = Task { try await commandLine.listInstances() }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    await #expect(throws: LimaCLIError.cancelled) { try await task.value }
    let pid = try #require(
      Int32(try String(contentsOf: fake.log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var gone = false
    for _ in 0..<100 where !gone {
      gone = kill(pid, 0) != 0
      if !gone { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(gone)
  }

  @Test func listTemplatesRunsCreateListTemplatesAndKeepsOnlyAllowListedLinux() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install(
      """
      echo "$*" > '\(fake.log.path)'
      printf '%s\\n' ubuntu ubuntu-24.04 docker k8s alpine-iso experimental/debian-sid debian-13 default fedora
      """)

    let templates = try await fake.commandLine().listTemplates()

    #expect(try String(contentsOf: fake.log, encoding: .utf8) == "create --list-templates\n")
    #expect(templates.map(\.id) == ["ubuntu", "ubuntu-24.04", "debian-13", "fedora"])
  }

  @Test func listTemplatesThrowsLimactlMissingAndKeepsNonZeroOutput() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    await #expect(throws: LimaCLIError.limactlMissing) { try await fake.commandLine().listTemplates() }

    try fake.install("echo 'bad templates' >&2; exit 2")
    await #expect(throws: LimaCLIError.nonZeroExit(code: 2, output: ["bad templates"])) {
      try await fake.commandLine().listTemplates()
    }
  }

  @Test func runSendsTheCommandToTheAgentAndRelaysItsEvents() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("exit 0")
    let agent = FakeMachineAgent(events: [.output("booting"), .exited(code: 4)])
    let dev = try machine("dev")

    let run = await fake.commandLine(agent: agent).run(.start(dev))
    let events = await collectEvents(run)

    #expect(agent.commands == [.start(dev)])
    #expect(events == [.output("booting"), .exited(code: 4)])
    #expect(await run.terminate())
  }

  @Test func runFailsWithoutContactingTheAgentWhenLimactlIsMissing() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    let agent = FakeMachineAgent()

    let run = await fake.commandLine(agent: agent).run(.stop(try machine("dev")))
    let events = await collectEvents(run)

    #expect(agent.commands.isEmpty)
    guard events.count == 1, case .launchFailed(let reason) = events[0] else {
      Issue.record("expected one launchFailed, got \(events)")
      return
    }
    #expect(reason.contains(fake.limactlPath))
    #expect(await run.terminate() == false)
  }

  @Test func runRelaysALaunchFailureFromTheAgent() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    try fake.install("exit 0")
    let agent = FakeMachineAgent(events: [.launchFailed(reason: "agent busy")])

    let events = await collectEvents(
      await fake.commandLine(agent: agent).run(.delete(try machine("dev"))))
    #expect(events == [.launchFailed(reason: "agent busy")])
  }

  @Test func activeOperationsKeepsOnlyMachineRunsWithTheirRunIDs() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    let dev = try machine("dev")
    let other = try machine("other")
    let firstID = UUID()
    let secondID = UUID()
    let agent = FakeMachineAgent(runs: [
      AgentRunSummary(runID: firstID, command: .machine(.start(dev))),
      AgentRunSummary(runID: UUID(), command: .colima(.start)),
      AgentRunSummary(runID: secondID, command: .machine(.delete(other))),
    ])

    let operations = await fake.commandLine(agent: agent).activeOperations()

    #expect(
      operations == [
        ActiveMachineOperation(runID: firstID, name: dev, kind: .start),
        ActiveMachineOperation(runID: secondID, name: other, kind: .delete),
      ])
  }

  @Test func activeOperationsIsNilWhenTheAgentCannotAnswer() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }

    #expect(await fake.commandLine(agent: FakeMachineAgent(runs: nil)).activeOperations() == nil)
  }

  @Test func terminateEarlierRunPassesTheRunIDAndReturnsTheAnswer() async throws {
    let fake = try FakeLimactl()
    defer { fake.remove() }
    let id = UUID()
    let accepting = FakeMachineAgent(acceptsTermination: true)
    let refusing = FakeMachineAgent(acceptsTermination: false)

    #expect(await fake.commandLine(agent: accepting).terminateEarlierRun(runID: id))
    #expect(await fake.commandLine(agent: refusing).terminateEarlierRun(runID: id) == false)
    #expect(accepting.terminated == [id])
    #expect(refusing.terminated == [id])
  }
}
