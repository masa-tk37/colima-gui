import Foundation
import Testing

@testable import ColimaCore

private let instance = VMInstance(
  runState: .running, arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30,
  runtime: "docker")
private let running = VMObservation.present(instance)
private let stopped = VMObservation.present(
  VMInstance(
    runState: .stopped(rawStatus: "Stopped"), arch: "aarch64", cpus: 2, memoryBytes: 2 << 30,
    diskBytes: 100 << 30, runtime: "docker"))

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

private let ok: [ProcessEvent] = [.exited(code: 0)]
private let failed: [ProcessEvent] = [.output("boom"), .exited(code: 1)]

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let controller: VMController
  let plan = makePlan()

  /// The first observation is consumed by the initial lookup; later entries serve the operations' reads in order.
  init(observations: [Result<VMObservation, ColimaCLIError>], runs: [[ProcessEvent]] = []) async {
    controller = VMController(cli: cli, files: files)
    cli.configure {
      $0.listDefault = observations
      $0.scriptedRuns = runs
    }
    await controller.redetectToolchain()
  }

  var runs: [VMCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func finish() async {
    await controller.operationTask?.value
  }

  func recreate() async {
    let result = await controller.requestRecreate(plan)
    #expect(result == .confirmationRequested)
    #expect(controller.confirm(id: controller.pendingConfirmation!.id) == .started)
    await finish()
  }

  func retryRecreate() async {
    let result = await controller.requestRetryRecreate()
    #expect(result == .confirmationRequested)
    #expect(controller.confirm(id: controller.pendingConfirmation!.id) == .started)
    await finish()
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMControllerRetryTests {

  // MARK: dataDiskMayRemain

  @Test func theMarkIsOffUntilADeleteStageFails() async {
    let harness = await Harness(observations: [.success(running)])
    #expect(harness.controller.dataDiskMayRemain == false)
  }

  @Test func aNonZeroDeleteSetsTheMark() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed])
    await harness.recreate()
    #expect(harness.controller.dataDiskMayRemain)
  }

  @Test func aDefaultRowThatRemainsAfterDeleteSetsTheMark() async {
    let harness = await Harness(observations: [.success(running), .success(running)], runs: [ok])
    await harness.recreate()
    #expect(harness.controller.lastFailure?.cause == .stillPresentAfterDelete)
    #expect(harness.controller.dataDiskMayRemain)
  }

  @Test func anUnreadableListAfterDeleteHasItsOwnCauseAndSetsTheMark() async {
    let harness = await Harness(observations: [.success(running), .failure(.timedOut)], runs: [ok])
    await harness.recreate()
    #expect(harness.controller.lastFailure?.stage == .deleting)
    #expect(harness.controller.lastFailure?.cause == .deleteNotConfirmed)
    #expect(harness.runs == [.delete])
    #expect(harness.controller.dataDiskMayRemain)
  }

  @Test func aCreateStageFailureDoesNotSetTheMark() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(.absent)], runs: [ok, failed])
    await harness.recreate()
    #expect(harness.controller.lastFailure?.stage == .creating)
    #expect(harness.controller.dataDiskMayRemain == false)
  }

  @Test func theMarkSurvivesTheNextOperationStartingAndAFailedCreate() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed, failed])
    await harness.recreate()
    #expect(harness.controller.dataDiskMayRemain)

    harness.controller.create(qemuSpec)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.dataDiskMayRemain)
    await harness.finish()

    #expect(harness.controller.lastFailure?.stage == .creating)
    #expect(harness.controller.dataDiskMayRemain)
  }

  // MARK: canRetryRecreate

  @Test func aRetryIsOfferedOnlyWhileTheDeleteStageFailureIsTheLastFailure() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed, failed])
    #expect(harness.controller.canRetryRecreate == false)

    await harness.recreate()
    #expect(harness.controller.canRetryRecreate)

    harness.controller.create(qemuSpec)
    #expect(harness.controller.canRetryRecreate == false)
    await harness.finish()

    #expect(harness.controller.dataDiskMayRemain)
    #expect(harness.controller.canRetryRecreate == false)
    #expect(await harness.controller.requestRetryRecreate() == .nothingToRetry)
  }

  @Test func aSuccessfulCreateClearsTheMark() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(running)], runs: [failed, ok])
    await harness.recreate()
    #expect(harness.controller.dataDiskMayRemain)

    harness.controller.create(qemuSpec)
    await harness.finish()

    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.dataDiskMayRemain == false)
  }

  @Test func aPollThatSeesThePresentVMClearsTheMarkOnlyOnceTheFailureIsNoLongerCurrent() async {
    let harness = await Harness(
      observations: [.success(running), .success(running), .success(running), .success(stopped)],
      runs: [failed, ok])
    await harness.recreate()
    #expect(harness.controller.observation == running)
    #expect(harness.controller.dataDiskMayRemain)

    await harness.controller.refreshNow()
    #expect(harness.controller.dataDiskMayRemain)

    harness.controller.requestStop(from: .window)
    #expect(harness.controller.confirm(id: harness.controller.pendingConfirmation!.id) == .started)
    await harness.finish()
    await harness.controller.refreshNow()

    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.dataDiskMayRemain == false)
  }

  // MARK: requestRetryRecreate

  @Test func retryRecreateAfterADeleteFailureReConfirmsAndRunsFromDeleteWithTheRetainedPlan() async
  {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(.absent), .success(running)],
      runs: [failed, ok, ok])
    await harness.recreate()
    #expect(harness.controller.lastFailure?.stage == .deleting)
    #expect(harness.controller.observation == .absent)
    let callsBefore = harness.cli.calls.count

    let result = await harness.controller.requestRetryRecreate()

    #expect(result == .confirmationRequested)
    #expect(harness.controller.pendingConfirmation?.intent == .recreateVM(harness.plan))
    #expect(harness.controller.pendingConfirmation?.origin == .window)
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.runs == [.delete])
    #expect(harness.cli.calls.dropFirst(callsBefore) == [.preflight])

    let id = harness.controller.pendingConfirmation!.id
    #expect(harness.controller.confirm(id: id) == .started)
    #expect(harness.controller.confirm(id: id) == .notPending)
    await harness.finish()

    #expect(harness.runs == [.delete, .delete, .create(qemuSpec)])
    #expect(
      harness.cli.calls.dropFirst(callsBefore)
        == [
          .preflight, .preflight, .run(.delete), .listDefault, .run(.create(qemuSpec)),
          .listDefault,
        ])
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.observation == running)
    #expect(harness.controller.dataDiskMayRemain == false)
  }

  @Test func retryRecreateCanFailAtDeleteAgainAndKeepsTheMark() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed, failed])
    await harness.recreate()

    await harness.retryRecreate()

    #expect(harness.runs == [.delete, .delete])
    #expect(harness.controller.lastFailure?.stage == .deleting)
    #expect(harness.controller.dataDiskMayRemain)
  }

  @Test func retryRecreateRejectsWhenTheRetainedPlansExecutablesAreMissingWithoutASlot() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed])
    await harness.recreate()
    harness.cli.configure { $0.toolchain = qemuMissing }
    let callsBefore = harness.cli.calls.count

    let result = await harness.controller.requestRetryRecreate()

    #expect(
      result
        == .rejected(
          .missingExecutables(vmType: .qemu, missing: ["qemu-img", "qemu-system-aarch64"])))
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.cli.calls.dropFirst(callsBefore) == [.preflight])
    #expect(harness.runs == [.delete])
  }

  @Test func retryRecreateRejectsWhenColimaItselfIsGone() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent)], runs: [failed])
    await harness.recreate()
    harness.cli.configure { $0.toolchain = colimaMissing }

    let result = await harness.controller.requestRetryRecreate()

    #expect(result == .rejected(.missingExecutables(vmType: .qemu, missing: ["colima"])))
    #expect(harness.controller.pendingConfirmation == nil)
  }

  @Test func retryRecreateHasNothingToRetryWithoutADeleteFailure() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(.absent)], runs: [ok, failed])

    #expect(await harness.controller.requestRetryRecreate() == .nothingToRetry)

    await harness.recreate()
    #expect(harness.controller.lastFailure?.stage == .creating)
    let callsBefore = harness.cli.calls.count
    #expect(await harness.controller.requestRetryRecreate() == .nothingToRetry)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.cli.calls.count == callsBefore)
  }

  @Test func retryRecreateReturnsBusyWhileAnOperationRunsAndCreatesNoRequest() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(.absent)], runs: [failed])
    await harness.recreate()
    harness.controller.create(qemuSpec)
    let callsBefore = harness.cli.calls.count

    let result = await harness.controller.requestRetryRecreate()

    #expect(result == .busy)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.cli.calls.count == callsBefore)
    let process = await harness.cli.process(at: 1)
    process.exit(code: 0)
    await harness.finish()
  }

  @Test func anOperationStartingDuringTheRetryLookupReturnsBusy() async {
    let harness = await Harness(
      observations: [.success(running), .success(.absent), .success(.absent)], runs: [failed])
    await harness.recreate()
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforePreflightReturns = gate.pass }

    let request = Task { await harness.controller.requestRetryRecreate() }
    await gate.waitForArrivals(1)
    #expect(harness.controller.activeOperation == nil)
    harness.controller.create(qemuSpec)
    gate.open()
    let result = await request.value

    #expect(result == .busy)
    #expect(harness.controller.pendingConfirmation == nil)
    let process = await harness.cli.process(at: 1)
    process.exit(code: 0)
    await harness.finish()
  }
}
