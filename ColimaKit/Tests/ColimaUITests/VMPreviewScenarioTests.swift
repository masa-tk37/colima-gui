import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMPreviewScenarioTests {
  // MARK: Observed states

  @Test func runningReadsAsRunningAndReady() async {
    let controller = await VMControllerPreviews.make(.running).controller
    #expect(controller.observation == .present(PreviewVMData.instance(running: true)))
    #expect(controller.displayState == .running)
    #expect(controller.dockerAvailability == .ready)
  }

  @Test func stoppedKeepsTheRawStatus() async {
    let stopped = await VMControllerPreviews.make(.stopped).controller
    #expect(stopped.observation == .present(PreviewVMData.instance(running: false)))
    #expect(stopped.dockerAvailability == .vmStopped)

    let broken = await VMControllerPreviews.make(.broken).controller
    guard case .present(let instance) = broken.observation else {
      Issue.record("expected a present VM")
      return
    }
    #expect(instance.runState == .stopped(rawStatus: "Broken"))
  }

  @Test func absentColimaMissingAndUnknown() async {
    let absent = await VMControllerPreviews.make(.absent).controller
    #expect(absent.dockerAvailability == .vmAbsent)

    let missing = await VMControllerPreviews.make(.colimaMissing).controller
    #expect(
      missing.dockerAvailability
        == .colimaMissing(searched: ["/opt/homebrew/bin", "/usr/local/bin"]))

    let unknown = await VMControllerPreviews.make(.unknown).controller
    guard case .unknown(let reason) = unknown.observation else {
      Issue.record("expected an unknown observation")
      return
    }
    #expect(reason.contains("error retrieving instances"))
  }

  // MARK: Operations in progress

  @Test func startingHoldsTheSlotWithOutputThatJustArrived() async throws {
    let controller = await VMControllerPreviews.make(.starting).controller
    let operation = try #require(controller.activeOperation)
    #expect(operation.kind == .start)
    #expect(operation.stage == .starting)
    #expect(controller.latestRecord?.texts == PreviewVMData.startOutput)
    #expect((4...12).contains(Date().timeIntervalSince(operation.startedAt)))
    #expect(try #require(operation.lastOutputAt).timeIntervalSinceNow > -6)
    #expect(!operation.isAbortAvailable(at: Date()))
    #expect(controller.displayState == .starting)
    #expect(controller.dockerAvailability == .vmBusy(.starting))
  }

  @Test func stoppingAndCreatingAreDistinctOperations() async throws {
    let stoppingController = await VMControllerPreviews.make(.stopping).controller
    let stopping = try #require(stoppingController.activeOperation)
    #expect(stopping.kind == .stop)
    #expect(stopping.stage == .stopping)
    #expect(stoppingController.latestRecord?.texts == PreviewVMData.stopOutput)

    let creatingController = await VMControllerPreviews.make(.creating).controller
    let creating = try #require(creatingController.activeOperation)
    #expect(creating.kind == .create)
    #expect(creating.stage == .creating)
    #expect(creatingController.latestRecord?.texts == PreviewVMData.createOutput)
  }

  @Test func aLongWaitWithNoOutputIsNotYetAbortable() async throws {
    let controller = await VMControllerPreviews.make(.startingNoOutputYet).controller
    let operation = try #require(controller.activeOperation)
    #expect(controller.latestRecord?.lines.isEmpty == true)
    #expect(operation.lastOutputAt == nil)
    #expect((11...20).contains(Date().timeIntervalSince(operation.stageStartedAt)))
    #expect(!operation.isAbortAvailable(at: Date()))
  }

  @Test func silenceForTenSecondsOrMoreWhileStillBelowTheAbortDelay() async throws {
    let operation = try #require(
      await VMControllerPreviews.make(.startingSilentForAWhile).controller.activeOperation)
    let silence = try #require(operation.lastOutputAt).distance(to: Date())
    #expect((39...50).contains(silence))
    #expect((94...105).contains(Date().timeIntervalSince(operation.stageStartedAt)))
    #expect(!operation.isAbortAvailable(at: Date()))
  }

  @Test func anOperationPastThreeMinutesOffersAnAbortThatWorks() async throws {
    let scene = await VMControllerPreviews.make(.startingAbortable)
    let operation = try #require(scene.controller.activeOperation)
    #expect(operation.isAbortAvailable(at: Date()))

    scene.controller.abortOperation()
    await PreviewSettle.until("abort recorded") { scene.controller.lastFailure != nil }
    #expect(scene.controller.lastFailure?.cause == .aborted)
    #expect(scene.controller.activeOperation == nil)
  }

  @Test func anAbortedStartLeavesTheAbortAsTheFailure() async throws {
    let controller = await VMControllerPreviews.make(.startAborted).controller
    let failure = try #require(controller.lastFailure)
    #expect(failure.kind == .start)
    #expect(failure.cause == .aborted)
    #expect(failure.outputTail == PreviewVMData.startOutput)
  }

  // MARK: Failures

  @Test func aFailedStartIsRetainedWithItsOutputTail() async throws {
    let controller = await VMControllerPreviews.make(.startFailed).controller
    let failure = try #require(controller.lastFailure)
    #expect(failure.kind == .start)
    #expect(failure.stage == .starting)
    #expect(failure.cause == .exited(code: 1))
    #expect(failure.outputTail == PreviewVMData.startFailureOutput)
    #expect(controller.activeOperation == nil)
    #expect(!controller.dataDiskMayRemain)
  }

  @Test func aFailedCreateIsRetainedAtTheCreatingStage() async throws {
    let controller = await VMControllerPreviews.make(.createFailed).controller
    let failure = try #require(controller.lastFailure)
    #expect(failure.kind == .create)
    #expect(failure.stage == .creating)
    #expect(failure.cause == .exited(code: 1))
    #expect(controller.observation == .absent)
  }

  @Test func aCreateOfAVMTypeWithMissingExecutablesFailsInPreflight() async throws {
    let controller = await VMControllerPreviews.make(.createFailedMissingExecutables).controller
    let failure = try #require(controller.lastFailure)
    #expect(failure.stage == .preflight)
    #expect(failure.cause == .missingExecutables(.qemu, ["qemu-img", "qemu-system-aarch64"]))
  }

  @Test func aFailedDeleteStageLeavesTheDataDiskFlagOnAnAbsentVM() async throws {
    let controller = await VMControllerPreviews.make(.dataDiskMayRemain).controller
    let failure = try #require(controller.lastFailure)
    #expect(failure.kind == .recreate)
    #expect(failure.stage == .deleting)
    #expect(controller.dataDiskMayRemain)
    #expect(controller.observation == .absent)
    #expect(controller.dockerAvailability == .vmAbsent)
  }

  @Test func aRefusedRetryOfTheRecreateCarriesItsReason() async throws {
    let scene = await VMControllerPreviews.make(.dataDiskMayRemainRetryRefused)
    #expect(
      scene.retryResult
        == .rejected(
          .missingExecutables(vmType: .qemu, missing: ["qemu-img", "qemu-system-aarch64"])))
    #expect(scene.controller.dataDiskMayRemain)
    #expect(scene.controller.pendingConfirmation == nil)

    let plain = await VMControllerPreviews.make(.dataDiskMayRemain)
    #expect(plain.retryResult == nil)
  }

  // MARK: Pending confirmations

  @Test func eachPendingConfirmationBelongsToTheSurfaceThatRaisedIt() async throws {
    let window = try #require(
      await VMControllerPreviews.make(.pendingStopFromWindow).controller.pendingConfirmation)
    #expect(window.intent == .stopVM)
    #expect(window.isShown(on: .window))
    #expect(!window.isShown(on: .menuBar))

    let menuBar = try #require(
      await VMControllerPreviews.make(.pendingStopFromMenuBar).controller.pendingConfirmation)
    #expect(menuBar.intent == .stopVM)
    #expect(menuBar.isShown(on: .menuBar))
    #expect(!menuBar.isShown(on: .window))

    let restart = try #require(
      await VMControllerPreviews.make(.pendingRestart).controller.pendingConfirmation)
    #expect(restart.intent == .restartVM)

    let recreate = try #require(
      await VMControllerPreviews.make(.pendingRecreate).controller.pendingConfirmation)
    guard case .recreateVM(let plan) = recreate.intent else {
      Issue.record("expected a recreate intent")
      return
    }
    #expect(plan.currentVMType == .qemu)
    #expect(plan.spec.vmType == .vz)
  }

  @Test func aRefusedApprovalKeepsTheReasonAndConsumesTheRequest() async throws {
    let scene = await VMControllerPreviews.make(.confirmationRejected)
    let reason = try #require(scene.rejectionReason)
    #expect(reason.contains("Another VM operation is running"))
    #expect(scene.controller.pendingConfirmation == nil)
    #expect(scene.controller.activeOperation == nil)
  }

  @Test func theConfirmationSceneHandsTheAnswerBackToItsOwner() async throws {
    let scene = await ConfirmationPreviews.make(.stopFromMenuBar)
    let request = try #require(scene.request)
    #expect(request.origin == .menuBar)
    #expect(scene.confirm(UUID()) == .notPending)
    scene.dismiss()

    let rejected = await ConfirmationPreviews.make(.approvalRejected)
    #expect(rejected.request == nil)
    #expect(rejected.rejectionReason != nil)

    let groups = try #require(await ConfirmationPreviews.make(.pruneVolumes).request).itemGroups
    #expect(groups.map(\.title) == ["Anonymous volumes", "Named volumes"])
  }

  // MARK: Ports

  @Test func theFakeUsageCounterProducesMeasurableSamples() async throws {
    let cli = PreviewColimaCLI()
    let first = try await cli.sampleUsage()
    let second = try await cli.sampleUsage()
    let percent = try #require(second.cpuPercent(since: first))
    #expect((34...36).contains(percent))
  }
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct EveryPreviewScenarioTests {
  @Test func everyScenarioReachesItsStateWithoutTimingOut() async {
    let before = PreviewSettle.timeouts.withLock { $0 }
    for scenario in VMControllerPreviews.Scenario.allCases {
      _ = await VMControllerPreviews.make(scenario)
    }
    for scenario in VMSettingsModelPreviews.Scenario.allCases {
      _ = await VMSettingsModelPreviews.make(scenario)
    }
    for scenario in VMUsageMonitorPreviews.Scenario.allCases {
      _ = await VMUsageMonitorPreviews.make(scenario)
    }
    for scenario in ContainerStorePreviews.Scenario.allCases {
      _ = await ContainerStorePreviews.make(scenario)
    }
    for scenario in StatsSessionPreviews.Scenario.allCases {
      _ = await StatsSessionPreviews.make(scenario)
    }
    for scenario in ImageStorePreviews.Scenario.allCases {
      _ = await ImageStorePreviews.make(scenario)
    }
    for scenario in VolumeStorePreviews.Scenario.allCases {
      _ = await VolumeStorePreviews.make(scenario)
    }
    for scenario in NetworkStorePreviews.Scenario.allCases {
      _ = await NetworkStorePreviews.make(scenario)
    }
    for scenario in ConfirmationPreviews.Scenario.allCases {
      _ = await ConfirmationPreviews.make(scenario)
    }
    for scenario in LogSessionPreviews.Scenario.allCases {
      let scene = await LogSessionPreviews.make(scenario)
      scene.runTask.cancel()
    }
    #expect(PreviewSettle.timeouts.withLock { $0 } == before)
  }
}
