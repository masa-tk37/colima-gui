import Foundation
import Observation
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(_ name: String, _ runState: MachineRunState = .stopped) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30,
    mounts: [], templateID: "ubuntu")
}

private func listing(_ instances: MachineInstance..., unowned: Set<MachineKey> = []) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: unowned)
}

private func unownedKey(_ instanceName: String) -> MachineKey? {
  MachineKey(unownedInstanceName: instanceName)
}

private let host = HostResources(cpus: 8, memoryGiB: 32, diskGiB: 500)
private let ubuntu = MachineTemplate(id: "ubuntu")!
private let home = "/Users/me"

private func form(
  _ name: String = "dev", template: String? = "ubuntu", cpus: String = "2", memory: String = "4",
  disk: String = "100"
) -> MachineFormInput {
  MachineFormInput(name: name, templateID: template, cpus: cpus, memoryGiB: memory, diskGiB: disk)
}

private func expectedSpec(_ name: String) -> MachineCreateSpec {
  MachineCreateSpec(
    name: machineName(name), template: ubuntu,
    resources: MachineResources(cpus: 2, memoryGiB: 4, diskGiB: 100),
    mounts: [MachineMount(path: home, writable: true)])
}

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let controller: MachineController

  /// `listings[0]` is the read before the create, `listings[1]` the create's re-read, the rest the final reads.
  init(_ listings: [LimaListing] = [listing()]) async {
    controller = MachineController(cli: cli, host: host, homeDirectory: home)
    cli.configure { $0.listInstances = listings.map { .success($0) } }
    await controller.refreshNow()
  }

  var runs: [MachineCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func key(_ name: String) -> MachineKey { machineName(name).key }

  func task(for name: String) -> Task<Void, Never>? { controller.operationTasks[key(name)] }

  func wait(until predicate: @escaping @MainActor () -> Bool) async {
    for await holds in Observations({ predicate() }) where holds { return }
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerCreateTests {

  // MARK: Validation

  @Test func invalidInputReturnsEveryFieldErrorAndNeverReadsOrTakesASlot() async {
    let harness = await Harness()
    let readsBefore = harness.cli.calls.filter { $0 == .listInstances }.count

    let outcome = await harness.controller.create(
      form("", template: "windows", cpus: "99", memory: "x", disk: "0"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.name, .template, .cpu, .memory, .disk])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.cli.calls.filter { $0 == .listInstances }.count == readsBefore)
    #expect(harness.runs.isEmpty)
  }

  @Test func aTemplateOutsideTheGivenListIsInvalid() async {
    let harness = await Harness()

    let outcome = await harness.controller.create(form(template: "debian"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.template])
    #expect(harness.runs.isEmpty)
  }

  @Test func aNameOfAListedMachineIsADuplicateBeforeAnySlotIsTaken() async {
    let harness = await Harness([listing(instance("dev"))])

    let outcome = await harness.controller.create(form("DEV"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.name])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.runs.isEmpty)
  }

  @Test func theReservedNamesAreRefused() async {
    let harness = await Harness()

    for name in ["default", "colima"] {
      let outcome = await harness.controller.create(form(name), templates: [ubuntu])
      guard case .invalid(let failure) = outcome else {
        Issue.record("expected invalid for \(name), got \(outcome)")
        continue
      }
      #expect(failure.fields.map(\.field) == [.name])
    }
    #expect(harness.runs.isEmpty)
  }

  // MARK: Slot and the fresh read

  @Test func theSlotIsTakenBeforeTheFreshReadAndASecondCreateOfTheSameNameIsBusy() async {
    let harness = await Harness()
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListInstancesReturns = gate.pass }

    let first = Task { await harness.controller.create(form("dev"), templates: [ubuntu]) }
    await gate.waitForArrivals(1)

    #expect(harness.controller.operations[harness.key("dev")]?.kind == .create)
    #expect(harness.controller.rows().map(\.display) == [.creating])
    #expect(await harness.controller.create(form("Dev"), templates: [ubuntu]) == .busy)
    #expect(harness.runs.isEmpty)

    gate.open()
    #expect(await first.value == .started)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.create(expectedSpec("dev"))])
    process.exit(code: 0)
    await harness.task(for: "dev")?.value
  }

  @Test func aCreateRunningFromAnEarlierSessionMakesTheSameNameBusy() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.activeOperations = [[ActiveMachineOperation(runID: UUID(), name: machineName("dev"), kind: .create)]]
    }
    let rounds = RoundCounter()
    let controller = harness.controller
    let monitor = Task { await controller.monitor(clock: ManualClock(), didCompleteRound: rounds.roundCompleted) }
    await rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value
    #expect(harness.controller.rows().map(\.display) == [.creating])

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .busy)
    #expect(harness.runs.isEmpty)
  }

  @Test func anotherKindOfSlotOnTheSameNameNeverPassesAndIsLeftAlone() async {
    let harness = await Harness([listing(instance("dev", .stopped))])
    harness.controller.performStart(machineName("dev"))

    let outcome = await harness.controller.create(form("dev"), templates: [ubuntu])

    if case .started = outcome { Issue.record("a held slot must not be taken over") }
    #expect(harness.controller.operations[harness.key("dev")]?.kind == .start)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.start(machineName("dev"))])
    process.exit(code: 0)
    await harness.task(for: "dev")?.value
  }

  @Test func aSlotOnAnUnlistedNameIsNeverTakenOver() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.activeOperations = [[ActiveMachineOperation(runID: UUID(), name: machineName("dev"), kind: .delete)]]
    }
    let rounds = RoundCounter()
    let controller = harness.controller
    let monitor = Task { await controller.monitor(clock: ManualClock(), didCompleteRound: rounds.roundCompleted) }
    await rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value
    #expect(controller.operations[harness.key("dev")]?.kind == .delete)

    let outcome = await controller.create(form("dev"), templates: [ubuntu])

    if case .started = outcome { Issue.record("a held slot must not be taken over") }
    #expect(controller.operations[harness.key("dev")]?.kind == .delete)
    #expect(harness.runs.isEmpty)
  }

  @Test func whileLimactlIsMissingNothingIsReadAndNothingRuns() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = .missing(searched: ["/opt/homebrew/bin/limactl"])
      $0.listInstances = [.failure(.limactlMissing)]
    }
    await harness.controller.refreshNow()
    let calls = harness.cli.calls

    let outcome = await harness.controller.create(form("dev"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.template])
    #expect(!harness.controller.canCreate)
    #expect(harness.cli.calls == calls)
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func aNameTakenByAnUnownedInstanceInTheFreshReadReleasesTheSlotAndRunsNothing() async {
    let key = unownedKey("cg-dev")!
    let harness = await Harness([listing(), listing(unowned: [key])])
    let earlierRecord = MachineOperationRecord(kind: .create, startedAt: Date(timeIntervalSince1970: 1))
    let earlierFailure = MachineOperationFailure(
      name: machineName("dev"), kind: .create, cause: .exited(code: 1), outputLines: ["old"])
    harness.controller.records[harness.key("dev")] = earlierRecord
    harness.controller.failures[harness.key("dev")] = earlierFailure

    let outcome = await harness.controller.create(form("dev"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.name])
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().isEmpty)
    #expect(harness.controller.records[harness.key("dev")] === earlierRecord)
    #expect(harness.controller.failures[harness.key("dev")] == earlierFailure)
  }

  @Test func theCaseVariantOfAnUnownedInstanceCollidesButANameWithoutThePrefixDoesNot() async {
    #expect(unownedKey("dev") == nil)
    let collide = await Harness([listing(), listing(unowned: [unownedKey("CG-Dev")!])])
    let pass = await Harness([listing(), listing(unowned: [unownedKey("cg-other")!])])

    guard case .invalid = await collide.controller.create(form("dev"), templates: [ubuntu]) else {
      Issue.record("CG-Dev must collide with dev")
      return
    }
    #expect(collide.runs.isEmpty)

    #expect(await pass.controller.create(form("dev"), templates: [ubuntu]) == .started)
    let process = await pass.cli.process(at: 0)
    #expect(pass.runs == [.create(expectedSpec("dev"))])
    process.exit(code: 0)
    await pass.task(for: "dev")?.value
  }

  @Test func aMachineThatAppearedInTheFreshReadIsADuplicate() async {
    let harness = await Harness([listing(), listing(instance("dev"))])

    let outcome = await harness.controller.create(form("dev"), templates: [ubuntu])

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.name])
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func aFailedFreshReadStillSendsTheCreateBecauseTheAgentAndLimaRefuseAnExistingInstance() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing()), .failure(.nonZeroExit(code: 1, output: ["boom"]))]
    }

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.create(expectedSpec("dev"))])
    process.exit(code: 0)
    await harness.task(for: "dev")?.value
  }

  // MARK: Running

  @Test func aPassingCreateSendsTheSpecShowsACreatingRowAndKeepsTheRunHandle() async throws {
    let harness = await Harness([listing(instance("old")), listing(instance("old"))])

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)

    let key = harness.key("dev")
    #expect(harness.controller.operations[key]?.kind == .create)
    #expect(harness.controller.records[key]?.kind == .create)
    #expect(harness.controller.failures[key] == nil)
    #expect(harness.controller.rows().map(\.name.rawValue) == ["old", "dev"])
    #expect(harness.controller.rows().map(\.display) == [.stopped, .creating])
    #expect(harness.controller.rows().last?.instance == nil)

    let process = await harness.cli.process(at: 0)
    #expect(process.command == .create(expectedSpec("dev")))
    await harness.wait { harness.controller.activeRuns[key] != nil }
    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .busy)
    #expect(harness.runs.count == 1)

    process.send("downloading image")
    await harness.wait { harness.controller.records[key]?.texts == ["downloading image"] }

    process.exit(code: 0)
    await harness.task(for: "dev")?.value
    #expect(harness.controller.activeRuns[key] == nil)
  }

  @Test func theCreatingRowGivesWayToTheListedMachineWithoutDuplicates() async {
    let harness = await Harness([listing(), listing(), listing(instance("dev", .other(rawStatus: "Creating")))])
    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)

    await harness.controller.refreshNow()

    #expect(harness.controller.rows().map(\.id) == [harness.key("dev")])
    #expect(harness.controller.rows().map(\.display) == [.creating])
    #expect(harness.controller.rows().first?.instance != nil)

    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "dev")?.value
  }

  @Test func aSuccessfulCreateEndsAsAStoppedMachineWithTheOutputKept() async {
    let harness = await Harness([listing(), listing(), listing(instance("dev", .stopped))])
    harness.cli.configure { $0.scriptedRuns = [[.output("done"), .exited(code: 0)]] }

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)
    await harness.task(for: "dev")?.value

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.records[harness.key("dev")]?.outcome == .succeeded)
    #expect(harness.controller.records[harness.key("dev")]?.texts == ["done"])
  }

  @Test func aFailedCreateKeepsLimasOutputVerbatimAndLeavesNoRow() async {
    let harness = await Harness([listing(), listing(), listing()])
    let output = ["downloading", "FATA[0003] disk image is corrupt", "  indented as Lima wrote it"]
    harness.cli.configure { $0.scriptedRuns = [output.map(ProcessEvent.output) + [.exited(code: 1)]] }

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)
    await harness.task(for: "dev")?.value

    let key = harness.key("dev")
    let failure = harness.controller.failures[key]
    #expect(failure?.kind == .create)
    #expect(failure?.cause == .exited(code: 1))
    #expect(failure?.outputTail == output)
    #expect(harness.controller.records[key]?.texts == output)
    #expect(harness.controller.records[key]?.outcome == failure.map(MachineOperationOutcome.failed))
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().isEmpty)
    #expect(harness.controller.activeRuns.isEmpty)
  }

  @Test func aLaunchFailureIsRecordedAsAFailure() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.scriptedRuns = [[.launchFailed(reason: "agent unreachable")]] }

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)
    await harness.task(for: "dev")?.value

    #expect(harness.controller.failures[harness.key("dev")]?.cause == .launchFailed(reason: "agent unreachable"))
    #expect(harness.controller.rows().isEmpty)
  }

  @Test func aNewCreateReplacesTheEarlierFailureAndRecordOfTheName() async {
    let harness = await Harness([listing(), listing(), listing()])
    harness.cli.configure { $0.scriptedRuns = [[.output("first"), .exited(code: 1)], []] }
    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)
    await harness.task(for: "dev")?.value
    #expect(harness.controller.failures[harness.key("dev")] != nil)

    #expect(await harness.controller.create(form("dev"), templates: [ubuntu]) == .started)

    #expect(harness.controller.failures[harness.key("dev")] == nil)
    #expect(harness.controller.records[harness.key("dev")]?.texts == [])
    await harness.cli.process(at: 1).exit(code: 0)
    await harness.task(for: "dev")?.value
  }

  @Test func differentNamesCreateInParallel() async {
    let harness = await Harness()

    #expect(await harness.controller.create(form("a"), templates: [ubuntu]) == .started)
    #expect(await harness.controller.create(form("b"), templates: [ubuntu]) == .started)

    #expect(harness.controller.rows().map(\.name.rawValue) == ["a", "b"])
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.cli.process(at: 1).exit(code: 0)
    await harness.task(for: "a")?.value
    await harness.task(for: "b")?.value
  }
}
