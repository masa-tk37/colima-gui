import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SettingsAndUsagePreviewScenarioTests {
  // MARK: Settings

  @Test func theFormOfARunningVMOffersSave() async {
    let scene = await VMSettingsModelPreviews.make(.save)
    #expect(scene.settings.primaryAction == .save)
    #expect(scene.settings.unappliedFields.isEmpty)
    #expect(scene.settings.cpusText == "2")
    #expect(scene.settings.vmType == .vz)
  }

  @Test func aSettingsFileAheadOfTheRunningVMMarksTheUnappliedFields() async {
    let scene = await VMSettingsModelPreviews.make(.saveWithUnappliedChanges)
    #expect(scene.settings.unappliedFields == [.cpu, .memory])
  }

  @Test func recreateIsOfferedWhenTheTypeDiffers() async {
    let scene = await VMSettingsModelPreviews.make(.recreate)
    #expect(scene.settings.primaryAction == .recreate)
    #expect(scene.settings.vmType == .qemu)
    #expect(scene.settings.missingExecutables(for: .qemu).isEmpty)
  }

  @Test func missingExecutablesAreListedAndRefuseTheRecreate() async {
    let scene = await VMSettingsModelPreviews.make(.recreateMissingExecutables)
    #expect(scene.settings.missingExecutables(for: .krunkit) == ["krunkit"])
    #expect(scene.settings.missingExecutables(for: .qemu).isEmpty)

    let rejected = await VMSettingsModelPreviews.make(.recreateRejected)
    #expect(
      rejected.submitResult
        == .recreateRejected(.missingExecutables(vmType: .krunkit, missing: ["krunkit"])))
    #expect(rejected.controller.pendingConfirmation == nil)
  }

  @Test func anAbsentVMOffersCreateAndTheDataDiskNoticeFollowsTheController() async {
    let create = await VMSettingsModelPreviews.make(.create)
    #expect(create.settings.primaryAction == .create)
    #expect(!create.controller.dataDiskMayRemain)

    let notice = await VMSettingsModelPreviews.make(.createWithDataDiskNotice)
    #expect(notice.settings.primaryAction == .create)
    #expect(notice.controller.dataDiskMayRemain)
  }

  @Test func theUnavailableActionsCarryTheirReason() async {
    let unknown = await VMSettingsModelPreviews.make(.unavailableUnknownState)
    guard case .unavailable(let reason) = unknown.settings.primaryAction else {
      Issue.record("expected an unavailable action")
      return
    }
    #expect(reason.contains("Could not check the VM state"))

    let unreadable = await VMSettingsModelPreviews.make(.unavailableVMTypeUnreadable)
    #expect(unreadable.settings.primaryAction == .unavailable(reason: "The VM type state file was not found."))
  }

  @Test func submittedInvalidInputLeavesFieldErrors() async {
    let scene = await VMSettingsModelPreviews.make(.fieldErrors)
    guard case .invalid(let errors) = scene.submitResult else {
      Issue.record("expected an invalid result, got \(String(describing: scene.submitResult))")
      return
    }
    #expect(Set(errors.map(\.field)) == [.cpu, .memory, .disk])
    #expect(scene.settings.fieldErrors == errors)
  }

  @Test func saveOutcomesAndFailures() async {
    let restart = await VMSettingsModelPreviews.make(.savedRestartRequired)
    #expect(restart.submitResult == .saved(.restartRequired))

    let stopped = await VMSettingsModelPreviews.make(.saveWhileStopped)
    #expect(stopped.settings.primaryAction == .save)

    let failed = await VMSettingsModelPreviews.make(.saveFailed)
    guard case .failed(let reason) = failed.submitResult else {
      Issue.record("expected a failed result, got \(String(describing: failed.submitResult))")
      return
    }
    #expect(reason.contains("Operation not permitted"))
  }

  @Test func aSettingsFileThatCannotBeReadShowsDefaultsWithTheReason() async {
    let scene = await VMSettingsModelPreviews.make(.loadFailed)
    #expect(scene.settings.loadFailureReason?.contains("Permission denied") == true)
  }

  @Test func aRunningOperationRefusesTheSubmit() async {
    let scene = await VMSettingsModelPreviews.make(.operationInProgress)
    #expect(scene.controller.activeOperation != nil)
    #expect(await scene.settings.submit() == .busy)
  }

  // MARK: Usage

  @Test func aRunningVMShowsHistoryWithGapsInBothSeries() async {
    let scene = await VMUsageMonitorPreviews.make(.runningWithGaps)
    #expect(scene.monitor.state == .sampling)
    for series in [scene.monitor.cpu, scene.monitor.memory] {
      #expect(series.points.count == 60)
      #expect(series.points.indices.filter { series.points[$0].value == nil } == [12, 13, 40])
    }
    #expect(Date().timeIntervalSince(scene.monitor.cpu.points[59].time) < 5)
  }

  @Test func theScreensOwnRunContinuesTheHistoryWithAMeasuredSample() async throws {
    let scene = await VMUsageMonitorPreviews.make(.runningWithoutGaps)
    let task = Task { await scene.monitor.run() }
    defer { task.cancel() }
    await PreviewSettle.until("the first live round was recorded") {
      scene.monitor.cpu.points.count == 61
    }
    let last = try #require(scene.monitor.cpu.points.last)
    #expect((34...36).contains(try #require(last.value)))
    #expect(scene.monitor.memory.points.last?.value != nil)
  }

  @Test func aSeriesWithoutGapsHasEveryValue() async {
    let scene = await VMUsageMonitorPreviews.make(.runningWithoutGaps)
    #expect(scene.monitor.cpu.points.allSatisfy { $0.value != nil })
    #expect(scene.monitor.memory.points.allSatisfy { $0.value != nil })
  }

  @Test func eachStateThatCannotSampleExplainsWhy() async {
    let reasons: [VMUsageMonitorPreviews.Scenario: String] = [
      .stopped: "Usage is unavailable because the VM is stopped.",
      .absent: "Usage is unavailable because the VM has not been created.",
      .colimaMissing: "Colima was not found.",
      .operationInProgress: "Usage is unavailable because the VM is busy with an operation.",
    ]
    for (scenario, reason) in reasons {
      let scene = await VMUsageMonitorPreviews.make(scenario)
      #expect(scene.monitor.state == .unavailable(reason: reason), "\(scenario)")
    }
    let unknown = await VMUsageMonitorPreviews.make(.unknown)
    guard case .unavailable(let text) = unknown.monitor.state else {
      Issue.record("expected an unavailable state")
      return
    }
    #expect(text.hasPrefix("Could not check the VM state"))
    #expect(await VMUsageMonitorPreviews.make(.runningNoSamplesYet).monitor.cpu.points.isEmpty)
  }
}
