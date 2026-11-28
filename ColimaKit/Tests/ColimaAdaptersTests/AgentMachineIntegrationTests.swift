import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

/// A fake `limactl` and lima home under a temporary directory, so a real `LocalMachineCommandLauncher` never touches `~/.lima`.
private struct LimactlSandbox {
  let root: URL
  let invocation: LimaInvocation

  var instanceDirectory: String { invocation.limaHome + "/cg-dev" }
  var callsPath: String { root.appendingPathComponent("calls.log").path }

  init(create: String, delete: String = "echo deleted; rm -rf \"$LIMA_HOME/cg-dev\"", other: String = "exit 0") throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentMachineIntegrationTests-\(UUID().uuidString)", isDirectory: true)
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

  var launcher: LocalMachineCommandLauncher {
    LocalMachineCommandLauncher(
      invocation: invocation, runner: ProcessRunner(pipeEOFGrace: .milliseconds(500), killGrace: .seconds(5)))
  }

  func calls() -> [String] {
    ((try? String(contentsOfFile: callsPath, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func directoryExists() -> Bool { FileManager.default.fileExists(atPath: instanceDirectory) }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private func decode(_ json: String) throws -> MachineCommand {
  try JSONDecoder().decode(MachineCommand.self, from: Data(json.utf8))
}

private let createJSON =
  #"{"kind":"create","name":"dev","template":"ubuntu-24.04","cpus":2,"memoryGiB":4,"diskGiB":100,"mounts":[]}"#

private func exitCodes(_ events: [ProcessEvent]) -> [Int32] {
  events.compactMap { if case .exited(let code) = $0 { code } else { nil } }
}

private func lines(_ events: [ProcessEvent]) -> [String] {
  events.compactMap { if case .output(let line) = $0 { line } else { nil } }
}

private func waitUntil(_ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(10)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return false
}

private final class VersionedAgent: NSObject, NSXPCListenerDelegate, ColimaAgentProtocol,
  @unchecked Sendable
{
  let listener = NSXPCListener.anonymous()
  private let version: Int
  private let starts = Mutex(0)

  init(version: Int) {
    self.version = version
    super.init()
    listener.delegate = self
    listener.resume()
  }

  var startsReceived: Int { starts.withLock { $0 } }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedObject = self
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    connection.resume()
    return true
  }

  func hello(reply: @escaping @Sendable (Int) -> Void) { reply(version) }

  func start(runID: UUID, command: Data, reply: @escaping @Sendable (Int) -> Void) {
    starts.withLock { $0 += 1 }
    reply(AgentStartReply.accepted.rawValue)
  }

  func terminate(runID: UUID, reply: @escaping @Sendable (Bool) -> Void) { reply(false) }
  func prepareForUpdate(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
  func activeRuns(reply: @escaping @Sendable (Data) -> Void) { reply(Data("[]".utf8)) }
}

@Suite("Agent machine runs over XPC", .serialized)
struct AgentMachineIntegrationTests {
  @Test func aMachineStartDeliversItsOutputInOrderThenOneExit() async throws {
    let lima = try LimactlSandbox(create: "exit 0", other: "echo booting; echo ready; exit 0")
    let colima = try FakeBin()
    defer {
      lima.remove()
      colima.remove()
    }
    let agent = AgentFixture(launcher: colima.launcher, machineLauncher: lima.launcher)

    let events = await collectEvents(await agent.client().run(try decode(#"{"kind":"start","name":"dev"}"#)))

    #expect(events == [.output("booting"), .output("ready"), .exited(code: 0)])
    #expect(lima.calls() == ["start --tty=false cg-dev"])
  }

  @Test func aSuccessfulCreateKeepsItsDirectoryAndEndsOnce() async throws {
    let lima = try LimactlSandbox(create: "mkdir -p \"$LIMA_HOME/cg-dev\"; echo made")
    let colima = try FakeBin()
    defer {
      lima.remove()
      colima.remove()
    }
    let agent = AgentFixture(launcher: colima.launcher, machineLauncher: lima.launcher)

    let events = await collectEvents(await agent.client().run(try decode(createJSON)))

    #expect(events == [.output("made"), .exited(code: 0)])
    #expect(lima.directoryExists())
    #expect(lima.calls().count == 1)
  }

  @Test func aFailedCreateIsCleanedUpBeforeItsSingleExitReachesTheClient() async throws {
    let lima = try LimactlSandbox(create: "mkdir -p \"$LIMA_HOME/cg-dev\"; echo boom >&2; exit 3")
    let colima = try FakeBin()
    defer {
      lima.remove()
      colima.remove()
    }
    let agent = AgentFixture(launcher: colima.launcher, machineLauncher: lima.launcher)

    let run = await agent.client().run(try decode(createJSON))
    var seen: [ProcessEvent] = []
    var directoryAtExit: Bool?
    for await event in run.events {
      seen.append(event)
      if case .exited = event { directoryAtExit = lima.directoryExists() }
    }

    #expect(lines(seen) == ["boom", "deleted"])
    #expect(exitCodes(seen) == [3])
    #expect(seen.last == .exited(code: 3))
    #expect(directoryAtExit == false)
    #expect(lima.calls().last == "delete --tty=false --force cg-dev")
  }

  @Test func aCreateCancelledFromAnotherConnectionIsCleanedUpAndEndsOnce() async throws {
    let lima = try LimactlSandbox(
      create: "mkdir -p \"$LIMA_HOME/cg-dev\"; echo creating; exec sleep 60")
    let colima = try FakeBin()
    defer {
      lima.remove()
      colima.remove()
    }
    let agent = AgentFixture(launcher: colima.launcher, machineLauncher: lima.launcher)
    let dev = try MachineName.parse("dev", limaHomeUTF8Count: 20).get()

    let earlier = await agent.client().run(try decode(createJSON))
    var iterator = earlier.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("creating"))
    #expect(lima.directoryExists())

    let current = agent.client()
    let summary = try #require(await current.activeRuns()?.first)
    guard case .machine(.create(let spec)) = summary.command else {
      Issue.record("expected a machine create, got \(summary.command)")
      return
    }
    #expect(spec.name == dev)

    #expect(await current.terminateEarlierRun(runID: summary.runID))

    var rest: [ProcessEvent] = []
    var directoryAtExit: Bool?
    while let event = await iterator.next() {
      rest.append(event)
      if case .exited = event { directoryAtExit = lima.directoryExists() }
    }

    #expect(lines(rest) == ["deleted"])
    #expect(exitCodes(rest) == [143])
    #expect(rest.last == .exited(code: 143))
    #expect(directoryAtExit == false)
    #expect(lima.calls().last == "delete --tty=false --force cg-dev")
    #expect(lima.calls().filter { $0.hasPrefix("delete") }.count == 1)
    #expect(await waitUntil { await current.activeRuns() == [] })
    #expect(await current.terminateEarlierRun(runID: summary.runID) == false)
  }

  @Test func theAgentAnswersHelloWithTheProtocolVersion() async throws {
    let colima = try FakeBin()
    defer { colima.remove() }
    let agent = AgentFixture(launcher: colima.launcher)
    let connection = NSXPCConnection(listenerEndpoint: agent.listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let proxy = try #require(connection.remoteObjectProxy as? any ColimaAgentProtocol)

    let version = await withCheckedContinuation { continuation in
      proxy.hello { continuation.resume(returning: $0) }
    }

    #expect(version == AgentXPC.protocolVersion)
  }

  @Test(arguments: [1, AgentXPC.protocolVersion + 1])
  func aMachineRunIsNeverSentToAnAgentOfAnotherVersion(version: Int) async throws {
    let agent = VersionedAgent(version: version)
    let client = AgentClient(
      makeConnection: { NSXPCConnection(listenerEndpoint: agent.listener.endpoint) },
      registration: { .enabled }, acceptTimeout: .seconds(10))

    let events = await collectEvents(await client.run(try decode(createJSON)))

    #expect(events == [.launchFailed(reason: AgentMessages.versionMismatch)])
    #expect(agent.startsReceived == 0)
  }
}
