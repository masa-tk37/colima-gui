import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

private final class CountingLauncher: VMCommandLauncher {
  private let base: any VMCommandLauncher
  private let count = Mutex(0)

  init(_ base: any VMCommandLauncher) { self.base = base }

  var runs: Int { count.withLock { $0 } }

  func run(_ command: VMCommand) async -> VMCommandRun {
    count.withLock { $0 += 1 }
    return await base.run(command)
  }
}

final class ForeignMachines: Sendable {
  private let keys = Mutex<Set<MachineKey>>([])

  func set(_ key: MachineKey, running: Bool) {
    keys.withLock { keys in
      if running { keys.insert(key) } else { keys.remove(key) }
    }
  }

  func contains(_ key: MachineKey) -> Bool { keys.withLock { $0.contains(key) } }
}

final class AgentFixture {
  let listener = NSXPCListener.anonymous()
  let service: AgentService
  let foreignMachines = ForeignMachines()

  /// `foreignCommandIsRunning` answers for the colima target; machine targets follow `foreignMachines`.
  init(
    launcher: any VMCommandLauncher, machineLauncher: any MachineCommandLauncher = GatedMachineLauncher(),
    foreignCommandIsRunning: Bool = false, updateHold: Duration = .seconds(30)
  ) {
    let foreignMachines = foreignMachines
    service = AgentService(
      vmLauncher: launcher, machineLauncher: machineLauncher, peerRequirement: { .unchecked },
      foreignCommandIsRunning: { target in
        switch target {
        case .colima: foreignCommandIsRunning
        case .machine(let key): foreignMachines.contains(key)
        }
      },
      updateHold: updateHold)
    listener.delegate = service
    listener.resume()
  }

  func client(
    registration: AgentRegistration = .enabled, acceptTimeout: Duration = .seconds(10)
  ) -> AgentClient {
    makeClient(
      endpoint: listener.endpoint, registration: registration, acceptTimeout: acceptTimeout)
  }

  deinit { listener.invalidate() }
}

private func makeClient(
  endpoint: NSXPCListenerEndpoint, registration: AgentRegistration = .enabled,
  acceptTimeout: Duration = .seconds(10)
) -> AgentClient {
  AgentClient(
    makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) },
    registration: { registration },
    acceptTimeout: acceptTimeout)
}

private func waitForFile(_ path: String, timeout: Duration = .seconds(10)) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if FileManager.default.fileExists(atPath: path) { return true }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return false
}

private final class ScriptedAgent: NSObject, NSXPCListenerDelegate, ColimaAgentProtocol,
  @unchecked Sendable
{
  enum Behavior {
    case wrongVersion
    case neverReplyToStart
    case acceptThenDisconnect
    case exitThenDisconnect
    case silent
  }

  let listener = NSXPCListener.anonymous()
  private let behavior: Behavior
  private let lock = NSLock()
  private var connection: NSXPCConnection?

  init(_ behavior: Behavior) {
    self.behavior = behavior
    super.init()
    listener.delegate = self
    listener.resume()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedObject = self
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    connection.resume()
    lock.withLock { self.connection = connection }
    return true
  }

  func hello(reply: @escaping @Sendable (Int) -> Void) {
    guard behavior != .silent else { return }
    reply(behavior == .wrongVersion ? AgentXPC.protocolVersion + 1 : AgentXPC.protocolVersion)
  }

  func start(runID: UUID, command: Data, reply: @escaping @Sendable (Int) -> Void) {
    let connection = lock.withLock { self.connection }
    switch behavior {
    case .wrongVersion, .neverReplyToStart, .silent:
      return
    case .acceptThenDisconnect:
      reply(AgentStartReply.accepted.rawValue)
      (connection?.remoteObjectProxy as? any ColimaAgentClientProtocol)?.output(
        runID: runID, line: "booting")
      connection?.invalidate()
    case .exitThenDisconnect:
      reply(AgentStartReply.accepted.rawValue)
      (connection?.remoteObjectProxy as? any ColimaAgentClientProtocol)?.exited(
        runID: runID, code: 0)
      connection?.invalidate()
    }
  }

  func terminate(runID: UUID, reply: @escaping @Sendable (Bool) -> Void) { reply(false) }
  func prepareForUpdate(reply: @escaping @Sendable (Bool) -> Void) {
    if behavior != .silent { reply(true) }
  }
  func activeRuns(reply: @escaping @Sendable (Data) -> Void) {
    if behavior != .silent { reply(Data("[]".utf8)) }
  }
}

private final class RecordingCallbacks: NSObject, ColimaAgentClientProtocol, @unchecked Sendable {
  func output(runID: UUID, line: String) {}
  func exited(runID: UUID, code: Int32) {}
  func launchFailed(runID: UUID, reason: String) {}
}

@Suite("Agent over XPC", .serialized)
struct AgentXPCTests {
  @Test func outputArrivesInOrderBeforeTheExit() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo one; echo two; echo three; exit 3")
    let agent = AgentFixture(launcher: scripts.launcher)

    let events = await collectEvents(await agent.client().run(.start))

    #expect(events == [.output("one"), .output("two"), .output("three"), .exited(code: 3)])
  }

  @Test func aCommandThatExitsAtOnceStillEndsWithItsExit() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let agent = AgentFixture(launcher: scripts.launcher)

    #expect(await collectEvents(await agent.client().run(.stop)) == [.exited(code: 0)])
  }

  @Test func theAgentBuildsArgvFromTheCommand() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima(
      #"for a in "$@"; do echo "arg:$a"; done; [ "$PWD" -ef "$(dirname "$0")" ] && echo "cwd:script-dir""#
    )
    let agent = AgentFixture(launcher: scripts.launcher)
    let spec = try VMSettingsValidator.validate(
      SettingsFormInput(cpus: "2", memoryGiB: "4", diskGiB: "60", vmType: .vz), diskFloorGiB: nil
    ).get()

    let events = await collectEvents(await agent.client().run(.create(spec)))

    let echoed = events.compactMap { event -> String? in
      guard case .output(let line) = event, line.hasPrefix("arg:") else { return nil }
      return String(line.dropFirst(4))
    }
    #expect(echoed == VMCommand.create(spec).arguments)
    #expect(events.contains(.output("cwd:script-dir")))
  }

  @Test func aMissingColimaIsALaunchFailure() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)

    let events = await collectEvents(await agent.client().run(.start))

    #expect(events.count == 1)
    guard case .launchFailed = events.first else {
      Issue.record("expected launchFailed, got \(events)")
      return
    }
  }

  @Test func terminateReachesTheChildThroughTheAgent() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo started; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)

    let run = await agent.client().run(.start)
    var iterator = run.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started"))
    #expect(await run.terminate())
    var rest: [ProcessEvent] = []
    while let event = await iterator.next() { rest.append(event) }

    #expect(rest == [.exited(code: 143)])
    #expect(await run.terminate() == false)
  }

  @Test(arguments: [AgentRegistration.requiresApproval, .notRegistered, .notFound])
  func anUnusableRegistrationFailsWithoutContactingTheAgent(registration: AgentRegistration)
    async throws
  {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let launcher = CountingLauncher(scripts.launcher)
    let agent = AgentFixture(launcher: launcher)

    let events = await collectEvents(await agent.client(registration: registration).run(.start))

    #expect(events == [.launchFailed(reason: AgentMessages.refusal(for: registration)!)])
    #expect(launcher.runs == 0)
  }

  @Test func aSecondRunFromAnotherConnectionIsBusy() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo started; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)

    let first = await agent.client().run(.start)
    var iterator = first.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started"))

    let second = await collectEvents(await agent.client().run(.stop))

    #expect(second == [.launchFailed(reason: AgentMessages.rejected(.busy))])
    #expect(await first.terminate())
    while await iterator.next() != nil {}
  }

  @Test func aColimaCommandStartedElsewhereMakesTheAgentBusy() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let launcher = CountingLauncher(scripts.launcher)
    let agent = AgentFixture(launcher: launcher, foreignCommandIsRunning: true)

    let events = await collectEvents(await agent.client().run(.start))

    #expect(events == [.launchFailed(reason: AgentMessages.rejected(.busy))])
    #expect(launcher.runs == 0)
  }

  @Test func theAgentRejectsWhatItCannotDecode() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let connection = NSXPCConnection(listenerEndpoint: agent.listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let proxy = try #require(connection.remoteObjectProxy as? any ColimaAgentProtocol)

    for payload in [
      Data("not json".utf8),
      Data(
        #"{"target":"colima","command":{"kind":"create","cpus":0,"memoryGiB":8,"diskGiB":100,"vmType":"vz"}}"#
          .utf8),
    ] {
      let reply = await withCheckedContinuation { continuation in
        proxy.start(runID: UUID(), command: payload) { continuation.resume(returning: $0) }
      }
      #expect(reply == AgentStartReply.undecodableCommand.rawValue)
    }
  }

  @Test func theChildOutlivesTheAppThatStartedIt() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let marker = scripts.path("finished")
    try scripts.installColima("echo started; sleep 1; echo done > '\(marker)'")
    let agent = AgentFixture(launcher: scripts.launcher)

    let connection = NSXPCConnection(listenerEndpoint: agent.listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    connection.exportedObject = RecordingCallbacks()
    connection.resume()
    let proxy = try #require(connection.remoteObjectProxy as? any ColimaAgentProtocol)
    let reply = await withCheckedContinuation { continuation in
      proxy.start(
        runID: UUID(), command: try! JSONEncoder().encode(AgentCommand.colima(.start))
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(reply == AgentStartReply.accepted.rawValue)
    connection.invalidate()

    #expect(await waitForFile(marker))
  }

  @Test func prepareForUpdateStopsAnIdleAgentFromTakingRuns() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = agent.client()

    #expect(await client.prepareForUpdate() == .idle)
    #expect(
      await collectEvents(await client.run(.start))
        == [.launchFailed(reason: AgentMessages.rejected(.updating))])
  }

  @Test func aPauseForAnUpdateThatNeverCameLapses() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let agent = AgentFixture(launcher: scripts.launcher, updateHold: .milliseconds(200))
    let client = agent.client()

    #expect(await client.prepareForUpdate() == .idle)
    try await Task.sleep(for: .milliseconds(500))

    #expect(await collectEvents(await client.run(.start)) == [.exited(code: 0)])
  }

  @Test func prepareForUpdateRefusesWhileARunIsAlive() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo started; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = agent.client()

    let run = await client.run(.start)
    var iterator = run.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started"))

    #expect(await client.prepareForUpdate() == .busy)
    #expect(await run.terminate())
    while await iterator.next() != nil {}
  }

  @Test func anAgentThatDoesNotAnswerIsReportedAsUnreachableForAnUpdate() async {
    let agent = ScriptedAgent(.silent)
    let client = makeClient(endpoint: agent.listener.endpoint, acceptTimeout: .milliseconds(300))

    #expect(await client.prepareForUpdate() == .unreachable)
  }

  @Test func anAgentThatDoesNotAnswerHelloEndsTheRun() async {
    let agent = ScriptedAgent(.silent)
    let client = makeClient(endpoint: agent.listener.endpoint, acceptTimeout: .milliseconds(300))

    #expect(
      await collectEvents(await client.run(.start)) == [
        .launchFailed(reason: AgentMessages.helperStopped)
      ])
  }

  @Test func anAgentOfAnotherVersionIsRefused() async {
    let agent = ScriptedAgent(.wrongVersion)

    let events = await collectEvents(await makeClient(endpoint: agent.listener.endpoint).run(.start))

    #expect(events == [.launchFailed(reason: AgentMessages.versionMismatch)])
  }

  @Test func noAnswerToStartEndsTheRunAsUnknown() async {
    let agent = ScriptedAgent(.neverReplyToStart)
    let client = makeClient(endpoint: agent.listener.endpoint, acceptTimeout: .milliseconds(300))

    let events = await collectEvents(await client.run(.start))

    #expect(events == [.launchFailed(reason: AgentMessages.resultUnknown)])
  }

  @Test func losingTheAgentMidRunEndsTheRun() async {
    let agent = ScriptedAgent(.acceptThenDisconnect)

    let run = await makeClient(endpoint: agent.listener.endpoint).run(.start)
    let events = await collectEvents(run)

    #expect(events.last == .launchFailed(reason: AgentMessages.helperStopped))
    #expect(events.filter { if case .output = $0 { false } else { true } }.count == 1)
    #expect(await run.terminate() == false)
  }

  @Test func anExitFollowedByADisconnectIsReportedOnce() async {
    let agent = ScriptedAgent(.exitThenDisconnect)

    let events = await collectEvents(await makeClient(endpoint: agent.listener.endpoint).run(.start))

    #expect(events == [.exited(code: 0)])
  }
}
