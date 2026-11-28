import Foundation
import Observation
import Testing

@testable import ColimaCore

private let running = VMObservation.present(instance(running: true))
private let stopped = VMObservation.present(instance(running: false))

private let allFound = ToolchainStatus(
  colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:])
private let qemuMissing = ToolchainStatus(
  colima: .found(path: "/opt/homebrew/bin/colima"),
  missingByVMType: [.qemu: ["qemu-img", "qemu-system-aarch64"]])
private let colimaMissing = ToolchainStatus(
  colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:])

private let qemuSpec = VMCreateSpec(
  resources: VMResourceSettings(cpus: 4, memoryGiB: 4, diskGiB: 50), vmType: .qemu)

private func makePlan() -> RecreatePlan {
  guard
    case .success(let plan) = RecreatePlan.make(
      spec: qemuSpec, currentVMType: .vz, toolchain: allFound)
  else {
    fatalError("fixture plan must be valid")
  }
  return plan
}

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let date = ManualDate()
  let controller: VMController
  let plan = makePlan()

  /// The first observation is consumed by the initial lookup; later entries serve the operation's reads.
  init(observations: [Result<VMObservation, ColimaCLIError>]) async {
    let date = date
    controller = VMController(cli: cli, files: files, now: { date.now })
    cli.configure { $0.listDefault = observations }
    await controller.redetectToolchain()
  }

  var runs: [VMCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  var preflightCount: Int { cli.calls.filter { $0 == .preflight }.count }

  func finish() async {
    await controller.operationTask?.value
  }

  func requestAndConfirm() async {
    let result = await controller.requestRecreate(plan)
    #expect(result == .confirmationRequested)
    let id = controller.pendingConfirmation!.id
    #expect(controller.confirm(id: id) == .started)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMControllerRecreateTests {

  // MARK: before confirmation

  @Test func requestingCreatesAWindowConfirmationAndRunsNothing() async {
    let harness = await Harness(observations: [.success(running)])
    let callsBefore = harness.cli.calls.count

    let result = await harness.controller.requestRecreate(harness.plan)

    #expect(result == .confirmationRequested)
    let request = harness.controller.pendingConfirmation
    #expect(request?.intent == .recreateVM(harness.plan))
    #expect(request?.origin == .window)
    #expect(harness.runs.isEmpty)
    #expect(harness.cli.calls.dropFirst(callsBefore) == [.preflight])
    #expect(harness.controller.activeOperation == nil)
  }

  @Test func theConfirmationStatesWhatIsLost() async {
    let harness = await Harness(observations: [.success(running)])
    _ = await harness.controller.requestRecreate(harness.plan)

    let message = harness.controller.pendingConfirmation?.message ?? ""
    for phrase in [
      "containers", "images", "volumes", "are lost", "other than the VM type", "return to their defaults",
    ] {
      #expect(message.contains(phrase), "missing: \(phrase)")
    }
    #expect(harness.controller.pendingConfirmation?.confirmLabel.isEmpty == false)
  }

  @Test func aMissingExecutableFoundByTheLookupRejectsWithoutASlotOrADisplayChange() async {
    let harness = await Harness(observations: [.success(running)])
    let gate = ArrivalGate()
    harness.cli.configure {
      $0.toolchain = qemuMissing
      $0.beforePreflightReturns = gate.pass
    }
    let preflightsBefore = harness.preflightCount

    let request = Task { await harness.controller.requestRecreate(harness.plan) }
    await gate.waitForArrivals(1)
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.displayState == .running)
    gate.open()
    let result = await request.value

    #expect(
      result
        == .rejected(
          .missingExecutables(vmType: .qemu, missing: ["qemu-img", "qemu-system-aarch64"])))
    #expect(harness.preflightCount == preflightsBefore + 1)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.displayState == .running)
    #expect(harness.runs.isEmpty)
  }

  @Test func theLookupUpdatesTheToolchainForTheSettingsScreen() async {
    let harness = await Harness(observations: [.success(running)])
    harness.cli.configure { $0.toolchain = qemuMissing }

    _ = await harness.controller.requestRecreate(harness.plan)

    #expect(harness.controller.toolchain == qemuMissing)
  }

  @Test func anOperationStartingDuringTheLookupReturnsBusyAndCreatesNoRequest() async {
    let harness = await Harness(observations: [.success(stopped), .success(running)])
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforePreflightReturns = gate.pass }

    let request = Task { await harness.controller.requestRecreate(harness.plan) }
    await gate.waitForArrivals(1)
    harness.controller.start()
    #expect(harness.controller.activeOperation?.kind == .start)
    gate.open()
    let result = await request.value

    #expect(result == .busy)
    #expect(harness.controller.pendingConfirmation == nil)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()
    #expect(harness.runs == [.start])
  }

  @Test func requestingWhileAnOperationRunsReturnsBusyWithoutLookingUp() async {
    let harness = await Harness(observations: [.success(stopped), .success(running)])
    harness.controller.start()
    let preflightsBefore = harness.preflightCount

    let result = await harness.controller.requestRecreate(harness.plan)

    #expect(result == .busy)
    #expect(harness.preflightCount == preflightsBefore)
    #expect(harness.controller.pendingConfirmation == nil)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()
  }

  @Test func aPlanForTheCurrentVMTypeIsRejected() async {
    let harness = await Harness(observations: [.success(running)])
    let same = RecreatePlan(spec: qemuSpec, currentVMType: .qemu)

    let result = await harness.controller.requestRecreate(same)

    #expect(result == .rejected(.sameVMType))
    #expect(harness.controller.pendingConfirmation == nil)
  }

  @Test func aMissingColimaRejectsInsteadOfAskingForConfirmation() async {
    let harness = await Harness(observations: [.success(running)])
    harness.cli.configure { $0.toolchain = colimaMissing }

    let result = await harness.controller.requestRecreate(harness.plan)

    #expect(result == .rejected(.missingExecutables(vmType: .qemu, missing: ["colima"])))
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.runs.isEmpty)
  }

  // MARK: approval

  @Test func approvalTakesTheSlotAtPreflightAndShowsStopping() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(running),
    ])

    await harness.requestAndConfirm()

    #expect(harness.controller.activeOperation?.kind == .recreate)
    #expect(harness.controller.activeOperation?.stage == .preflight)
    #expect(harness.controller.displayState == .stopping)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.dockerAvailability == .vmBusy(.stopping))

    let delete = await harness.cli.process(at: 0)
    delete.exit(code: 0)
    let create = await harness.cli.process(at: 1)
    create.exit(code: 0)
    await harness.finish()
  }

  @Test func approvalRunsPreflightDeleteVerifyCreateThenReadsAndStreamsEveryStage() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(running),
    ])
    let callsBefore = harness.cli.calls.count

    _ = await harness.controller.requestRecreate(harness.plan)
    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)

    let delete = await harness.cli.process(at: 0)
    #expect(harness.controller.activeOperation?.stage == .deleting)
    #expect(harness.controller.displayState == .stopping)
    delete.send("deleting instance")
    delete.exit(code: 0)

    let create = await harness.cli.process(at: 1)
    #expect(harness.controller.activeOperation?.stage == .creating)
    #expect(harness.controller.displayState == .starting)
    #expect(harness.controller.latestRecord?.texts == ["deleting instance"])
    create.send("creating instance")
    create.exit(code: 0)
    await harness.finish()

    #expect(
      harness.cli.calls.dropFirst(callsBefore)
        == [
          .preflight, .preflight, .run(.delete), .listDefault, .run(.create(qemuSpec)),
          .listDefault,
        ])
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.observation == running)
    #expect(harness.controller.lastRecreatePlan == harness.plan)
    #expect(harness.controller.lastCreatedSpec == qemuSpec)
  }

  @Test func aMissingExecutableAfterApprovalStopsBeforeDelete() async {
    let harness = await Harness(observations: [.success(running)])
    _ = await harness.controller.requestRecreate(harness.plan)
    harness.cli.configure { $0.toolchain = qemuMissing }

    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .recreate, stage: .preflight,
          cause: .missingExecutables(.qemu, ["qemu-img", "qemu-system-aarch64"]), outputLines: []))
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.lastRecreatePlan == harness.plan)
  }

  @Test func colimaDisappearingAfterApprovalStopsBeforeDelete() async {
    let harness = await Harness(observations: [.success(running)])
    _ = await harness.controller.requestRecreate(harness.plan)
    harness.cli.configure { $0.toolchain = colimaMissing }

    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(harness.controller.lastFailure?.kind == .recreate)
    #expect(harness.controller.lastFailure?.stage == .preflight)
  }

  // MARK: activeCreateSpec

  @Test func theActiveCreateSpecIsTheNewSpecThroughoutARecreateAndClearedAfterwards() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(running),
    ])
    #expect(harness.controller.activeCreateSpec == nil)
    _ = await harness.controller.requestRecreate(harness.plan)
    #expect(harness.controller.activeCreateSpec == nil)

    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    #expect(harness.controller.activeCreateSpec == qemuSpec)

    let delete = await harness.cli.process(at: 0)
    #expect(harness.controller.activeCreateSpec == qemuSpec)
    delete.exit(code: 0)
    let create = await harness.cli.process(at: 1)
    #expect(harness.controller.activeCreateSpec == qemuSpec)
    create.exit(code: 0)
    await harness.finish()

    #expect(harness.controller.activeCreateSpec == nil)
  }

  @Test func theActiveCreateSpecIsClearedWhenARecreateFails() async {
    let harness = await Harness(observations: [.success(running), .success(running)])
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)]] }

    await harness.requestAndConfirm()
    #expect(harness.controller.activeCreateSpec == qemuSpec)
    await harness.finish()

    #expect(harness.controller.lastFailure?.stage == .deleting)
    #expect(harness.controller.activeCreateSpec == nil)
  }

  // MARK: delete stage

  @Test func aFailedDeleteKeepsTheStageOutputAndPlanAndDoesNotCreate() async {
    let harness = await Harness(observations: [.success(running), .success(running)])
    harness.cli.configure { $0.scriptedRuns = [[.output("cannot remove disk"), .exited(code: 1)]] }

    await harness.requestAndConfirm()
    await harness.finish()

    #expect(harness.runs == [.delete])
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .recreate, stage: .deleting, cause: .exited(code: 1),
          outputLines: ["cannot remove disk"]))
    #expect(harness.controller.lastRecreatePlan == harness.plan)
    #expect(harness.controller.observation == running)
    #expect(harness.controller.activeOperation == nil)
  }

  @Test func aDeleteThatFailsAfterTheVMWasRemovedReflectsTheAbsentState() async {
    let harness = await Harness(observations: [.success(running), .success(.absent)])
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)]] }

    await harness.requestAndConfirm()
    await harness.finish()

    #expect(harness.runs == [.delete])
    #expect(harness.controller.observation == .absent)
    #expect(harness.controller.lastFailure?.stage == .deleting)
  }

  @Test func aDefaultRowThatRemainsAfterDeleteExitsZeroFailsTheStageAndDoesNotCreate() async {
    let harness = await Harness(observations: [.success(running), .success(running)])
    harness.cli.configure { $0.scriptedRuns = [[.output("deleted"), .exited(code: 0)]] }

    await harness.requestAndConfirm()
    await harness.finish()

    #expect(harness.runs == [.delete])
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .recreate, stage: .deleting, cause: .stillPresentAfterDelete,
          outputLines: ["deleted"]))
    #expect(harness.controller.lastCreatedSpec == nil)
  }

  @Test func anUnreadableListAfterDeleteDoesNotCreateEither() async {
    let harness = await Harness(observations: [.success(running), .failure(.timedOut)])
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 0)]] }

    await harness.requestAndConfirm()
    await harness.finish()

    #expect(harness.runs == [.delete])
    #expect(harness.controller.lastFailure?.stage == .deleting)
    #expect(harness.controller.lastFailure?.cause == .deleteNotConfirmed)
  }

  @Test func theDeleteStageCannotBeAbortedEvenAfterTheDelay() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(running),
    ])
    await harness.requestAndConfirm()
    let delete = await harness.cli.process(at: 0)

    harness.date.advance(by: VMOperationProgress.abortDelay + 60)
    harness.controller.abortOperation()
    await Task.yield()

    #expect(delete.terminateCount == 0)
    #expect(harness.controller.activeOperation?.stage == .deleting)
    delete.exit(code: 0)
    let create = await harness.cli.process(at: 1)
    create.exit(code: 0)
    await harness.finish()
    #expect(harness.controller.lastFailure == nil)
  }

  // MARK: create stage

  @Test func aFailedCreateLeavesACreatingFailureAnAbsentVMAndThePlan() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(.absent),
    ])
    harness.cli.configure {
      $0.scriptedRuns = [
        [.output("deleted"), .exited(code: 0)], [.output("boom"), .exited(code: 1)],
      ]
    }

    await harness.requestAndConfirm()
    await harness.finish()

    #expect(harness.runs == [.delete, .create(qemuSpec)])
    #expect(harness.controller.lastFailure?.kind == .recreate)
    #expect(harness.controller.lastFailure?.stage == .creating)
    #expect(harness.controller.lastFailure?.cause == .exited(code: 1))
    #expect(harness.controller.lastFailure?.outputTail == ["deleted", "boom"])
    #expect(harness.controller.observation == .absent)
    #expect(harness.controller.lastRecreatePlan == harness.plan)
  }

  // MARK: exclusion

  @Test func everyOtherOperationIsRefusedWhileTheRecreateRuns() async {
    let harness = await Harness(observations: [
      .success(running), .success(.absent), .success(running),
    ])
    await harness.requestAndConfirm()
    let delete = await harness.cli.process(at: 0)
    let preflightsBefore = harness.preflightCount
    let runsBefore = harness.runs.count

    harness.controller.start()
    harness.controller.create(qemuSpec)
    harness.controller.requestStop(from: .window)
    harness.controller.requestRestart()
    let result = await harness.controller.requestRecreate(harness.plan)

    #expect(result == .busy)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.preflightCount == preflightsBefore)
    #expect(harness.runs.count == runsBefore)
    #expect(harness.controller.activeOperation?.kind == .recreate)

    delete.exit(code: 0)
    let create = await harness.cli.process(at: 1)
    create.exit(code: 0)
    await harness.finish()
  }

  @Test func approvingAfterAnotherOperationTookTheSlotConsumesTheRequestAndRunsNothing() async {
    let harness = await Harness(observations: [.success(stopped), .success(running)])
    _ = await harness.controller.requestRecreate(harness.plan)
    let id = harness.controller.pendingConfirmation!.id
    harness.controller.start()

    let outcome = harness.controller.confirm(id: id)

    guard case .rejectedBusy = outcome else {
      Issue.record("expected rejectedBusy, got \(outcome)")
      return
    }
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.confirm(id: id) == .notPending)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()
    #expect(harness.runs == [.start])
  }

  @Test func theNextOperationClearsTheRecreateFailure() async {
    let harness = await Harness(observations: [
      .success(running), .success(running), .success(running),
    ])
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)]] }
    await harness.requestAndConfirm()
    await harness.finish()
    #expect(harness.controller.lastFailure != nil)

    harness.controller.requestStop(from: .window)
    #expect(harness.controller.lastFailure != nil)
    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    #expect(harness.controller.lastFailure == nil)
    let process = await harness.cli.process(at: 1)
    process.exit(code: 0)
    await harness.finish()
  }
}
