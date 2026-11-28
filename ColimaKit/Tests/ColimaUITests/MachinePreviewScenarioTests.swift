import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachinePreviewScenarioTests {
  private typealias Data = PreviewMachineData

  private func controller(_ scenario: MachineControllerPreviews.Scenario) async -> MachineController {
    await MachineControllerPreviews.make(scenario).controller
  }

  private func row(_ name: MachineName, in controller: MachineController) -> MachineRow? {
    controller.rows().first { $0.name == name }
  }

  // MARK: The list

  @Test func noMachinesReadsAsAnEmptyListWithLimactlFound() async {
    let controller = await controller(.noMachines)
    #expect(controller.toolchain == PreviewLimaCLI.installedToolchain)
    #expect(controller.listing == Data.emptyListing)
    #expect(controller.rows().isEmpty)
  }

  @Test func limactlMissingKeepsTheSearchedFolders() async {
    let controller = await controller(.limactlMissing)
    #expect(controller.toolchain == .missing(searched: Data.limactlSearched))
    #expect(controller.listing == nil)
    #expect(!controller.canCreate)
  }

  @Test func aFailedReadKeepsLimasOutputWithoutAList() async {
    let controller = await controller(.listFailed)
    #expect(controller.listError == .nonZeroExit(code: 1, output: Data.listFailureOutput))
    #expect(controller.listing == nil)
  }

  @Test func theMixedListShowsRunningAndStoppedMachinesWithTheirDistributions() async {
    let rows = await controller(.mixed).rows()
    #expect(rows.map(\.name) == [Data.running, Data.stopped, Data.alpine])
    #expect(rows.map(\.display) == [.running, .stopped, .stopped])
    #expect(rows.map(\.distribution) == ["Ubuntu (latest)", "Debian 12", "Alpine Linux (latest)"])
  }

  @Test func aBrokenRowKeepsLimasErrors() async throws {
    let broken = try #require(row(Data.broken, in: await controller(.brokenRow)))
    guard case .broken(let errors) = broken.display else {
      Issue.record("expected a broken row")
      return
    }
    #expect(errors.count == 1)
    #expect(broken.distribution == nil)
  }

  // MARK: Operations

  @Test func aCreateShowsACreatingRowBeforeLimaListsTheMachine() async throws {
    let controller = await controller(.creating)
    let creating = try #require(row(Data.creating, in: controller))
    #expect(creating.display == .creating)
    #expect(creating.instance == nil)
    #expect(!creating.cancelRequested)
    #expect(controller.records[Data.creating.key]?.texts == Data.createOutput)
    #expect(controller.canCancelCreate(Data.creating))
  }

  @Test func aPendingCancelDisablesTheControlAndKeepsTheRow() async throws {
    let controller = await controller(.createCancelRequested)
    let creating = try #require(row(Data.creating, in: controller))
    #expect(creating.display == .creating)
    #expect(creating.cancelRequested)
    #expect(!controller.canCancelCreate(Data.creating))
    #expect(controller.notice == nil)
  }

  @Test func aCancelledCreateLeavesANoticeAndNoRow() async {
    let controller = await controller(.createCancelled)
    #expect(controller.notice == Data.createCancelledNotice)
    #expect(row(Data.creating, in: controller) == nil)
    #expect(controller.operations.isEmpty)
    #expect(controller.failures.isEmpty)
  }

  @Test func aStartHoldsTheSlotWithItsOutput() async throws {
    let controller = await controller(.starting)
    #expect(row(Data.stopped, in: controller)?.display == .starting)
    #expect(controller.records[Data.stopped.key]?.texts == Data.startOutput)
    #expect(controller.pendingConfirmation == nil)
  }

  @Test func aFailedStartKeepsTheOutputTailAndShowsTheListedState() async throws {
    let controller = await controller(.startFailed)
    let failure = try #require(controller.failures[Data.stopped.key])
    #expect(failure.kind == .start)
    #expect(failure.cause == .exited(code: 1))
    #expect(failure.outputTail == Data.startFailureOutput)
    #expect(row(Data.stopped, in: controller)?.display == .stopped)
  }

  @Test func earlierSessionOperationsFillTheirSlotsAndRows() async throws {
    let controller = await controller(.earlierSession)
    let creating = try #require(row(Data.creating, in: controller))
    #expect(creating.display == .creating)
    #expect(creating.instance == nil)
    #expect(row(Data.stopped, in: controller)?.display == .starting)
    for progress in controller.operations.values {
      guard case .earlierSession = progress.origin else {
        Issue.record("expected an earlier session's operation")
        return
      }
    }
  }

  // MARK: Confirmations

  @Test func theMemoryWarningScenarioHoldsTheFixedRequest() async throws {
    let request = try #require(await controller(.pendingMemoryWarning).pendingConfirmation)
    let fixed = Data.memoryWarningRequest
    #expect(request.intent == fixed.intent)
    #expect(request.confirmRole == .standard)
    #expect(fixed.confirmRole == .standard)
    #expect(request.origin == fixed.origin)
    #expect(request.itemGroups == fixed.itemGroups)
    guard case .startMachine(_, let warning) = fixed.intent else {
      Issue.record("expected a start request")
      return
    }
    #expect(warning.totalBytes == 8 << 30)
    #expect(warning.thresholdBytes == 6 << 30)
  }

  @Test func theDeleteScenariosHoldTheFixedRequestsForRunningAndStoppedMachines() async throws {
    let running = try #require(await controller(.pendingDeleteRunning).pendingConfirmation)
    #expect(running.intent == Data.deleteRunningRequest.intent)
    #expect(running.itemGroups == Data.deleteRunningRequest.itemGroups)
    #expect(running.confirmRole == .destructive)

    let stopped = try #require(await controller(.pendingDeleteStopped).pendingConfirmation)
    #expect(stopped.intent == Data.deleteStoppedRequest.intent)
    #expect(stopped.itemGroups == Data.deleteStoppedRequest.itemGroups)
  }

  // MARK: Shell

  @Test func theTerminalScenariosReachTheirStates() async {
    let available = await TerminalModelPreviews.make(.available).model
    #expect(available.availability == .available)
    #expect(available.lastLaunchFailure == nil)

    let missing = await TerminalModelPreviews.make(.terminalNotFound).model
    #expect(missing.availability == .notFound)
    #expect(missing.lastLaunchFailure == nil)
  }

  @Test func eachKindOfShellLaunchFailureIsReachedAndMatchesTheFixedValue() async {
    let expected: [(TerminalModelPreviews.Scenario, ShellLaunchFailure)] = [
      (.shellApplicationNotFound, Data.shellApplicationNotFound),
      (.shellAutomationDenied, Data.shellAutomationDenied),
      (.shellFailed, Data.shellFailed),
    ]
    for (scenario, fixed) in expected {
      let failure = await TerminalModelPreviews.make(scenario).model.lastLaunchFailure
      #expect(failure?.error == fixed.error)
      #expect(failure?.machine == fixed.machine)
    }
  }

  @Test func everyScenarioBuilds() async {
    for scenario in MachineControllerPreviews.Scenario.allCases {
      _ = await MachineControllerPreviews.make(scenario)
    }
    for scenario in TerminalModelPreviews.Scenario.allCases {
      _ = await TerminalModelPreviews.make(scenario)
    }
  }
}
