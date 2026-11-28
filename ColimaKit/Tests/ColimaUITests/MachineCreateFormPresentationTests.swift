import Foundation
import Testing

@testable import ColimaCore
@testable import ColimaUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineCreateFormPresentationTests {
  private typealias Data = PreviewMachineData

  private func templates(_ ids: String...) -> [MachineTemplate] {
    ids.compactMap(MachineTemplate.init(id:))
  }

  private func loaded(_ ids: String...) -> MachineCreateFormPresentation {
    var form = MachineCreateFormPresentation()
    form.load(.success(ids.compactMap(MachineTemplate.init(id:))))
    return form
  }

  // MARK: Templates and defaults

  @Test func startsLoadingWithTheDefaultResourcesAndNothingToSubmit() {
    let form = MachineCreateFormPresentation()
    #expect(form.templates == .loading)
    #expect(form.input == MachineFormInput.defaults(firstTemplateID: nil))
    #expect(form.input.cpus == "2" && form.input.memoryGiB == "4")
    #expect(!form.canSubmit)
  }

  @Test func theLatestUbuntuIsTheDefaultWhenOffered() {
    let form = loaded("almalinux", "debian-12", "ubuntu", "ubuntu-24.04")
    #expect(form.input.templateID == "ubuntu")
    #expect(form.canSubmit)
  }

  @Test func theFirstTemplateIsTheDefaultWithoutUbuntu() {
    let form = loaded("debian-12", "fedora")
    #expect(form.input.templateID == "debian-12")
  }

  @Test func theOfferedListKeepsLimasOrder() {
    let form = loaded("fedora", "alpine", "ubuntu")
    #expect(form.offeredTemplates.map(\.id) == ["fedora", "alpine", "ubuntu"])
  }

  @Test func noTemplatesLeavesNothingSelectedAndNothingToSubmit() {
    let form = loaded()
    #expect(form.input.templateID == nil)
    #expect(form.hasNoTemplates)
    #expect(!form.canSubmit)
  }

  @Test func aFailedLoadKeepsTheErrorAndBlocksSubmit() {
    var form = MachineCreateFormPresentation()
    form.load(.failure(.limactlMissing))
    #expect(form.templates == .failed(.limactlMissing))
    #expect(form.loadFailureMessage != nil)
    #expect(!form.canSubmit)
  }

  @Test func aSuccessfulReloadKeepsWhatTheUserTypedAndTheirChoice() {
    var form = loaded("debian-12", "ubuntu")
    form.input.name = "dev2"
    form.input.cpus = "6"
    form.input.templateID = "debian-12"
    form.load(.success(templates("debian-12", "ubuntu")))
    #expect(form.input.name == "dev2" && form.input.cpus == "6")
    #expect(form.input.templateID == "debian-12")
  }

  @Test func aReloadWithoutTheChosenTemplateFallsBackToTheDefault() {
    var form = loaded("debian-12", "ubuntu")
    form.input.templateID = "debian-12"
    form.load(.success(templates("fedora", "ubuntu")))
    #expect(form.input.templateID == "ubuntu")
  }

  @Test func everyLoadFailureHasAMessage() {
    let failures: [LimaCLIError] = [
      .limactlMissing, .launchFailed(reason: "spawn failed"),
      .nonZeroExit(code: 1, output: ["fatal: no templates"]), .cancelled,
    ]
    for failure in failures {
      var form = MachineCreateFormPresentation()
      form.load(.failure(failure))
      #expect(form.loadFailureMessage?.isEmpty == false)
    }
    var form = MachineCreateFormPresentation()
    form.load(.failure(.launchFailed(reason: "spawn failed")))
    #expect(form.loadFailureMessage == "spawn failed")
    form.load(.failure(.nonZeroExit(code: 1, output: ["a", "b"])))
    #expect(form.loadFailureMessage == "a\nb")
  }

  // MARK: Submit state

  @Test func submittingDisablesTheCreateButton() {
    var form = loaded("ubuntu")
    #expect(form.canSubmit)
    form.isSubmitting = true
    #expect(!form.canSubmit)
  }

  @Test func aStartedCreateClosesTheSheet() {
    var form = loaded("ubuntu")
    form.input.name = "dev2"
    let closes = form.apply(.started, submitted: form.input)
    #expect(closes)
  }

  // MARK: Errors under their fields

  private func failure(_ errors: (MachineField, String)...) -> MachineCreateOutcome {
    .invalid(MachineValidationFailure(fields: errors.map { MachineFieldError(field: $0.0, message: $0.1) }))
  }

  @Test func eachErrorAppearsOnlyUnderItsOwnField() {
    var form = loaded("ubuntu")
    let closes = form.apply(
      failure((.name, "Enter a name."), (.cpu, "bad cpu"), (.disk, "bad disk 1"), (.disk, "bad disk 2")),
      submitted: form.input)
    #expect(!closes)
    #expect(form.errors(for: .name) == ["Enter a name."])
    #expect(form.errors(for: .cpu) == ["bad cpu"])
    #expect(form.errors(for: .disk) == ["bad disk 1", "bad disk 2"])
    #expect(form.errors(for: .memory).isEmpty)
    #expect(form.errors(for: .template).isEmpty)
  }

  @Test func editingAFieldHidesItsErrorButNotTheOthers() {
    var form = loaded("ubuntu")
    form.apply(failure((.name, "Enter a name."), (.cpu, "bad cpu")), submitted: form.input)
    form.input.name = "dev2"
    #expect(form.errors(for: .name).isEmpty)
    #expect(form.errors(for: .cpu) == ["bad cpu"])
  }

  @Test func restoringTheSubmittedValueShowsTheErrorAgain() {
    var form = loaded("ubuntu")
    form.apply(failure((.name, "Enter a name.")), submitted: form.input)
    form.input.name = "x"
    form.input.name = ""
    #expect(form.errors(for: .name) == ["Enter a name."])
  }

  @Test func theDistributionErrorFollowsTheSelection() {
    var form = loaded("debian-12", "ubuntu")
    form.apply(failure((.template, "Choose a distribution.")), submitted: form.input)
    #expect(form.errors(for: .template) == ["Choose a distribution."])
    form.input.templateID = "debian-12"
    #expect(form.errors(for: .template).isEmpty)
  }

  @Test func aNewResultReplacesTheEarlierErrors() {
    var form = loaded("ubuntu")
    form.apply(failure((.cpu, "bad cpu")), submitted: form.input)
    form.input.cpus = "3"
    form.apply(failure((.memory, "bad memory")), submitted: form.input)
    #expect(form.errors(for: .cpu).isEmpty)
    #expect(form.errors(for: .memory) == ["bad memory"])
  }

  // MARK: Busy

  @Test func busyShowsUntilTheNameChanges() {
    var form = loaded("ubuntu")
    form.input.name = "fresh"
    let closes = form.apply(.busy, submitted: form.input)
    #expect(!closes)
    #expect(form.showsBusy)
    form.input.cpus = "3"
    #expect(form.showsBusy)
    form.input.name = "fresh2"
    #expect(!form.showsBusy)
  }

  @Test func aLaterValidationResultClearsBusy() {
    var form = loaded("ubuntu")
    form.apply(.busy, submitted: form.input)
    form.apply(failure((.name, "Enter a name.")), submitted: form.input)
    #expect(!form.showsBusy)
  }

  // MARK: With the real controller

  private func outcome(
    _ scenario: MachineControllerPreviews.Scenario, edit: (inout MachineFormInput) -> Void
  ) async -> (MachineCreateFormPresentation, MachineCreateOutcome) {
    let controller = await MachineControllerPreviews.make(scenario).controller
    var form = MachineCreateFormPresentation()
    form.load(await controller.availableTemplates())
    edit(&form.input)
    let outcome = await controller.create(form.input, templates: form.offeredTemplates)
    form.apply(outcome, submitted: form.input)
    return (form, outcome)
  }

  @Test func theControllersTemplatesFillTheFormWithTheDefaults() async {
    let controller = await MachineControllerPreviews.make(.noMachines).controller
    var form = MachineCreateFormPresentation()
    form.load(await controller.availableTemplates())
    #expect(form.offeredTemplates == Data.templates)
    #expect(form.input.templateID == "ubuntu")
    #expect(form.input.cpus == "2" && form.input.memoryGiB == "4")
  }

  @Test func anExistingNameShowsUnderTheNameField() async {
    let (form, outcome) = await outcome(.mixed) { $0.name = Data.running.rawValue }
    guard case .invalid = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(form.errors(for: .name).count == 1)
    #expect(form.errors(for: .cpu).isEmpty && form.errors(for: .memory).isEmpty && form.errors(for: .disk).isEmpty)
  }

  @Test func theDefaultVMNameShowsUnderTheNameField() async {
    let (form, _) = await outcome(.noMachines) { $0.name = "default" }
    #expect(form.errors(for: .name).count == 1)
  }

  @Test func eachBadResourceShowsUnderItsOwnField() async {
    let (form, _) = await outcome(.noMachines) {
      $0.name = "ok-name"
      $0.cpus = "abc"
      $0.memoryGiB = "-1"
      $0.diskGiB = "0"
    }
    #expect(form.errors(for: .name).isEmpty)
    #expect(form.errors(for: .cpu).count == 1)
    #expect(form.errors(for: .memory).count == 1)
    #expect(form.errors(for: .disk).count == 1)
  }

  @Test func aNameBeingCreatedShowsBusy() async {
    let (form, outcome) = await outcome(.creating) { $0.name = Data.creating.rawValue }
    #expect(outcome == .busy)
    #expect(form.showsBusy)
  }
}
