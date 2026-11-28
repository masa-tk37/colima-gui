import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineBannersPresentationTests {
  private typealias Data = PreviewMachineData

  private func banners(
    _ scenario: MachineControllerPreviews.Scenario, terminal: TerminalModelPreviews.Scenario = .available
  ) async -> MachineBannersPresentation {
    let controller = await MachineControllerPreviews.make(scenario).controller
    let model = await TerminalModelPreviews.make(terminal).model
    return MachineBannersPresentation(controller: controller, terminal: model)
  }

  // MARK: Notices

  @Test func aCancelledCreateShowsItsNotice() async {
    let shown = await banners(.createCancelled)
    #expect(shown.notice == MachineNoticeBanner(Data.createCancelledNotice))
    #expect(shown.notice?.message.contains(Data.creating.rawValue) == true)
    #expect(shown.shellFailure == nil)
  }

  @Test func aSavedEditNamesTheMachineAndTheNextStart() {
    let message = MachineNoticeBanner(.editSaved(Data.running)).message
    #expect(message.contains(Data.running.rawValue))
    #expect(message.contains("next time"))
  }

  @Test func dismissingTheNoticeRemovesTheBanner() async {
    let controller = await MachineControllerPreviews.make(.createCancelled).controller
    let model = await TerminalModelPreviews.make(.available).model
    controller.dismissNotice()
    #expect(MachineBannersPresentation(controller: controller, terminal: model).notice == nil)
  }

  @Test(arguments: [
    MachineControllerPreviews.Scenario.mixed, .creating, .createCancelRequested, .earlierSession, .pendingDeleteRunning,
  ])
  func otherScenariosShowNoBanner(scenario: MachineControllerPreviews.Scenario) async {
    let shown = await banners(scenario)
    #expect(shown.notice == nil)
    #expect(shown.shellFailure == nil)
  }

  // MARK: Shell failures

  @Test func aMissingTerminalOffersTheSettings() async throws {
    let banner = try #require(await banners(.mixed, terminal: .shellApplicationNotFound).shellFailure)
    #expect(banner.offersSettings)
    #expect(banner.detail == nil)
    #expect(banner.title.contains(Data.running.rawValue))
  }

  @Test func aDeniedAutomationNamesWhereToAllowIt() async throws {
    let banner = try #require(await banners(.mixed, terminal: .shellAutomationDenied).shellFailure)
    #expect(!banner.offersSettings)
    #expect(banner.message.contains("Privacy & Security › Automation"))
  }

  @Test func anyOtherFailureKeepsTheToolsTextUnchanged() async throws {
    let banner = try #require(await banners(.mixed, terminal: .shellFailed).shellFailure)
    guard case .failed(let detail) = Data.shellFailed.error else {
      Issue.record("expected a failed launch")
      return
    }
    #expect(banner.detail == detail)
    #expect(!banner.offersSettings)
  }

  @Test func eachCauseHasItsOwnMessage() {
    let messages = [
      Data.shellApplicationNotFound, Data.shellAutomationDenied, Data.shellFailed,
    ].map { ShellFailureBanner($0).message }
    #expect(Set(messages).count == 3)
  }

  @Test func aFailureWithNoToolTextShowsNoDetail() {
    let failure = ShellLaunchFailure(machine: Data.running, error: .failed(detail: ""))
    #expect(ShellFailureBanner(failure).detail == nil)
  }

  @Test func dismissingTheFailureRemovesTheBanner() async {
    let controller = await MachineControllerPreviews.make(.mixed).controller
    let model = await TerminalModelPreviews.make(.shellFailed).model
    model.dismissLaunchFailure()
    #expect(MachineBannersPresentation(controller: controller, terminal: model).shellFailure == nil)
  }

  @Test func aFailedCreateWithNoRowShowsLimasOutput() async throws {
    let shown = await banners(.createFailed)
    let banner = try #require(shown.createFailure)
    #expect(banner.failure.name == Data.creating)
    #expect(banner.title.contains(Data.creating.rawValue))
    #expect(banner.failure.outputTail == Data.createFailureOutput)
  }

  @Test func onlyTheNewestFailedCreateIsShown() async throws {
    let scene = await MachineControllerPreviews.make(.createFailed)
    let model = await TerminalModelPreviews.make(.available).model
    scene.cli.configure { $0.runs = [.exits(code: 1, lines: Data.createFailureOutput)] }
    let templates = (try? await scene.cli.listTemplates()) ?? []
    let input = MachineFormInput(name: "later", templateID: "ubuntu", cpus: "2", memoryGiB: "4", diskGiB: "50")
    _ = await scene.controller.create(input, templates: templates)
    await PreviewSettle.until("the second create failure was kept") { scene.controller.failures.count == 2 }

    let shown = MachineBannersPresentation(controller: scene.controller, terminal: model)
    #expect(shown.createFailure?.failure.name.rawValue == "later")
    scene.controller.dismissFailure(for: try #require(shown.createFailure).failure.name)
    let next = MachineBannersPresentation(controller: scene.controller, terminal: model)
    #expect(next.createFailure?.failure.name == Data.creating)
  }

  @Test func aFailedOperationOnAListedMachineShowsNoBanner() async {
    #expect(await banners(.startFailed).createFailure == nil)
  }

  @Test func aFailedCreateWhoseMachineIsListedShowsNoBanner() async throws {
    let scene = await MachineControllerPreviews.make(.createFailed)
    let model = await TerminalModelPreviews.make(.available).model
    let listed = Data.listing(Data.mixedListing.machines + [Data.instance(Data.creating, runState: .stopped)])
    scene.cli.configure { $0.listing = .success(listed) }
    await scene.controller.refreshNow()
    #expect(MachineBannersPresentation(controller: scene.controller, terminal: model).createFailure == nil)
  }

  @Test func dismissingACreateFailureRemovesTheBanner() async {
    let controller = await MachineControllerPreviews.make(.createFailed).controller
    let model = await TerminalModelPreviews.make(.available).model
    controller.dismissFailure(for: Data.creating)
    #expect(MachineBannersPresentation(controller: controller, terminal: model).createFailure == nil)
  }

  // MARK: Confirmations

  @Test func theDeleteConfirmationForARunningMachineSaysItIsForceStopped() async throws {
    let request = try #require(await MachineControllerPreviews.make(.pendingDeleteRunning).controller.pendingConfirmation)
    #expect(request.isShown(on: .window))
    #expect(request.confirmRole == .destructive)
    #expect(request.message.contains("force-stopped"))
    #expect(request.message.contains("lost"))
  }

  @Test func theDeleteConfirmationForAStoppedMachineOnlySaysTheDataIsLost() async throws {
    let request = try #require(await MachineControllerPreviews.make(.pendingDeleteStopped).controller.pendingConfirmation)
    #expect(request.confirmRole == .destructive)
    #expect(request.message.contains("lost"))
    #expect(!request.message.contains("force-stopped"))
  }

  @Test func theMemoryWarningShowsTheFiguresAndIsNotDestructive() async throws {
    let request = try #require(await MachineControllerPreviews.make(.pendingMemoryWarning).controller.pendingConfirmation)
    #expect(request.isShown(on: .window))
    #expect(request.confirmRole == .standard)
    #expect(request.message.contains("8 GiB"))
    #expect(request.message.contains("6 GiB"))
  }

  @Test func approvingOrDismissingTheConfirmationConsumesIt() async throws {
    let controller = await MachineControllerPreviews.make(.pendingDeleteStopped).controller
    controller.dismissConfirmation()
    #expect(controller.pendingConfirmation == nil)
  }

  @Test func theEarlierSessionScenarioHasNothingPendingToConfirm() async {
    let controller = await MachineControllerPreviews.make(.earlierSession).controller
    #expect(controller.pendingConfirmation == nil)
    #expect(controller.notice == nil)
  }
}
