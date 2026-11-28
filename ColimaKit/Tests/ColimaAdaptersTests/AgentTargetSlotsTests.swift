import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaProcess

final class GatedMachineLauncher: MachineCommandLauncher {
  private let launched = Mutex<[MachineCommand]>([])

  var commands: [MachineCommand] { launched.withLock { $0 } }

  func run(_ command: MachineCommand) async -> VMCommandRun {
    launched.withLock { $0.append(command) }
    let (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self)
    let alive = Mutex(true)
    continuation.yield(.output("started \(command.name.rawValue)"))
    return VMCommandRun(
      events: events,
      terminate: {
        guard alive.withLock({ let was = $0; $0 = false; return was }) else { return false }
        continuation.yield(.exited(code: 143))
        continuation.finish()
        return true
      })
  }
}

private final class EventLog: NSObject, ColimaAgentClientProtocol, @unchecked Sendable {
  private let lock = Mutex<[UUID: [ProcessEvent]]>([:])

  func output(runID: UUID, line: String) { append(runID, .output(line)) }
  func exited(runID: UUID, code: Int32) { append(runID, .exited(code: code)) }
  func launchFailed(runID: UUID, reason: String) { append(runID, .launchFailed(reason: reason)) }

  func events(of runID: UUID) -> [ProcessEvent] { lock.withLock { $0[runID] ?? [] } }

  func waitFor(_ runID: UUID, _ predicate: ([ProcessEvent]) -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if predicate(events(of: runID)) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  private func append(_ runID: UUID, _ event: ProcessEvent) {
    lock.withLock { $0[runID, default: []].append(event) }
  }
}

private struct RawConnection {
  let connection: NSXPCConnection
  let proxy: any ColimaAgentProtocol
  let log = EventLog()

  init(_ listener: NSXPCListener) throws {
    connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ColimaAgentProtocol.self)
    connection.exportedInterface = NSXPCInterface(with: ColimaAgentClientProtocol.self)
    connection.exportedObject = log
    connection.resume()
    proxy = try #require(connection.remoteObjectProxy as? any ColimaAgentProtocol)
  }

  func start(_ runID: UUID, _ command: AgentCommand) async -> Int {
    await start(runID, payload: try! JSONEncoder().encode(command))
  }

  func start(_ runID: UUID, payload: Data) async -> Int {
    await withCheckedContinuation { continuation in
      proxy.start(runID: runID, command: payload) { continuation.resume(returning: $0) }
    }
  }

  func terminate(_ runID: UUID) async -> Bool {
    await withCheckedContinuation { continuation in
      proxy.terminate(runID: runID) { continuation.resume(returning: $0) }
    }
  }

  func invalidate() { connection.invalidate() }
}

private func machine(_ name: String) throws -> MachineName {
  try MachineName.parse(name, limaHomeUTF8Count: 20).get()
}

private func machineStart(_ name: String) throws -> AgentCommand {
  .machine(.start(try machine(name)))
}

private let accepted = AgentStartReply.accepted.rawValue
private let busy = AgentStartReply.busy.rawValue

@Suite("Agent target slots", .serialized)
struct AgentTargetSlotsTests {
  @Test func twoMachinesAndColimaRunAtTheSameTime() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo colima-up; exec sleep 30")
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let (dev, web, vm) = (UUID(), UUID(), UUID())

    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.start(web, try machineStart("web")) == accepted)
    #expect(await client.start(vm, .colima(.start)) == accepted)

    #expect(await client.log.waitFor(dev) { $0 == [.output("started dev")] })
    #expect(await client.log.waitFor(web) { $0 == [.output("started web")] })
    #expect(await client.log.waitFor(vm) { $0 == [.output("colima-up")] })
    #expect(machines.commands.count == 2)
    for runID in [dev, web, vm] { #expect(await client.terminate(runID)) }
  }

  @Test func theSameMachineIsBusyEvenWhenTheCaseDiffers() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let first = UUID()

    #expect(await client.start(first, try machineStart("dev")) == accepted)
    #expect(await client.start(UUID(), try machineStart("dev")) == busy)
    #expect(await client.start(UUID(), try machineStart("DEV")) == busy)
    #expect(await client.start(UUID(), try machineStart("Dev")) == busy)
    #expect(machines.commands == [.start(try machine("dev"))])

    #expect(await client.terminate(first))
    #expect(await client.log.waitFor(first) { $0.last == .exited(code: 143) })
    let again = UUID()
    var reply = busy
    for _ in 0..<100 where reply != accepted {
      reply = await client.start(again, try machineStart("DEV"))
      if reply != accepted { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(reply == accepted)
    #expect(await client.terminate(again))
  }

  @Test func aSecondColimaRunIsBusyWhileAMachineRuns() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo colima-up; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let (dev, first) = (UUID(), UUID())

    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.start(first, .colima(.start)) == accepted)
    #expect(await client.start(UUID(), .colima(.stop)) == busy)
    #expect(await client.terminate(first))
    #expect(await client.terminate(dev))
  }

  @Test func aColimaCommandStartedElsewhereDoesNotBlockAMachine() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher, foreignCommandIsRunning: true)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let dev = UUID()

    #expect(await client.start(UUID(), .colima(.start)) == busy)
    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.terminate(dev))
  }

  @Test func aRunRefusedForAForeignCommandReleasesItsSlot() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("exit 0")
    let agent = AgentFixture(launcher: scripts.launcher, foreignCommandIsRunning: true)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }

    #expect(await client.start(UUID(), .colima(.start)) == busy)

    let ready = await withCheckedContinuation { continuation in
      client.proxy.prepareForUpdate { continuation.resume(returning: $0) }
    }
    #expect(ready)
  }

  @Test func whatIsNotAnEnvelopeIsRejected() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }

    for payload in [
      #"{"kind":"start"}"#,
      #"{"target":"other","command":{"kind":"start"}}"#,
      #"{"target":"colima"}"#,
      #"{"target":"machine","command":{"kind":"start","name":"default"}}"#,
      #"{"target":"machine","command":{"kind":"start","name":"colima"}}"#,
    ] {
      let reply = await client.start(UUID(), payload: Data(payload.utf8))
      #expect(reply == AgentStartReply.undecodableCommand.rawValue, "\(payload)")
    }
    #expect(machines.commands.isEmpty)
  }

  @Test func anyConnectionCanTerminateOneRunWithoutTouchingTheOthers() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let owner = try RawConnection(agent.listener)
    let other = try RawConnection(agent.listener)
    defer {
      owner.invalidate()
      other.invalidate()
    }
    let (dev, web) = (UUID(), UUID())
    #expect(await owner.start(dev, try machineStart("dev")) == accepted)
    #expect(await owner.start(web, try machineStart("web")) == accepted)
    #expect(await owner.log.waitFor(web) { $0 == [.output("started web")] })

    #expect(await other.terminate(UUID()) == false)
    #expect(await other.terminate(dev))

    #expect(await owner.log.waitFor(dev) { $0 == [.output("started dev"), .exited(code: 143)] })
    #expect(owner.log.events(of: web) == [.output("started web")])
    #expect(await other.terminate(dev) == false)
    #expect(await other.terminate(web))
    #expect(await owner.log.waitFor(web) { $0.last == .exited(code: 143) })
  }

  @Test func updatesAreRefusedWhileAMachineRuns() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let dev = UUID()
    #expect(await client.start(dev, try machineStart("dev")) == accepted)

    let ready = await withCheckedContinuation { continuation in
      client.proxy.prepareForUpdate { continuation.resume(returning: $0) }
    }

    #expect(ready == false)
    #expect(await client.terminate(dev))
  }

  private func activeRuns(_ client: RawConnection) async throws -> [AgentRunSummary] {
    let data = await withCheckedContinuation { continuation in
      client.proxy.activeRuns { continuation.resume(returning: $0) }
    }
    return try JSONDecoder().decode([AgentRunSummary].self, from: data)
  }

  private func prepareForUpdate(_ client: RawConnection) async -> Bool {
    await withCheckedContinuation { continuation in
      client.proxy.prepareForUpdate { continuation.resume(returning: $0) }
    }
  }

  @Test func aMachineOperatedOnOutsideTheAgentIsBusyAndReleasesItsSlot() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    agent.foreignMachines.set(try machine("dev").key, running: true)

    #expect(await client.start(UUID(), try machineStart("DEV")) == busy)
    #expect(machines.commands.isEmpty)
    #expect(try await activeRuns(client).isEmpty)
    #expect(await prepareForUpdate(client))
  }

  @Test func aForeignOperationOnOneMachineDoesNotBlockAnother() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    agent.foreignMachines.set(try machine("dev").key, running: true)

    let web = UUID()
    #expect(await client.start(web, try machineStart("web")) == accepted)
    #expect(await client.terminate(web))
  }

  @Test func aMachineWhoseExternalOperationEndedCanStartAgain() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let key = try machine("dev").key
    agent.foreignMachines.set(key, running: true)
    #expect(await client.start(UUID(), try machineStart("dev")) == busy)
    agent.foreignMachines.set(key, running: false)

    let dev = UUID()
    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.terminate(dev))
  }

  @Test func activeRunsListsEveryLiveRunAndNothingAfterTheyEnd() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.installColima("echo colima-up; exec sleep 30")
    let agent = AgentFixture(launcher: scripts.launcher)
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    #expect(try await activeRuns(client).isEmpty)
    let (dev, vm) = (UUID(), UUID())

    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.start(vm, .colima(.start)) == accepted)

    let listed = try await activeRuns(client)
    #expect(Set(listed.map(\.runID)) == [dev, vm])
    #expect(listed.first { $0.runID == dev }?.command == (try machineStart("dev")))
    #expect(listed.first { $0.runID == vm }?.command == .colima(.start))

    #expect(await client.terminate(dev))
    #expect(await client.terminate(vm))
    var remaining = listed
    for _ in 0..<200 where !remaining.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      remaining = try await activeRuns(client)
    }
    #expect(remaining.isEmpty)
  }

  @Test func updatesAreAcceptedOnlyOnceEveryRunHasEnded() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let agent = AgentFixture(launcher: scripts.launcher, updateHold: .milliseconds(100))
    let client = try RawConnection(agent.listener)
    defer { client.invalidate() }
    let (dev, web) = (UUID(), UUID())
    #expect(await client.start(dev, try machineStart("dev")) == accepted)
    #expect(await client.start(web, try machineStart("web")) == accepted)

    #expect(await prepareForUpdate(client) == false)
    #expect(await client.terminate(dev))
    for _ in 0..<200 where try await activeRuns(client).count != 1 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await prepareForUpdate(client) == false)

    #expect(await client.terminate(web))
    var ready = false
    for _ in 0..<200 where !ready {
      ready = await prepareForUpdate(client)
      if !ready { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(ready)
  }

  @Test func aCreateKeepsRunningAfterTheAppDisconnects() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    let machines = GatedMachineLauncher()
    let agent = AgentFixture(launcher: scripts.launcher, machineLauncher: machines)
    let owner = try RawConnection(agent.listener)
    let later = try RawConnection(agent.listener)
    defer { later.invalidate() }
    let create = try JSONDecoder().decode(
      AgentCommand.self,
      from: Data(
        #"{"target":"machine","command":{"kind":"create","name":"dev","template":"ubuntu-24.04","cpus":2,"memoryGiB":4,"diskGiB":100,"mounts":[]}}"#
          .utf8))
    let runID = UUID()
    #expect(await owner.start(runID, create) == accepted)
    #expect(await owner.log.waitFor(runID) { $0 == [.output("started dev")] })

    owner.invalidate()
    try await Task.sleep(for: .milliseconds(300))

    #expect(try await activeRuns(later) == [AgentRunSummary(runID: runID, command: create)])
    #expect(await prepareForUpdate(later) == false)
    #expect(await later.start(UUID(), try machineStart("dev")) == busy)
    #expect(await later.terminate(runID))
  }
}
