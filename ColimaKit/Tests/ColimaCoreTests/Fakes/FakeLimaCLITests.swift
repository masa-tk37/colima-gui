import Foundation
import Synchronization
import Testing

@testable import ColimaCore

private func collect(_ run: VMCommandRun) async -> [ProcessEvent] {
  var events: [ProcessEvent] = []
  for await event in run.events { events.append(event) }
  return events
}

private let dev = MachineName(instanceName: "cg-dev")!

private func instance(_ name: MachineName) -> MachineInstance {
  MachineInstance(
    name: name, runState: .running, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30, mounts: [],
    templateID: "ubuntu")
}

@Test func limaCLIRecordsCallsInInvocationOrder() async throws {
  let cli = FakeLimaCLI()
  _ = await cli.preflight()
  _ = try await cli.listInstances()
  _ = try await cli.listTemplates()
  let run = await cli.run(.stop(dev))
  _ = await run.terminate()
  _ = await cli.activeOperations()
  let runID = UUID()
  _ = await cli.terminateEarlierRun(runID: runID)

  #expect(
    cli.calls == [
      .preflight, .listInstances, .listTemplates, .run(.stop(dev)), .activeOperations,
      .terminateEarlierRun(runID),
    ])
}

@Test func limaCLIReturnsConfiguredReadsAndRepeatsTheLast() async throws {
  let cli = FakeLimaCLI()
  let listing = LimaListing(machines: [instance(dev)], unownedMachineKeys: [])
  let template = try #require(MachineTemplate(id: "ubuntu-24.04"))
  let missing = LimaToolchain.missing(searched: ["/opt/homebrew/bin"])
  cli.configure {
    $0.limaHomeUTF8Count = 30
    $0.toolchain = missing
    $0.listInstances = [.success(listing), .failure(.nonZeroExit(code: 1, output: ["boom"]))]
    $0.listTemplates = [.success([template]), .failure(.limactlMissing)]
  }

  #expect(cli.limaHomeUTF8Count == 30)
  #expect(await cli.preflight() == missing)
  #expect(try await cli.listInstances() == listing)
  await #expect(throws: LimaCLIError.nonZeroExit(code: 1, output: ["boom"])) { try await cli.listInstances() }
  await #expect(throws: LimaCLIError.nonZeroExit(code: 1, output: ["boom"])) { try await cli.listInstances() }
  #expect(try await cli.listTemplates() == [template])
  await #expect(throws: LimaCLIError.limactlMissing) { try await cli.listTemplates() }
}

@Test func limaCLICancelledTaskGetsCancelledErrorOverConfiguredResult() async {
  let cli = FakeLimaCLI()
  let cancelled = await Task { () -> [LimaCLIError] in
    withUnsafeCurrentTask { $0?.cancel() }
    var errors: [LimaCLIError] = []
    do throws(LimaCLIError) { _ = try await cli.listInstances() } catch { errors.append(error) }
    do throws(LimaCLIError) { _ = try await cli.listTemplates() } catch { errors.append(error) }
    return errors
  }.value
  #expect(cancelled == [LimaCLIError.cancelled, LimaCLIError.cancelled])
}

@Test func limaCLIActiveOperationsAndEarlierRunTerminationAreConfigurable() async {
  let cli = FakeLimaCLI()
  let operation = ActiveMachineOperation(runID: UUID(), name: dev, kind: .create)
  #expect(await FakeLimaCLI().activeOperations() == nil)

  cli.configure {
    $0.activeOperations = [[operation], []]
    $0.terminateEarlierRun = [false, true]
  }
  #expect(await cli.activeOperations() == [operation])
  #expect(await cli.activeOperations() == [])
  #expect(await cli.activeOperations() == [])
  #expect(await cli.terminateEarlierRun(runID: operation.runID) == false)
  #expect(await cli.terminateEarlierRun(runID: operation.runID) == true)
}

@Test func limaCLIScriptedRunPlaysItsEventsAndFinishes() async {
  let cli = FakeLimaCLI()
  cli.configure { $0.scriptedRuns = [[.output("creating"), .exited(code: 0)]] }

  let run = await cli.run(.start(dev))

  #expect(await collect(run) == [.output("creating"), .exited(code: 0)])
  #expect(await cli.process(at: 0).command == .start(dev))
}

@Test func limaCLIManualRunDeliversFedOutputThenExitAndIgnoresLaterInput() async {
  let cli = FakeLimaCLI()
  let run = await cli.run(.delete(dev))
  let process = await cli.process(at: 0)

  process.send("deleting")
  process.exit(code: 0)
  process.send("ignored after exit")

  #expect(await collect(run) == [.output("deleting"), .exited(code: 0)])
  #expect(process.isFinished)
}

@Test func limaCLILaunchFailureEndsTheRun() async {
  let cli = FakeLimaCLI()
  let run = await cli.run(.start(dev))
  await cli.process(at: 0).failLaunch(reason: "agent disabled")

  #expect(await collect(run) == [.launchFailed(reason: "agent disabled")])
}

@Test func limaCLITerminateEndsTheRunWithTheConfiguredExitCode() async {
  let cli = FakeLimaCLI()
  cli.configure { $0.exitCodeOnTerminate = 137 }
  let run = await cli.run(.start(dev))

  #expect(await run.terminate())
  #expect(await run.terminate() == false)
  #expect(await collect(run) == [.exited(code: 137)])
  #expect(await cli.process(at: 0).terminateCount == 2)
}

@Test func limaCLIRejectedTerminateLeavesTheRunOpen() async {
  let cli = FakeLimaCLI()
  cli.configure { $0.acceptsTerminate = false }
  let run = await cli.run(.start(dev))
  let process = await cli.process(at: 0)

  #expect(await run.terminate() == false)
  #expect(!process.isFinished)
  process.exit(code: 0)
  #expect(await collect(run) == [.exited(code: 0)])
}

@Test func limaCLIProcessLookupWaitsForARunNotYetStarted() async {
  let cli = FakeLimaCLI()
  async let process = cli.process(at: 1)
  _ = await cli.run(.start(dev))
  _ = await cli.run(.stop(dev))

  #expect(await process.command == .stop(dev))
}

@Test func limaCLIHooksRunBeforeEachReadReturns() async throws {
  let cli = FakeLimaCLI()
  let hits = Mutex<[String]>([])
  cli.configure {
    $0.beforePreflightReturns = { hits.withLock { $0.append("preflight") } }
    $0.beforeListInstancesReturns = { hits.withLock { $0.append("instances") } }
    $0.beforeListTemplatesReturns = { hits.withLock { $0.append("templates") } }
    $0.beforeActiveOperationsReturns = { hits.withLock { $0.append("active") } }
  }

  _ = await cli.preflight()
  _ = try await cli.listInstances()
  _ = try await cli.listTemplates()
  _ = await cli.activeOperations()

  #expect(hits.withLock { $0 } == ["preflight", "instances", "templates", "active"])
}

@Test func limaCLIProcessThatNeverArrivesRecordsAnIssueInsteadOfHanging() async {
  let cli = FakeLimaCLI()
  await withKnownIssue {
    let placeholder = await cli.process(at: 3, timeout: .milliseconds(50))
    #expect(placeholder.isFinished == false)
  }
}
