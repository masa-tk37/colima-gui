import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineListPresentationTests {
  private typealias Data = PreviewMachineData

  private func controller(_ scenario: MachineControllerPreviews.Scenario) async -> MachineController {
    await MachineControllerPreviews.make(scenario).controller
  }

  private func row(_ name: MachineName, in controller: MachineController) throws -> MachineRow {
    try #require(controller.rows().first { $0.name == name })
  }

  private func actions(_ name: MachineName, in controller: MachineController) throws -> MachineRowActionState {
    MachineRowActionState(row: try row(name, in: controller), controller: controller)
  }

  // MARK: Which screen

  @Test(arguments: [
    (MachineControllerPreviews.Scenario.noMachines, MachineListPresentation.Screen.noMachines),
    (.limactlMissing, .limactlMissing(searched: PreviewMachineData.limactlSearched)),
    (.listFailed, .readFailedWithoutList),
    (.mixed, .table),
    (.brokenRow, .table),
    (.creating, .table),
    (.createCancelRequested, .table),
    (.starting, .table),
    (.startFailed, .table),
  ])
  func eachScenarioPicksItsScreen(
    scenario: MachineControllerPreviews.Scenario, screen: MachineListPresentation.Screen
  ) async {
    let shown = MachineListPresentation(controller: await controller(scenario))
    #expect(shown.screen == screen)
  }

  @Test func beforeTheFirstReadTheScreenIsLoading() {
    let shown = MachineListPresentation(toolchain: nil, listing: nil, listError: nil, rows: [])
    #expect(shown.screen == .loading)
    #expect(shown.readFailure == nil)
  }

  @Test func theListWithNoReadFailureHasNoBanner() async {
    for scenario in [MachineControllerPreviews.Scenario.noMachines, .limactlMissing, .mixed, .creating] {
      #expect(MachineListPresentation(controller: await controller(scenario)).readFailure == nil)
    }
  }

  @Test func aFailedReadShowsLimasOutputAsItCame() async {
    let shown = MachineListPresentation(controller: await controller(.listFailed))
    #expect(shown.readFailure?.output == Data.listFailureOutput)
    #expect(shown.readFailure?.summary == MachineFailureCause.exited(code: 1).message)
    #expect(shown.rows.isEmpty)
  }

  @Test func aFailedReadKeepsTheLastListBelowTheBanner() async {
    let scene = await MachineControllerPreviews.make(.mixed)
    scene.cli.configure { $0.listing = .failure(.nonZeroExit(code: 2, output: ["first", "second"])) }
    await scene.controller.refreshNow()

    let shown = MachineListPresentation(controller: scene.controller)
    #expect(shown.screen == .table)
    #expect(shown.rows.map(\.name) == [Data.running, Data.stopped, Data.alpine])
    #expect(shown.readFailure?.output == ["first", "second"])
  }

  @Test func aLaunchFailureShowsItsReasonVerbatimAndNoSummary() {
    let shown = MachineListPresentation(
      toolchain: .found(path: "/opt/homebrew/bin/limactl"), listing: nil,
      listError: .launchFailed(reason: "posix_spawn: Permission denied"), rows: [])
    #expect(shown.screen == .readFailedWithoutList)
    #expect(shown.readFailure == MachineListPresentation.ReadFailure(summary: nil, output: ["posix_spawn: Permission denied"]))
  }

  @Test func aMissingLimactlWinsOverAListReadBefore() async {
    let scene = await MachineControllerPreviews.make(.mixed)
    scene.cli.configure {
      $0.toolchain = .missing(searched: ["/somewhere"])
      $0.listing = .failure(.limactlMissing)
    }
    await scene.controller.refreshNow()

    let shown = MachineListPresentation(controller: scene.controller)
    #expect(shown.screen == .limactlMissing(searched: ["/somewhere"]))
    #expect(!shown.canCreate)
    #expect(shown.readFailure == nil)
  }

  @Test func createIsOfferedOnlyWhileLimactlIsFound() async {
    #expect(MachineListPresentation(controller: await controller(.noMachines)).canCreate)
    #expect(!MachineListPresentation(controller: await controller(.limactlMissing)).canCreate)
  }

  // MARK: Cells

  @Test func aListedMachineShowsItsSpecInGiB() async throws {
    let controller = await controller(.mixed)
    let running = MachineRowCells(row: try row(Data.running, in: controller))
    #expect(running.name == "dev")
    #expect(running.distribution == (try row(Data.running, in: controller)).distribution)
    #expect(running.cpu == "2")
    #expect(running.memory == "4 GiB")
    #expect(running.disk == "100 GiB")

    let alpine = MachineRowCells(row: try row(Data.alpine, in: controller))
    #expect(alpine.memory == "1 GiB")
  }

  @Test func aCreatingRowWithNoInstanceShowsPlaceholdersNotZeros() async throws {
    let creating = MachineRowCells(row: try row(Data.creating, in: await controller(.creating)))
    #expect(creating.name == "fresh")
    #expect([creating.distribution, creating.cpu, creating.memory, creating.disk] == Array(repeating: "—", count: 4))
  }

  @Test func aBrokenRowShowsPlaceholdersNotZeros() async throws {
    let broken = MachineRowCells(row: try row(Data.broken, in: await controller(.brokenRow)))
    #expect([broken.distribution, broken.cpu, broken.memory, broken.disk] == Array(repeating: "—", count: 4))
    #expect(broken.state.tone == .attention)
  }

  @Test func aFractionalMemoryKeepsOneDecimal() {
    #expect(MachineRowCells.gibibytes(Int64(1536) << 20) == "1.5 GiB")
    #expect(MachineRowCells.gibibytes(0) == "—")
  }

  @Test func eachDisplayStateHasATone() {
    let tones: [(MachineDisplayState, MachineStatePresentation.Tone)] = [
      (.running, .running), (.stopped, .stopped),
      (.creating, .transitional), (.starting, .transitional), (.stopping, .transitional),
      (.deleting, .transitional), (.saving, .transitional),
      (.broken(errors: ["x"]), .attention), (.other(rawStatus: "Paused"), .attention),
    ]
    for (state, tone) in tones {
      #expect(MachineStatePresentation(state).tone == tone)
    }
  }

  @Test func anUnmodelledStatusIsShownVerbatim() {
    #expect(MachineStatePresentation(.other(rawStatus: "Paused")).label == "Paused")
  }

  // MARK: Row actions

  @Test func aRunningMachineOffersStopAndShell() async throws {
    let actions = try actions(Data.running, in: await controller(.mixed))
    #expect(actions.toggle == .stop(enabled: true))
    #expect(actions.shellEnabled)
    #expect(!actions.editEnabled)
    #expect(actions.deleteEnabled)
    #expect(actions.cancelCreate == .hidden)
  }

  @Test func aStoppedMachineOffersStartEditAndDelete() async throws {
    let actions = try actions(Data.stopped, in: await controller(.mixed))
    #expect(actions.toggle == .start(enabled: true))
    #expect(!actions.shellEnabled)
    #expect(actions.editEnabled)
    #expect(actions.deleteEnabled)
  }

  @Test func aCreatingMachineOffersOnlyCancel() async throws {
    let actions = try actions(Data.creating, in: await controller(.creating))
    #expect(actions.cancelCreate == .enabled)
    #expect(actions.toggle == .start(enabled: false))
    #expect(!actions.shellEnabled && !actions.editEnabled && !actions.deleteEnabled)
  }

  @Test func aRequestedCancelDisablesTheControl() async throws {
    let actions = try actions(Data.creating, in: await controller(.createCancelRequested))
    #expect(actions.cancelCreate == .disabled)
    #expect(!actions.deleteEnabled)
  }

  @Test func aStartingMachineDisablesEveryOperation() async throws {
    let actions = try actions(Data.stopped, in: await controller(.starting))
    #expect(actions.toggle == .start(enabled: false))
    #expect(!actions.shellEnabled && !actions.editEnabled && !actions.deleteEnabled)
    #expect(actions.cancelCreate == .hidden)
  }

  @Test func aFailedStartLeavesTheMachineStartableAgain() async throws {
    let actions = try actions(Data.stopped, in: await controller(.startFailed))
    #expect(actions.toggle == .start(enabled: true))
    #expect(actions.deleteEnabled)
  }

  @Test func aBrokenMachineCanOnlyBeDeleted() async throws {
    let actions = try actions(Data.broken, in: await controller(.brokenRow))
    #expect(actions.toggle == .start(enabled: false))
    #expect(!actions.shellEnabled && !actions.editEnabled)
    #expect(actions.deleteEnabled)
  }

  @Test func aStoppingMachineKeepsTheStopToggleDisabled() {
    let state = MachineRowActionState(
      display: .stopping,
      capabilities: MachineRowCapabilities(
        canStart: false, canStop: false, canDelete: false, canEdit: false, canOpenShell: false,
        canCancelCreate: false))
    #expect(state.toggle == .stop(enabled: false))
  }

  // MARK: Selection

  @Test func aSelectionResolvesToItsRowOrNothing() async throws {
    let rows = await controller(.mixed).rows()
    #expect(MachineListPresentation.selectedRow(Data.stopped.key, in: rows)?.name == Data.stopped)
    #expect(MachineListPresentation.selectedRow(Data.creating.key, in: rows) == nil)
    #expect(MachineListPresentation.selectedRow(nil, in: rows) == nil)
  }

  @Test func aNewCreatingRowTakesTheSelection() async throws {
    let before = await controller(.mixed).rows()
    let after = await controller(.creating).rows()
    let next = MachineListPresentation.selection(Data.running.key, afterRows: before, become: after)
    #expect(next == Data.creating.key)
  }

  @Test func aSelectionThatStillExistsStaysWhenRowsChange() async throws {
    let rows = await controller(.mixed).rows()
    #expect(MachineListPresentation.selection(Data.running.key, afterRows: rows, become: rows) == Data.running.key)
  }

  @Test func aSelectionWhoseRowVanishedIsCleared() async throws {
    let before = await controller(.creating).rows()
    let after = await controller(.createCancelled).rows()
    #expect(MachineListPresentation.selection(Data.creating.key, afterRows: before, become: after) == nil)
  }

  @Test func creatingRowsThatWereAlreadyThereDoNotStealTheSelection() async throws {
    let rows = await controller(.creating).rows()
    #expect(MachineListPresentation.selection(Data.running.key, afterRows: rows, become: rows) == Data.running.key)
  }

  // MARK: Detail pane

  @Test func noSelectedRowHasNoDetail() {
    #expect(MachineListPresentation.detail(for: nil, operationsAreEmpty: true) == .none)
  }

  @Test func aBrokenRowWithoutOperationsShowsLimasErrors() async throws {
    let broken = try row(Data.broken, in: await controller(.brokenRow))
    guard case .broken(let errors) = broken.display else {
      Issue.record("expected a broken row")
      return
    }
    #expect(
      MachineListPresentation.detail(for: broken, operationsAreEmpty: true)
        == .brokenErrors(Data.broken, errors))
    #expect(MachineListPresentation.detail(for: broken, operationsAreEmpty: false) == .operations(Data.broken))
  }

  @Test func anyOtherRowShowsTheOperationPanel() async throws {
    let running = try row(Data.running, in: await controller(.mixed))
    #expect(MachineListPresentation.detail(for: running, operationsAreEmpty: true) == .operations(Data.running))
  }
}
