import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

private func machine(_ name: String) throws -> MachineName {
  try MachineName.parse(name, limaHomeUTF8Count: 20).get()
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
  private let version: Int?
  private let counts = Mutex((hello: 0, activeRuns: 0, terminate: 0))

  init(version: Int?) {
    self.version = version
    super.init()
    listener.delegate = self
    listener.resume()
  }

  var received: (hello: Int, activeRuns: Int, terminate: Int) { counts.withLock { $0 } }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedObject = self
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    connection.resume()
    return true
  }

  func hello(reply: @escaping @Sendable (Int) -> Void) {
    counts.withLock { $0.hello += 1 }
    if let version { reply(version) }
  }

  func start(runID: UUID, command: Data, reply: @escaping @Sendable (Int) -> Void) {}

  func terminate(runID: UUID, reply: @escaping @Sendable (Bool) -> Void) {
    counts.withLock { $0.terminate += 1 }
    reply(true)
  }

  func prepareForUpdate(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }

  func activeRuns(reply: @escaping @Sendable (Data) -> Void) {
    counts.withLock { $0.activeRuns += 1 }
    reply(Data("[]".utf8))
  }
}

private func client(for agent: VersionedAgent, acceptTimeout: Duration = .seconds(10)) -> AgentClient {
  AgentClient(
    makeConnection: { NSXPCConnection(listenerEndpoint: agent.listener.endpoint) },
    registration: { .enabled }, acceptTimeout: acceptTimeout)
}

@Suite("Agent client machine operations", .serialized)
struct AgentMachineClientTests {
  @Test func aMachineCommandRunsThroughTheAgentAndEndsOnce() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let dev = try machine("dev")

    let run = await agent.client().run(.start(dev))
    var iterator = run.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started dev"))
    #expect(await run.terminate())
    var rest: [ProcessEvent] = []
    while let event = await iterator.next() { rest.append(event) }

    #expect(rest == [.exited(code: 143)])
    #expect(machines.commands == [.start(dev)])
  }

  @Test func anUnusableRegistrationFailsAMachineCommandWithoutContactingTheAgent() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)

    let events = await collectEvents(
      await agent.client(registration: .requiresApproval).run(.stop(try machine("dev"))))

    #expect(events == [.launchFailed(reason: AgentMessages.refusal(for: .requiresApproval)!)])
    #expect(machines.commands.isEmpty)
  }

  @Test func theSameMachineIsRefusedWithTheMachineWording() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let dev = try machine("dev")

    let first = await agent.client().run(.start(dev))
    var iterator = first.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started dev"))

    let second = await collectEvents(await agent.client().run(.stop(dev)))

    #expect(second == [.launchFailed(reason: AgentMessages.rejected(.busy, for: .machine(dev.key)))])
    #expect(AgentMessages.rejected(.busy, for: .machine(dev.key)) != AgentMessages.rejected(.busy))
    #expect(await first.terminate())
    while await iterator.next() != nil {}
  }

  @Test func aMachineCommandStartedElsewhereIsRefusedWithTheMachineWording() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let dev = try machine("dev")
    agent.foreignMachines.set(dev.key, running: true)

    let events = await collectEvents(await agent.client().run(.start(dev)))

    #expect(events == [.launchFailed(reason: AgentMessages.rejected(.busy, for: .machine(dev.key)))])
  }

  @Test func aBusyColimaKeepsTheColimaWording() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher, foreignCommandIsRunning: true)

    let events = await collectEvents(await agent.client().run(.start))

    #expect(events == [.launchFailed(reason: AgentMessages.rejected(.busy, for: .colima))])
    #expect(AgentMessages.rejected(.busy, for: .colima) == AgentMessages.rejected(.busy))
  }

  @Test func theActiveRunsListNamesEveryRunWithItsCommand() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo up; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = agent.client()
    let (dev, web) = (try machine("dev"), try machine("web"))
    #expect(await client.activeRuns() == [])

    let devRun = await client.run(.start(dev))
    let webRun = await client.run(.delete(web))
    let vmRun = await client.run(.start)
    var iterators = [devRun, webRun, vmRun].map { $0.events.makeAsyncIterator() }
    for index in iterators.indices { #expect(await iterators[index].next() != nil) }

    let commands = try #require(await client.activeRuns()).map(\.command)
    #expect(commands.count == 3)
    #expect(commands.contains(.machine(.start(dev))))
    #expect(commands.contains(.machine(.delete(web))))
    #expect(commands.contains(.colima(.start)))
    for run in [devRun, webRun, vmRun] { #expect(await run.terminate()) }
  }

  @Test func anEarlierSessionsRunIsStoppedFromANewClient() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let dev = try machine("dev")
    let earlier = await agent.client().run(.start(dev))
    var iterator = earlier.events.makeAsyncIterator()
    #expect(await iterator.next() == .output("started dev"))

    let current = agent.client()
    let summary = try #require(await current.activeRuns()?.first)
    #expect(summary.command == .machine(.start(dev)))

    #expect(await current.terminateEarlierRun(runID: summary.runID))
    var rest: [ProcessEvent] = []
    while let event = await iterator.next() { rest.append(event) }
    #expect(rest == [.exited(code: 143)])
    #expect(await waitUntil { await current.activeRuns() == [] })
    #expect(await current.terminateEarlierRun(runID: summary.runID) == false)
  }

  @Test func anUnknownRunIsNotStopped() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)

    #expect(await agent.client().terminateEarlierRun(runID: UUID()) == false)
  }

  @Test(arguments: [1, AgentXPC.protocolVersion + 1])
  func anAgentOfAnotherVersionIsNeverAskedForRunsOrToStopOne(version: Int) async {
    let agent = VersionedAgent(version: version)
    let client = client(for: agent)

    #expect(await client.activeRuns() == nil)
    #expect(await client.terminateEarlierRun(runID: UUID()) == false)

    let received = agent.received
    #expect(received.hello == 2)
    #expect(received.activeRuns == 0)
    #expect(received.terminate == 0)
  }

  @Test func anAgentThatDoesNotAnswerGivesNoRunsAndNoStop() async {
    let agent = VersionedAgent(version: nil)
    let client = client(for: agent, acceptTimeout: .milliseconds(300))

    #expect(await client.activeRuns() == nil)
    #expect(await client.terminateEarlierRun(runID: UUID()) == false)
    #expect(agent.received.activeRuns == 0)
    #expect(agent.received.terminate == 0)
  }

  @Test func aCurrentAgentIsAskedAfterHello() async {
    let agent = VersionedAgent(version: AgentXPC.protocolVersion)
    let client = client(for: agent)

    #expect(await client.activeRuns() == [])
    #expect(await client.terminateEarlierRun(runID: UUID()))

    let received = agent.received
    #expect(received.hello == 2)
    #expect(received.activeRuns == 1)
    #expect(received.terminate == 1)
  }

  @Test func registrationRefusesQueriesWithoutContactingTheAgent() async {
    let agent = VersionedAgent(version: AgentXPC.protocolVersion)
    let client = AgentClient(
      makeConnection: { NSXPCConnection(listenerEndpoint: agent.listener.endpoint) },
      registration: { .notRegistered }, acceptTimeout: .seconds(10))

    #expect(await client.activeRuns() == nil)
    #expect(await client.terminateEarlierRun(runID: UUID()) == false)
    #expect(agent.received.hello == 0)
  }
}
