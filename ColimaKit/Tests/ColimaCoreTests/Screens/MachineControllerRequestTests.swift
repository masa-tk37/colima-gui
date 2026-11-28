import Foundation
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(
  _ name: String, _ runState: MachineRunState = .running, memoryGiB: Int64 = 4, extraBytes: Int64 = 0
) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: memoryGiB << 30 + extraBytes,
    diskBytes: 100 << 30, mounts: [], templateID: "ubuntu")
}

private func listing(_ instances: MachineInstance...) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: [])
}

private func vmInstance(running: Bool, memoryGiB: Int64) -> VMInstance {
  VMInstance(
    runState: running ? .running : .stopped(rawStatus: "Stopped"), arch: "aarch64", cpus: 2,
    memoryBytes: memoryGiB << 30, diskBytes: 100 << 30, runtime: "docker")
}

private let gibibyte: Int64 = 1 << 30
private let sixteenGiBMac = HostResources(cpus: 8, memoryGiB: 16, diskGiB: 500)

private let allFound = ToolchainStatus(
  colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:])

private func vmSpec(memoryGiB: Double, vmType: VMType) -> VMCreateSpec {
  VMCreateSpec(
    resources: VMResourceSettings(cpus: 2, memoryGiB: memoryGiB, diskGiB: 100), vmType: vmType)
}

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let vmCLI = FakeColimaCLI()
  let vm: VMController
  let controller: MachineController

  init(
    _ initial: LimaListing, listings: [LimaListing] = [],
    vm vmObservations: [Result<VMObservation, ColimaCLIError>] = [.success(.absent)],
    host: HostResources = sixteenGiBMac
  ) async {
    vm = VMController(cli: vmCLI, files: InMemoryColimaFileStore())
    vmCLI.configure { $0.listDefault = vmObservations }
    await vm.redetectToolchain()
    controller = MachineController(cli: cli, vmController: vm, host: host)
    cli.configure { $0.listInstances = ([initial] + listings).map { .success($0) } }
    await controller.refreshNow()
  }

  var runs: [MachineCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func key(_ name: String) -> MachineKey { machineName(name).key }

  func task(for name: String) -> Task<Void, Never>? { controller.operationTasks[key(name)] }

  func relist(_ listing: LimaListing) async {
    cli.configure { $0.listInstances = [.success(listing)] }
    await controller.refreshNow()
  }

  var pendingWarning: MemoryWarning? {
    if case .startMachine(_, let warning)? = controller.pendingConfirmation?.intent { warning } else { nil }
  }

  func holdSlot(_ name: String, kind: MachineOperationKind = .stop) {
    controller.operations[key(name)] = MachineOperationProgress(kind: kind, origin: .earlierSession(runID: UUID()))
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerRequestTests {

  // MARK: Start without a warning

  @Test func startBelowTheThresholdStartsAtOnceWithoutAConfirmation() async {
    let harness = await Harness(listing(instance("target", .stopped)))

    let outcome = harness.controller.requestStart(machineName("target"))

    #expect(outcome == .started)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.operations[harness.key("target")]?.kind == .start)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.start(machineName("target"))])
    process.exit(code: 0)
    await harness.task(for: "target")?.value
  }

  @Test func theThresholdItselfDoesNotWarnAndOneByteMoreDoes() async {
    let atThreshold = await Harness(
      listing(instance("target", .stopped, memoryGiB: 4)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    #expect(atThreshold.controller.requestStart(machineName("target")) == .started)
    let process = await atThreshold.cli.process(at: 0)
    process.exit(code: 0)
    await atThreshold.task(for: "target")?.value

    let overByOneByte = await Harness(
      listing(instance("target", .stopped, memoryGiB: 4, extraBytes: 1)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    #expect(overByOneByte.controller.requestStart(machineName("target")) == .confirmationRequested)
    #expect(overByOneByte.runs.isEmpty)
  }

  @Test func withoutAVMControllerTheDefaultVMAddsNothing() async {
    let cli = FakeLimaCLI()
    cli.configure { $0.listInstances = [.success(listing(instance("target", .stopped, memoryGiB: 12)))] }
    let controller = MachineController(cli: cli, host: sixteenGiBMac)
    await controller.refreshNow()

    #expect(controller.requestStart(machineName("target")) == .started)
    #expect(controller.pendingConfirmation == nil)
    let process = await cli.process(at: 0)
    process.exit(code: 0)
    await controller.operationTasks[machineName("target").key]?.value
  }

  // MARK: Start with a warning

  @Test func aWarningHoldsAStandardConfirmationShowingTheThreeFiguresAndRunsNothing() async {
    let harness = await Harness(
      listing(
        instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])

    let outcome = harness.controller.requestStart(machineName("target"))

    #expect(outcome == .confirmationRequested)
    let request = harness.controller.pendingConfirmation
    #expect(
      request?.intent
        == .startMachine(
          machineName("target"),
          warning: MemoryWarning(
            totalBytes: 20 * gibibyte, physicalBytes: 16 * gibibyte, thresholdBytes: 12 * gibibyte)))
    #expect(request?.confirmRole == .standard)
    #expect(request?.origin == .window)
    #expect(request?.message.contains("20 GiB") == true)
    #expect(request?.message.contains("16 GiB") == true)
    #expect(request?.message.contains("12 GiB") == true)
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
  }

  @Test func approvingStartsTheMachineAndConsumesTheRequestOnce() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let id = harness.controller.pendingConfirmation!.id

    #expect(harness.controller.confirm(id: id) == .started)

    #expect(harness.controller.pendingConfirmation == nil)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.start(machineName("target"))])
    #expect(harness.controller.confirm(id: id) == .notPending)
    #expect(harness.runs == [.start(machineName("target"))])
    process.exit(code: 0)
    await harness.task(for: "target")?.value
  }

  @Test func theTotalIsNotEvaluatedAgainAfterApproval() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let id = harness.controller.pendingConfirmation!.id

    // Still above the threshold: a second evaluation would hold a new request instead of starting.
    await harness.relist(listing(instance("a", .running), instance("b", .running), instance("target", .stopped)))
    #expect(harness.controller.confirm(id: id) == .started)

    #expect(harness.controller.pendingConfirmation == nil)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.start(machineName("target"))])
    process.exit(code: 0)
    await harness.task(for: "target")?.value
  }

  @Test func cancellingConsumesTheRequestAndChangesNothing() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let id = harness.controller.pendingConfirmation!.id
    let before = harness.controller.listing

    harness.controller.dismissConfirmation()

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.confirm(id: id) == .notPending)
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.listing == before)
  }

  @Test func anUnknownIdIsNotPendingAndLeavesTheHeldRequest() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let held = harness.controller.pendingConfirmation

    #expect(harness.controller.confirm(id: UUID()) == .notPending)

    #expect(harness.controller.pendingConfirmation == held)
    #expect(harness.runs.isEmpty)
  }

  @Test func approvingAfterTheSlotWasTakenIsRejectedAndConsumed() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let id = harness.controller.pendingConfirmation!.id
    harness.holdSlot("target", kind: .edit)

    guard case .rejectedBusy = harness.controller.confirm(id: id) else {
      Issue.record("expected rejectedBusy")
      return
    }

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
  }

  @Test func approvingAfterTheMachineIsNoLongerStoppedIsRejectedAndConsumed() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    let id = harness.controller.pendingConfirmation!.id
    await harness.relist(listing(instance("a", .running), instance("b", .running), instance("target", .running)))

    guard case .rejectedBusy = harness.controller.confirm(id: id) else {
      Issue.record("expected rejectedBusy")
      return
    }

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
  }

  @Test func aStartRequestThatDoesNotApplyHoldsNoConfirmation() async {
    let harness = await Harness(
      listing(instance("a", .running), instance("b", .running), instance("target", .stopped)),
      vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])

    #expect(harness.controller.requestStart(machineName("a")) == .notApplicable)
    #expect(harness.controller.requestStart(machineName("ghost")) == .notApplicable)
    harness.holdSlot("target", kind: .edit)
    #expect(harness.controller.requestStart(machineName("target")) == .busy)

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
  }

  // MARK: Which machines count

  private func total(
    _ machines: [MachineInstance], target: String = "target", host: HostResources = sixteenGiBMac
  ) async -> Int64? {
    let harness = await Harness(LimaListing(machines: machines, unownedMachineKeys: []), host: host)
    let outcome = harness.controller.requestStart(machineName(target))
    if outcome == .started {
      let process = await harness.cli.process(at: 0)
      process.exit(code: 0)
      await harness.task(for: target)?.value
    }
    return harness.pendingWarning?.totalBytes
  }

  @Test func onlyRunningMachinesAndMachinesBeingStartedCountTowardTheTotal() async {
    let target = instance("target", .stopped, memoryGiB: 4)

    #expect(await total([target, instance("other", .running, memoryGiB: 6)]) == nil)
    #expect(await total([target, instance("idle", .stopped, memoryGiB: 6), instance("odd", .other(rawStatus: "Paused"), memoryGiB: 6)]) == nil)
    #expect(await total([target, instance("bad", .broken(errors: ["no config"]), memoryGiB: 6)]) == nil)

    #expect(
      await total([target, instance("a", .running, memoryGiB: 6), instance("b", .running, memoryGiB: 6)])
        == 16 * gibibyte)
  }

  @Test func aMachineBeingStartedCountsEvenWhileListedAsStopped() async {
    let harness = await Harness(
      listing(
        instance("target", .stopped, memoryGiB: 4), instance("booting", .stopped, memoryGiB: 6),
        instance("other", .running, memoryGiB: 6)))
    harness.holdSlot("booting", kind: .start)

    #expect(harness.controller.requestStart(machineName("target")) == .confirmationRequested)
    #expect(harness.pendingWarning?.totalBytes == 16 * gibibyte)
  }

  @Test func aMachineBeingCreatedOrStoppedOrDeletedIsCountedOnlyByItsRunningState() async {
    let harness = await Harness(
      listing(
        instance("target", .stopped, memoryGiB: 4), instance("making", .stopped, memoryGiB: 6),
        instance("halting", .running, memoryGiB: 6), instance("going", .stopped, memoryGiB: 6)))
    harness.holdSlot("making", kind: .create)
    harness.holdSlot("halting", kind: .stop)
    harness.holdSlot("going", kind: .delete)

    #expect(harness.controller.requestStart(machineName("target")) == .started)
    let process = await harness.cli.process(at: 0)
    #expect(harness.runs == [.start(machineName("target"))])
    process.exit(code: 0)
    await harness.task(for: "target")?.value
  }

  @Test func aMachineRunningAndBeingStartedCountsOnce() async {
    let harness = await Harness(
      listing(instance("target", .stopped, memoryGiB: 4), instance("both", .running, memoryGiB: 6)))
    harness.holdSlot("both", kind: .start)

    #expect(harness.controller.requestStart(machineName("target")) == .started)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "target")?.value
  }

  // MARK: The default VM, driven through a real VMController

  private func harnessWithMachines(vm: [Result<VMObservation, ColimaCLIError>]) async -> Harness {
    await Harness(
      listing(instance("a", .running), instance("target", .stopped)),
      vm: vm)
  }

  private func defaultVMIsCounted(_ harness: Harness) -> Bool {
    let outcome = harness.controller.requestStart(machineName("target"))
    return outcome == .confirmationRequested
  }

  @Test func aRunningDefaultVMCountsAndAStoppedOrAbsentOneDoesNot() async {
    let running = await harnessWithMachines(vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    #expect(defaultVMIsCounted(running))
    #expect(running.pendingWarning?.totalBytes == 16 * gibibyte)

    let stopped = await harnessWithMachines(vm: [.success(.present(vmInstance(running: false, memoryGiB: 8)))])
    #expect(!defaultVMIsCounted(stopped))
    let stoppedProcess = await stopped.cli.process(at: 0)
    stoppedProcess.exit(code: 0)
    await stopped.task(for: "target")?.value

    let absent = await harnessWithMachines(vm: [.success(.absent)])
    #expect(!defaultVMIsCounted(absent))
    let absentProcess = await absent.cli.process(at: 0)
    absentProcess.exit(code: 0)
    await absent.task(for: "target")?.value
  }

  @Test func theDefaultVMCountsWhileARestartHasStoppedItAndBeforeItStarts() async {
    let harness = await harnessWithMachines(vm: [
      .success(.present(vmInstance(running: true, memoryGiB: 8))),
      .success(.present(vmInstance(running: false, memoryGiB: 8))),
      .success(.present(vmInstance(running: true, memoryGiB: 8))),
    ])
    harness.vm.requestRestart()
    #expect(harness.vm.confirm(id: harness.vm.pendingConfirmation!.id) == .started)
    #expect(defaultVMIsCounted(harness))
    harness.controller.dismissConfirmation()

    let stop = await harness.vmCLI.process(at: 0)
    stop.exit(code: 0)
    let start = await harness.vmCLI.process(at: 1)
    #expect(harness.vm.activeOperation?.kind == .restart)
    #expect(harness.vm.observation == .present(vmInstance(running: false, memoryGiB: 8)))

    #expect(defaultVMIsCounted(harness))
    #expect(harness.pendingWarning?.totalBytes == 16 * gibibyte)
    start.exit(code: 0)
    await harness.vm.operationTask?.value
  }

  @Test func theDefaultVMCountsWithTheNewSpecWhileItIsBeingCreated() async {
    let harness = await harnessWithMachines(vm: [.success(.absent)])
    harness.vm.create(vmSpec(memoryGiB: 8, vmType: .vz))

    #expect(harness.vm.activeOperation?.kind == .create)
    #expect(harness.vm.observation == .absent)
    #expect(defaultVMIsCounted(harness))
    #expect(harness.pendingWarning?.totalBytes == 16 * gibibyte)
    let process = await harness.vmCLI.process(at: 0)
    process.exit(code: 1)
    await harness.vm.operationTask?.value
  }

  @Test func aRecreateCountsTheNewSpecNotTheMemoryOfTheVMItReplaces() async {
    guard
      case .success(let toLarge) = RecreatePlan.make(
        spec: vmSpec(memoryGiB: 8, vmType: .qemu), currentVMType: .vz, toolchain: allFound),
      case .success(let toSmall) = RecreatePlan.make(
        spec: vmSpec(memoryGiB: 1, vmType: .qemu), currentVMType: .vz, toolchain: allFound)
    else {
      Issue.record("fixture plans must be valid")
      return
    }

    let growing = await harnessWithMachines(vm: [.success(.present(vmInstance(running: false, memoryGiB: 1)))])
    #expect(await growing.vm.requestRecreate(toLarge) == .confirmationRequested)
    _ = growing.vm.confirm(id: growing.vm.pendingConfirmation!.id)
    #expect(growing.vm.activeOperation?.kind == .recreate)
    #expect(defaultVMIsCounted(growing))
    #expect(growing.pendingWarning?.totalBytes == 16 * gibibyte)

    let shrinking = await harnessWithMachines(vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    #expect(await shrinking.vm.requestRecreate(toSmall) == .confirmationRequested)
    _ = shrinking.vm.confirm(id: shrinking.vm.pendingConfirmation!.id)
    #expect(shrinking.vm.activeOperation?.kind == .recreate)
    #expect(!defaultVMIsCounted(shrinking))
    let process = await shrinking.cli.process(at: 0)
    process.exit(code: 0)
    await shrinking.task(for: "target")?.value
  }

  @Test func startingAMachineNeverRunsOrChangesAnythingOnTheDefaultVM() async {
    let harness = await harnessWithMachines(vm: [.success(.present(vmInstance(running: true, memoryGiB: 8)))])
    _ = harness.controller.requestStart(machineName("target"))
    harness.controller.dismissConfirmation()

    #expect(harness.vmCLI.calls.filter { if case .run = $0 { true } else { false } }.isEmpty)
    #expect(harness.vm.activeOperation == nil)
    #expect(harness.vm.pendingConfirmation == nil)
  }

  // MARK: Delete

  @Test func deleteHoldsADestructiveConfirmationWithTheRunningStateAndRunsNothing() async {
    let harness = await Harness(listing(instance("idle", .stopped), instance("busy", .running)))

    #expect(harness.controller.requestDelete(machineName("idle")) == .confirmationRequested)
    let stopped = harness.controller.pendingConfirmation
    #expect(stopped?.intent == .deleteMachine(machineName("idle"), wasRunning: false))
    #expect(stopped?.confirmRole == .destructive)
    #expect(stopped?.message.contains("lost") == true)
    #expect(stopped?.message.contains("force-stopped") == false)

    #expect(harness.controller.requestDelete(machineName("busy")) == .confirmationRequested)
    let running = harness.controller.pendingConfirmation
    #expect(running?.intent == .deleteMachine(machineName("busy"), wasRunning: true))
    #expect(running?.confirmRole == .destructive)
    #expect(running?.message.contains("lost") == true)
    #expect(running?.message.contains("running") == true)
    #expect(running?.message.contains("force-stopped") == true)

    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
  }

  @Test func deleteIsAvailableForABrokenMachine() async {
    let harness = await Harness(listing(instance("bad", .broken(errors: ["no config"]))))

    #expect(harness.controller.requestDelete(machineName("bad")) == .confirmationRequested)
    #expect(
      harness.controller.pendingConfirmation?.intent == .deleteMachine(machineName("bad"), wasRunning: false))
  }

  @Test func aDeleteRequestThatDoesNotApplyHoldsNoConfirmation() async {
    let harness = await Harness(listing(instance("web", .running)))
    harness.holdSlot("web", kind: .start)

    #expect(harness.controller.requestDelete(machineName("web")) == .busy)
    #expect(harness.controller.requestDelete(machineName("ghost")) == .notApplicable)
    #expect(harness.controller.pendingConfirmation == nil)
  }

  @Test func approvingRunsOneForcedDeleteAndTheRowDisappears() async {
    let harness = await Harness(
      listing(instance("web", .running), instance("db", .stopped)),
      listings: [listing(instance("db", .stopped))])
    _ = harness.controller.requestDelete(machineName("web"))
    let id = harness.controller.pendingConfirmation!.id

    #expect(harness.controller.confirm(id: id) == .started)

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.operations[harness.key("web")]?.kind == .delete)
    #expect(harness.controller.rows().first { $0.name == machineName("web") }?.display == .deleting)
    #expect(harness.controller.confirm(id: id) == .notPending)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.runs == [.delete(machineName("web"))])
    #expect(harness.runs.first?.arguments.contains("--force") == true)
    #expect(harness.controller.rows().map(\.name) == [machineName("db")])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.failures.isEmpty)
  }

  @Test func aFailedDeleteKeepsLimasOutputAndTheRowFromTheRereadList() async {
    let harness = await Harness(listing(instance("web", .stopped)))
    _ = harness.controller.requestDelete(machineName("web"))
    _ = harness.controller.confirm(id: harness.controller.pendingConfirmation!.id)
    let process = await harness.cli.process(at: 0)
    process.send("FATA[0000] cannot remove")
    process.exit(code: 1)
    await harness.task(for: "web")?.value

    let failure = harness.controller.failures[harness.key("web")]
    #expect(failure?.kind == .delete)
    #expect(failure?.cause == .exited(code: 1))
    #expect(failure?.outputTail == ["FATA[0000] cannot remove"])
    #expect(harness.controller.rows().map(\.name) == [machineName("web")])
  }

  @Test func cancellingADeleteConsumesTheRequestAndChangesNothing() async {
    let harness = await Harness(listing(instance("web", .running)))
    _ = harness.controller.requestDelete(machineName("web"))
    let id = harness.controller.pendingConfirmation!.id
    let before = harness.controller.listing

    harness.controller.dismissConfirmation()

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.confirm(id: id) == .notPending)
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.controller.failures.isEmpty)
    #expect(harness.controller.listing == before)
  }

  @Test func approvingAfterTheSlotWasTakenIsRejectedConsumedAndDeletesNothing() async {
    let harness = await Harness(listing(instance("web", .stopped)))
    _ = harness.controller.requestDelete(machineName("web"))
    let id = harness.controller.pendingConfirmation!.id
    harness.holdSlot("web", kind: .start)

    guard case .rejectedBusy = harness.controller.confirm(id: id) else {
      Issue.record("expected rejectedBusy")
      return
    }

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
    #expect(harness.controller.operations[harness.key("web")]?.kind == .start)
  }

  @Test func approvingAfterTheRunningStateChangedIsRejectedInBothDirections() async {
    let wasRunning = await Harness(listing(instance("web", .running)))
    _ = wasRunning.controller.requestDelete(machineName("web"))
    let runningID = wasRunning.controller.pendingConfirmation!.id
    await wasRunning.relist(listing(instance("web", .stopped)))
    guard case .rejectedBusy = wasRunning.controller.confirm(id: runningID) else {
      Issue.record("expected rejectedBusy")
      return
    }
    #expect(wasRunning.controller.pendingConfirmation == nil)
    #expect(wasRunning.runs.isEmpty)

    let wasStopped = await Harness(listing(instance("web", .stopped)))
    _ = wasStopped.controller.requestDelete(machineName("web"))
    let stoppedID = wasStopped.controller.pendingConfirmation!.id
    await wasStopped.relist(listing(instance("web", .running)))
    guard case .rejectedBusy = wasStopped.controller.confirm(id: stoppedID) else {
      Issue.record("expected rejectedBusy")
      return
    }
    #expect(wasStopped.controller.pendingConfirmation == nil)
    #expect(wasStopped.runs.isEmpty)
  }

  @Test func approvingAfterTheMachineLeftTheListIsRejectedAndConsumed() async {
    let harness = await Harness(listing(instance("web", .stopped)))
    _ = harness.controller.requestDelete(machineName("web"))
    let id = harness.controller.pendingConfirmation!.id
    await harness.relist(listing())

    guard case .rejectedBusy = harness.controller.confirm(id: id) else {
      Issue.record("expected rejectedBusy")
      return
    }

    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
  }

  @Test func theConfirmationOfAnotherMachinesDeleteDoesNotTouchTheFirstOnesSlot() async {
    let harness = await Harness(listing(instance("web", .stopped), instance("db", .stopped)))
    _ = harness.controller.requestStart(machineName("web"))
    _ = harness.controller.requestDelete(machineName("db"))
    let id = harness.controller.pendingConfirmation!.id

    #expect(harness.controller.confirm(id: id) == .started)

    let first = await harness.cli.process(at: 0)
    let second = await harness.cli.process(at: 1)
    #expect(harness.runs == [.start(machineName("web")), .delete(machineName("db"))])
    first.exit(code: 0)
    second.exit(code: 0)
    await harness.task(for: "web")?.value
    await harness.task(for: "db")?.value
  }
}
