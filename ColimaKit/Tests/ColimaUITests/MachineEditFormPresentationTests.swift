import Foundation
import Testing

@testable import ColimaCore
@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineEditFormPresentationTests {
  private typealias Data = PreviewMachineData

  private func instance(
    memoryBytes: Int64 = 4 << 30, diskBytes: Int64 = 100 << 30, mounts: [MachineMount] = []
  ) -> MachineInstance {
    MachineInstance(
      name: Data.stopped, runState: .stopped, cpus: 2, memoryBytes: memoryBytes, diskBytes: diskBytes,
      mounts: mounts, templateID: "ubuntu")
  }

  private func failure(_ errors: (MachineField, String)...) -> MachineEditOutcome {
    .invalid(MachineValidationFailure(fields: errors.map { MachineFieldError(field: $0.0, message: $0.1) }))
  }

  // MARK: Initial values

  @Test func startsFromTheMachinesResourcesAndShares() {
    let mounts = [MachineMount(path: "/Users/preview", writable: true), MachineMount(path: "/data", writable: false)]
    let form = MachineEditFormPresentation(instance: instance(mounts: mounts))
    #expect(form.input == MachineEditInput(cpus: "2", memoryGiB: "4", diskGiB: "100", mounts: mounts))
  }

  @Test func aFractionalMemoryKeepsItsDecimals() {
    #expect(MachineEditFormPresentation(instance: instance(memoryBytes: (2 << 30) - 1)).input.memoryGiB == "2")
    #expect(MachineEditFormPresentation(instance: instance(memoryBytes: 3 << 29)).input.memoryGiB == "1.5")
    #expect(MachineEditFormPresentation(instance: instance(memoryBytes: 1 << 30)).input.memoryGiB == "1")
    #expect(MachineEditFormPresentation(instance: instance(memoryBytes: (5 << 30) / 4)).input.memoryGiB == "1.25")
  }

  @Test func theDiskRoundsUpSoTheUnchangedValueIsNotAShrink() {
    let form = MachineEditFormPresentation(instance: instance(diskBytes: (100 << 30) + 1))
    #expect(form.input.diskGiB == "101")
  }

  // MARK: Form or guidance

  @Test func onlyAnEditableMachineShowsTheForm() {
    #expect(MachineEditFormPresentation.content(canEdit: true) == .form)
    #expect(MachineEditFormPresentation.content(canEdit: false) == .stopFirst)
  }

  // MARK: Shares

  @Test func addingFoldersAppendsThemAsReadOnly() {
    var form = MachineEditFormPresentation(instance: instance(mounts: [MachineMount(path: "/a", writable: true)]))
    form.addMounts(["/b", "/c"])
    #expect(form.input.mounts.map(\.path) == ["/a", "/b", "/c"])
    #expect(form.input.mounts.map(\.writable) == [true, false, false])
  }

  @Test func addingAFolderAlreadyListedKeepsOneRow() {
    var form = MachineEditFormPresentation(instance: instance(mounts: [MachineMount(path: "/a", writable: true)]))
    form.addMounts(["/a", "/b", "/b"])
    #expect(form.input.mounts.map(\.path) == ["/a", "/b"])
    #expect(form.input.mounts[0].writable)
  }

  @Test func togglingWritableChangesOnlyThatRow() {
    var form = MachineEditFormPresentation(
      instance: instance(mounts: [MachineMount(path: "/a", writable: true), MachineMount(path: "/b", writable: false)]))
    form.setWritable(true, at: 1)
    form.setWritable(false, at: 0)
    #expect(form.input.mounts == [MachineMount(path: "/a", writable: false), MachineMount(path: "/b", writable: true)])
  }

  @Test func togglingWritableKeepsAnInheritedGuestMountPoint() {
    var form = MachineEditFormPresentation(
      instance: instance(mounts: [MachineMount(path: "/a", writable: false, mountPoint: "/guest/a")]))
    form.setWritable(true, at: 0)
    #expect(form.input.mounts == [MachineMount(path: "/a", writable: true, mountPoint: "/guest/a")])
  }

  @Test func removingARowKeepsTheOthersInOrder() {
    var form = MachineEditFormPresentation(
      instance: instance(mounts: ["/a", "/b", "/c"].map { MachineMount(path: $0, writable: false) }))
    form.removeMount(at: 1)
    #expect(form.input.mounts.map(\.path) == ["/a", "/c"])
  }

  @Test func outOfRangeShareEditsAreIgnored() {
    var form = MachineEditFormPresentation(instance: instance(mounts: [MachineMount(path: "/a", writable: false)]))
    let before = form
    form.removeMount(at: 3)
    form.setWritable(true, at: -1)
    #expect(form == before)
  }

  // MARK: Outcomes and errors

  @Test func aStartedSaveClosesTheSheet() {
    var form = MachineEditFormPresentation(instance: instance())
    let closes = form.apply(.started, submitted: form.input)
    #expect(closes)
  }

  @Test func anInvalidOrBusyOrBlockedSaveKeepsTheSheetOpen() {
    var form = MachineEditFormPresentation(instance: instance())
    let outcomes: [MachineEditOutcome] = [failure((.cpu, "bad cpu")), .busy, .mustStopFirst]
    for outcome in outcomes {
      let closes = form.apply(outcome, submitted: form.input)
      #expect(!closes)
    }
  }

  @Test func eachErrorAppearsOnlyUnderItsOwnField() {
    var form = MachineEditFormPresentation(
      instance: instance(mounts: ["/a", "/b"].map { MachineMount(path: $0, writable: false) }))
    form.apply(
      failure((.cpu, "bad cpu"), (.disk, "bad disk 1"), (.disk, "bad disk 2"), (.mount(index: 1), "no folder")),
      submitted: form.input)
    #expect(form.errors(for: .cpu) == ["bad cpu"])
    #expect(form.errors(for: .disk) == ["bad disk 1", "bad disk 2"])
    #expect(form.errors(for: .memory).isEmpty)
    #expect(form.errors(for: .mount(index: 0)).isEmpty)
    #expect(form.errors(for: .mount(index: 1)) == ["no folder"])
    #expect(form.errors(for: .mount(index: 2)).isEmpty)
  }

  @Test func editingAFieldHidesItsErrorButNotTheOthers() {
    var form = MachineEditFormPresentation(instance: instance())
    form.apply(failure((.cpu, "bad cpu"), (.memory, "bad memory")), submitted: form.input)
    form.input.cpus = "3"
    #expect(form.errors(for: .cpu).isEmpty)
    #expect(form.errors(for: .memory) == ["bad memory"])
    form.input.cpus = "2"
    #expect(form.errors(for: .cpu) == ["bad cpu"])
  }

  @Test func aMountErrorFollowsItsPathWhenRowsShift() {
    var form = MachineEditFormPresentation(
      instance: instance(mounts: ["/a", "/b"].map { MachineMount(path: $0, writable: false) }))
    form.apply(failure((.mount(index: 1), "no folder")), submitted: form.input)
    form.removeMount(at: 0)
    #expect(form.errors(for: .mount(index: 0)).isEmpty)
    #expect(form.errors(for: .mount(index: 1)).isEmpty)
  }

  @Test func togglingWritableKeepsTheMountError() {
    var form = MachineEditFormPresentation(instance: instance(mounts: [MachineMount(path: "/a", writable: false)]))
    form.apply(failure((.mount(index: 0), "no folder")), submitted: form.input)
    form.setWritable(true, at: 0)
    #expect(form.errors(for: .mount(index: 0)) == ["no folder"])
  }

  @Test func aBusyOrBlockedResultClearsEarlierErrors() {
    var form = MachineEditFormPresentation(instance: instance())
    form.apply(failure((.cpu, "bad cpu")), submitted: form.input)
    form.apply(.busy, submitted: form.input)
    #expect(form.errors(for: .cpu).isEmpty)
  }

  // MARK: Saving

  @Test func aStartedSaveKeepsTheFormUpAndBlocksASecondSave() {
    var form = MachineEditFormPresentation(instance: instance())
    #expect(form.canSave)
    #expect(MachineEditFormPresentation.content(canEdit: false, saveStarted: form.saveStarted) == .stopFirst)
    form.apply(.started, submitted: form.input)
    #expect(!form.canSave)
    #expect(MachineEditFormPresentation.content(canEdit: false, saveStarted: form.saveStarted) == .form)
  }

  @Test func aRejectedSaveCanBeRetried() {
    var form = MachineEditFormPresentation(instance: instance())
    form.apply(failure((.cpu, "bad cpu")), submitted: form.input)
    #expect(form.canSave)
  }

  // MARK: Folder chooser

  @Test func aChosenFolderURLLosesItsTrailingSlash() {
    var form = MachineEditFormPresentation(instance: instance(mounts: [MachineMount(path: "/Volumes/data", writable: true)]))
    form.addMounts(folders: [
      URL(filePath: "/Volumes/data", directoryHint: .isDirectory),
      URL(filePath: "/Volumes/my docs", directoryHint: .isDirectory),
    ])
    #expect(form.input.mounts.map(\.path) == ["/Volumes/data", "/Volumes/my docs"])
    #expect(MachineEditFormPresentation.path(of: URL(filePath: "/", directoryHint: .isDirectory)) == "/")
  }

  // MARK: With the real controller

  private func controller(missing: Set<String> = []) async -> MachineController {
    let cli = PreviewLimaCLI()
    cli.configure { $0.listing = .success(Data.mixedListing) }
    let controller = MachineController(
      cli: cli, host: Data.host, homeDirectory: Data.homeDirectory, directoryExists: { !missing.contains($0) })
    await controller.refreshNow()
    return controller
  }

  private func form(for name: MachineName, in controller: MachineController) throws -> MachineEditFormPresentation {
    let instance = try #require(controller.machines?.first { $0.name == name })
    return MachineEditFormPresentation(instance: instance)
  }

  @Test func theSheetOpensOnlyForAStoppedIdleMachine() async {
    let controller = await controller()
    #expect(MachineEditFormPresentation.content(canEdit: controller.canEdit(Data.stopped)) == .form)
    #expect(MachineEditFormPresentation.content(canEdit: controller.canEdit(Data.running)) == .stopFirst)
  }

  @Test func aMachineWithAnOperationShowsTheGuidance() async {
    let controller = await MachineControllerPreviews.make(.starting).controller
    #expect(MachineEditFormPresentation.content(canEdit: controller.canEdit(Data.stopped)) == .stopFirst)
  }

  @Test func savingAValidChangeStartsTheEditAndCloses() async throws {
    let controller = await controller()
    var form = try form(for: Data.stopped, in: controller)
    form.input.cpus = "4"
    let outcome = controller.saveEdit(Data.stopped, form.input)
    #expect(outcome == .started)
    let closes = form.apply(outcome, submitted: form.input)
    #expect(closes)
    #expect(!controller.canEdit(Data.stopped))
    #expect(MachineEditFormPresentation.content(canEdit: controller.canEdit(Data.stopped), saveStarted: form.saveStarted) == .form)
  }

  @Test func eachBadResourceShowsUnderItsOwnField() async throws {
    let controller = await controller()
    var form = try form(for: Data.stopped, in: controller)
    form.input.cpus = "abc"
    form.input.memoryGiB = "99999"
    form.input.diskGiB = "0"
    form.apply(controller.saveEdit(Data.stopped, form.input), submitted: form.input)
    #expect(form.errors(for: .cpu).count == 1)
    #expect(form.errors(for: .memory).count == 1)
    #expect(form.errors(for: .disk).count == 1)
    #expect(form.errors(for: .mount(index: 0)).isEmpty)
  }

  @Test func shrinkingTheDiskShowsTheShrinkErrorUnderTheDisk() async throws {
    let controller = await controller()
    var form = try form(for: Data.stopped, in: controller)
    form.input.diskGiB = "50"
    form.apply(controller.saveEdit(Data.stopped, form.input), submitted: form.input)
    #expect(form.errors(for: .disk).count == 1)
    #expect(form.errors(for: .cpu).isEmpty && form.errors(for: .memory).isEmpty)
  }

  @Test func aMissingFolderShowsUnderItsOwnRow() async throws {
    let controller = await controller(missing: ["/gone"])
    var form = try form(for: Data.stopped, in: controller)
    form.addMounts(["/gone", "/Volumes/data"])
    form.apply(controller.saveEdit(Data.stopped, form.input), submitted: form.input)
    #expect(form.errors(for: .mount(index: 0)).isEmpty)
    #expect(form.errors(for: .mount(index: 1)).count == 1)
    #expect(form.errors(for: .mount(index: 2)).isEmpty)
  }

  @Test func relativeExpansionAndOverlappingPathsShowUnderTheirRows() async throws {
    let controller = await controller()
    var form = try form(for: Data.stopped, in: controller)
    form.addMounts(["relative", "/x/{{.Home}}", "/Users/preview/sub"])
    form.apply(controller.saveEdit(Data.stopped, form.input), submitted: form.input)
    #expect(form.errors(for: .mount(index: 0)).isEmpty)
    #expect(form.errors(for: .mount(index: 1)).count == 1)
    #expect(form.errors(for: .mount(index: 2)).count == 1)
    #expect(form.errors(for: .mount(index: 3)).count == 1)
  }

  // MARK: Preview scenarios

  @Test func thePreviewScenariosReachTheirStates() async throws {
    let stopped = await MachineEditSheetPreviewScenario.stopped.make()
    #expect(stopped.0.canEdit(stopped.1) && stopped.2 == nil)
    let running = await MachineEditSheetPreviewScenario.running.make()
    #expect(!running.0.canEdit(running.1))
    let busy = await MachineEditSheetPreviewScenario.operationInProgress.make()
    #expect(!busy.0.canEdit(busy.1))

    let fields = try #require(await MachineEditSheetPreviewScenario.fieldErrors.make().2)
    #expect(fields.errors(for: .cpu).count == 1 && fields.errors(for: .memory).count == 1)
    #expect(fields.errors(for: .disk).count == 1)

    let shrink = try #require(await MachineEditSheetPreviewScenario.diskShrink.make().2)
    #expect(shrink.errors(for: .disk).count == 1 && shrink.errors(for: .cpu).isEmpty)

    let mounts = try #require(await MachineEditSheetPreviewScenario.badMountPaths.make().2)
    #expect(mounts.input.mounts.count == 5)
    #expect(mounts.errors(for: .mount(index: 0)).isEmpty)
    #expect(mounts.errors(for: .mount(index: 1)).count == 1)
    #expect(mounts.errors(for: .mount(index: 2)).isEmpty)
    #expect(mounts.errors(for: .mount(index: 3)).count == 1)
    #expect(mounts.errors(for: .mount(index: 4)).count == 1)
  }
}
