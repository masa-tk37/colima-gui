import Foundation
import Testing

@testable import ColimaCore

private func instance(
  running: Bool = true, cpus: Int = 2, memoryBytes: Int64 = 2 << 30, diskBytes: Int64 = 100 << 30
) -> VMInstance {
  VMInstance(
    runState: running ? .running : .stopped(rawStatus: "Stopped"),
    arch: "aarch64", cpus: cpus, memoryBytes: memoryBytes, diskBytes: diskBytes, runtime: "docker")
}

private func profile(cpus: Int, memoryGiB: Double, diskGiB: Int, vmType: VMType?) -> ProfileSettings
{
  ProfileSettings(
    resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
    vmType: vmType)
}

private let qemuMissing = ToolchainStatus(
  colima: .found(path: "/opt/homebrew/bin/colima"),
  missingByVMType: [.qemu: ["qemu-img", "qemu-system-aarch64"]])

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let controller: VMController
  let model: VMSettingsModel

  init(
    observation: VMObservation,
    profile: Result<ProfileSettings?, ColimaFileError> = .success(nil),
    instanceVMType: Result<VMType?, ColimaFileError> = .success(nil)
  ) async {
    controller = VMController(cli: cli, files: files)
    cli.configure { $0.listDefault = [.success(observation)] }
    files.configure {
      $0.profile = profile
      $0.instanceVMType = instanceVMType
    }
    await controller.redetectToolchain()
    model = VMSettingsModel(controller: controller, files: files)
  }

  var writes: [VMResourceSettings] { files.writtenSettings }

  var runs: [VMCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  var preflightCount: Int { cli.calls.filter { $0 == .preflight }.count }

  static func runningVZ(
    profile settings: ProfileSettings? = profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)
  )
    async -> Harness
  {
    await Harness(
      observation: .present(instance()), profile: .success(settings), instanceVMType: .success(.vz))
  }

  func holdARestartOpen() async -> FakeProcess {
    controller.requestRestart()
    let id = controller.pendingConfirmation!.id
    #expect(controller.confirm(id: id) == .started)
    return await cli.process(at: 0)
  }

  func releaseOperation(_ process: FakeProcess) async {
    process.exit(code: 0)
    await controller.operationTask?.value
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMSettingsModelTests {


  @Test func theDiskFloorIsTheCurrentDiskRoundedUpWhileSaving() async {
    let partial = await Harness(
      observation: .present(instance(diskBytes: (100 << 30) + 1)),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)), instanceVMType: .success(.vz))
    #expect(partial.model.primaryAction == .save)
    #expect(partial.model.diskFloorGiB == 101)
  }

  @Test func creatingOrRecreatingHasNoDiskFloor() async {
    let absent = await Harness(observation: .absent)
    #expect(absent.model.diskFloorGiB == nil)

    let recreate = await Harness.runningVZ()
    await recreate.model.selectVMType(.qemu)
    #expect(recreate.model.primaryAction == .recreate)
    #expect(recreate.model.diskFloorGiB == nil)
  }

  @Test func hostResourcesNeverGoBelowOne() {
    #expect(HostResources(cpus: 0, memoryGiB: 0, diskGiB: -3) == HostResources(cpus: 1, memoryGiB: 1, diskGiB: 1))
  }

  // MARK: initial values

  @Test func initialValuesComeFromTheSettingsFile() async {
    let harness = await Harness.runningVZ(
      profile: profile(cpus: 4, memoryGiB: 8, diskGiB: 60, vmType: .qemu))

    #expect(
      harness.model.input
        == SettingsFormInput(cpus: "4", memoryGiB: "8", diskGiB: "60", vmType: .qemu))
    #expect(harness.model.loadFailureReason == nil)
  }

  @Test func fractionalMemoryKeepsItsFraction() async {
    let harness = await Harness.runningVZ(
      profile: profile(cpus: 2, memoryGiB: 2.5, diskGiB: 100, vmType: .vz))

    #expect(harness.model.memoryGiBText == "2.5")
  }

  @Test func missingSettingsFileFallsBackToCreationDefaultsWithoutAFailureReason() async {
    let harness = await Harness(observation: .absent, profile: .success(nil))

    #expect(
      harness.model.input
        == SettingsFormInput(cpus: "2", memoryGiB: "2", diskGiB: "100", vmType: .vz))
    #expect(harness.model.loadFailureReason == nil)
  }

  @Test func missingVMTypeLineTakesOnlyTheVMTypeFromDefaults() async {
    let harness = await Harness(
      observation: .absent,
      profile: .success(profile(cpus: 6, memoryGiB: 3, diskGiB: 40, vmType: nil)))

    #expect(
      harness.model.input
        == SettingsFormInput(cpus: "6", memoryGiB: "3", diskGiB: "40", vmType: .vz))
  }

  @Test func unreadableSettingsFileFallsBackToDefaultsAndShowsTheReason() async {
    let harness = await Harness(
      observation: .absent,
      profile: .failure(.unexpectedFormat(key: "cpu", reason: "duplicated")))

    #expect(
      harness.model.input
        == SettingsFormInput(cpus: "2", memoryGiB: "2", diskGiB: "100", vmType: .vz))
    let reason = harness.model.loadFailureReason
    #expect(reason?.contains("duplicated") == true)
  }

  @Test func appearingAgainReloadsUnlessTheFormWasEdited() async {
    let harness = await Harness.runningVZ(
      profile: profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz))
    harness.files.configure {
      $0.profile = .success(profile(cpus: 3, memoryGiB: 2, diskGiB: 100, vmType: .vz))
    }

    await harness.model.onAppear()
    #expect(harness.model.cpusText == "3")

    harness.model.cpusText = "5"
    harness.files.configure {
      $0.profile = .success(profile(cpus: 7, memoryGiB: 2, diskGiB: 100, vmType: .vz))
    }
    await harness.model.onAppear()
    #expect(harness.model.cpusText == "5")
  }

  // MARK: unapplied fields

  @Test func fieldsThatDifferFromTheRunningVMAreUnapplied() async {
    let harness = await Harness(
      observation: .present(instance()),
      profile: .success(profile(cpus: 4, memoryGiB: 4, diskGiB: 100, vmType: .qemu)),
      instanceVMType: .success(.vz))

    #expect(harness.model.unappliedFields == [.cpu, .memory, .vmType])
  }

  @Test func memoryAndDiskAreComparedInBytes() async {
    let harness = await Harness(
      observation: .present(instance(memoryBytes: 2_684_354_560, diskBytes: 100 << 30)),
      profile: .success(profile(cpus: 2, memoryGiB: 2.5, diskGiB: 100, vmType: .vz)),
      instanceVMType: .success(.vz))
    #expect(harness.model.unappliedFields.isEmpty)

    let off = await Harness(
      observation: .present(instance(memoryBytes: 2_684_354_561, diskBytes: (100 << 30) + 1)),
      profile: .success(profile(cpus: 2, memoryGiB: 2.5, diskGiB: 100, vmType: .vz)),
      instanceVMType: .success(.vz))
    #expect(off.model.unappliedFields == [.memory, .disk])
  }

  @Test func unappliedFieldsAreEmptyUnlessTheVMIsRunning() async {
    let stopped = await Harness(
      observation: .present(instance(running: false)),
      profile: .success(profile(cpus: 4, memoryGiB: 4, diskGiB: 200, vmType: .vz)),
      instanceVMType: .success(.vz))
    #expect(stopped.model.unappliedFields.isEmpty)

    let absent = await Harness(
      observation: .absent,
      profile: .success(profile(cpus: 4, memoryGiB: 4, diskGiB: 200, vmType: .vz)))
    #expect(absent.model.unappliedFields.isEmpty)
  }

  @Test func vmTypeIsLeftOutWhenTheInstanceTypeCannotBeRead() async {
    let harness = await Harness(
      observation: .present(instance()),
      profile: .success(profile(cpus: 4, memoryGiB: 2, diskGiB: 100, vmType: .qemu)),
      instanceVMType: .success(nil))

    #expect(harness.model.unappliedFields == [.cpu])
  }

  @Test func vmTypeIsLeftOutWhenTheSettingsFileHasNoVMTypeLine() async {
    let harness = await Harness(
      observation: .present(instance()),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: nil)),
      instanceVMType: .success(.vz))

    #expect(harness.model.unappliedFields.isEmpty)
  }

  // MARK: primary action

  @Test func primaryActionIsCreateWhenTheVMIsAbsent() async {
    let harness = await Harness(observation: .absent, instanceVMType: .success(nil))

    #expect(harness.model.primaryAction == .create)
  }

  @Test func primaryActionIsSaveWhenTheVMTypeMatchesTheActualOne() async {
    let harness = await Harness.runningVZ()

    #expect(harness.model.primaryAction == .save)
  }

  @Test func primaryActionComparesWithTheStateFileNotTheSettingsFile() async {
    let harness = await Harness.runningVZ(
      profile: profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .qemu))
    #expect(harness.model.primaryAction == .recreate)

    await harness.model.selectVMType(.vz)
    #expect(harness.model.primaryAction == .save)
  }

  @Test func primaryActionSwitchesToRecreateWhenTheVMTypeSelectionDiffers() async {
    let harness = await Harness.runningVZ()

    await harness.model.selectVMType(.krunkit)

    #expect(harness.model.primaryAction == .recreate)
  }

  @Test func primaryActionIsUnavailableWhenAnExistingVMsTypeFileIsMissing() async {
    let harness = await Harness(
      observation: .present(instance()),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)),
      instanceVMType: .success(nil))

    guard case .unavailable(let reason) = harness.model.primaryAction else {
      Issue.record("expected unavailable, got \(harness.model.primaryAction)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func primaryActionIsUnavailableWhenTheStateFileCannotBeRead() async {
    let harness = await Harness(
      observation: .present(instance()),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)),
      instanceVMType: .failure(.unreadable(path: "/x/colima.yaml", reason: "denied")))

    guard case .unavailable(let reason) = harness.model.primaryAction else {
      Issue.record("expected unavailable, got \(harness.model.primaryAction)")
      return
    }
    #expect(reason.contains("denied"))
  }

  @Test func primaryActionIsUnavailableWhileTheVMStateIsUnknown() async {
    let harness = await Harness(observation: .unknown(reason: "list が失敗しました"))

    guard case .unavailable(let reason) = harness.model.primaryAction else {
      Issue.record("expected unavailable, got \(harness.model.primaryAction)")
      return
    }
    #expect(reason.contains("list が失敗しました"))
  }

  @Test func unreadableTypeDoesNotBlockCreatingAnAbsentVM() async {
    let harness = await Harness(
      observation: .absent, instanceVMType: .failure(.unreadable(path: "/x", reason: "denied")))

    #expect(harness.model.primaryAction == .create)
  }

  // MARK: save

  @Test func savingARunningVMWritesOnlyTheThreeResourcesAndNeverTheVMType() async {
    let harness = await Harness.runningVZ(
      profile: profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .qemu))
    await harness.model.selectVMType(.vz)
    harness.model.cpusText = "6"
    harness.model.memoryGiBText = "4.5"
    harness.model.diskGiBText = "120"

    let result = await harness.model.submit()

    #expect(result == .saved(.restartRequired))
    #expect(harness.writes == [VMResourceSettings(cpus: 6, memoryGiB: 4.5, diskGiB: 120)])
    #expect(try! harness.files.readProfileSettings()?.vmType == .qemu)
    #expect(harness.runs.isEmpty)
  }

  @Test func savingAStoppedVMAppliesOnTheNextStart() async {
    let harness = await Harness(
      observation: .present(instance(running: false)),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)),
      instanceVMType: .success(.vz))
    harness.model.cpusText = "3"

    let result = await harness.model.submit()

    #expect(result == .saved(.appliesOnNextStart))
    #expect(harness.writes.count == 1)
  }

  @Test func aSavedValueShowsAsUnappliedWhileTheVMKeepsRunning() async {
    let harness = await Harness.runningVZ()
    #expect(harness.model.unappliedFields.isEmpty)
    harness.model.cpusText = "6"

    _ = await harness.model.submit()

    #expect(harness.model.unappliedFields == [.cpu])
  }

  @Test func restartAfterSaveStartsTheRestartConfirmation() async {
    let harness = await Harness.runningVZ()
    harness.model.cpusText = "6"
    #expect(await harness.model.submit() == .saved(.restartRequired))

    harness.model.requestRestart()

    #expect(harness.controller.pendingConfirmation?.intent == .restartVM)
  }

  @Test func aFailedWriteReturnsTheReasonAndNeverReportsARestart() async {
    let harness = await Harness.runningVZ()
    harness.files.configure {
      $0.writeFailure = .writeFailed(path: "/x/colima.yaml", reason: "read-only")
    }
    harness.model.cpusText = "6"

    let result = await harness.model.submit()

    guard case .failed(let reason) = result else {
      Issue.record("expected failed, got \(result)")
      return
    }
    #expect(reason.contains("read-only"))
  }

  // MARK: validation

  @Test func invalidInputIsReportedPerFieldAndNothingIsWritten() async {
    let harness = await Harness.runningVZ()
    harness.model.cpusText = "0"
    harness.model.memoryGiBText = "abc"

    let result = await harness.model.submit()

    guard case .invalid(let errors) = result else {
      Issue.record("expected invalid, got \(result)")
      return
    }
    #expect(errors.map(\.field) == [.cpu, .memory])
    #expect(harness.model.fieldErrors == errors)
    #expect(harness.writes.isEmpty)
  }

  @Test func aSuccessfulSubmitClearsEarlierFieldErrors() async {
    let harness = await Harness.runningVZ()
    harness.model.cpusText = "0"
    _ = await harness.model.submit()
    #expect(!harness.model.fieldErrors.isEmpty)

    harness.model.cpusText = "3"
    _ = await harness.model.submit()

    #expect(harness.model.fieldErrors.isEmpty)
  }

  @Test func savingRejectsADiskSmallerThanTheActualOne() async {
    let harness = await Harness.runningVZ()
    harness.model.diskGiBText = "50"

    let result = await harness.model.submit()

    guard case .invalid(let errors) = result else {
      Issue.record("expected invalid, got \(result)")
      return
    }
    #expect(errors.map(\.field) == [.disk])
    #expect(harness.writes.isEmpty)
  }

  @Test func theDiskFloorIsTheActualDiskRoundedUp() async {
    let harness = await Harness(
      observation: .present(instance(diskBytes: (100 << 30) + 1)),
      profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)),
      instanceVMType: .success(.vz))

    let rejected = await harness.model.submit()
    guard case .invalid = rejected else {
      Issue.record("100 GiB must be below the 101 GiB floor, got \(rejected)")
      return
    }

    harness.model.diskGiBText = "101"
    #expect(await harness.model.submit() == .saved(.restartRequired))
  }

  @Test func recreatingAcceptsADiskSmallerThanTheActualOne() async {
    let harness = await Harness.runningVZ()
    await harness.model.selectVMType(.krunkit)
    harness.model.diskGiBText = "50"

    let result = await harness.model.submit()

    #expect(result == .recreateRequested)
    guard case .recreateVM(let plan)? = harness.controller.pendingConfirmation?.intent else {
      Issue.record("expected a recreate confirmation")
      return
    }
    #expect(plan.spec.resources.diskGiB == 50)
    #expect(plan.spec.vmType == .krunkit)
    #expect(plan.currentVMType == .vz)
    #expect(harness.writes.isEmpty)
  }

  // MARK: recreate

  @Test func recreatingToATypeWithMissingExecutablesIsRejectedWithoutAConfirmation() async {
    let harness = await Harness.runningVZ()
    harness.cli.configure { $0.toolchain = qemuMissing }
    await harness.model.selectVMType(.qemu)

    let result = await harness.model.submit()

    #expect(
      result
        == .recreateRejected(
          .missingExecutables(vmType: .qemu, missing: ["qemu-img", "qemu-system-aarch64"])))
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.writes.isEmpty)
  }

  @Test func recreatingChecksAMissingExecutableAgainBeforeRejecting() async {
    let harness = await Harness.runningVZ()
    harness.cli.configure { $0.toolchain = qemuMissing }
    await harness.model.selectVMType(.qemu)
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [:])
    }

    let result = await harness.model.submit()

    #expect(result == .recreateRequested)
  }

  @Test func selectingAVMTypeShowsItsMissingExecutables() async {
    let harness = await Harness.runningVZ()
    #expect(harness.model.missingExecutables(for: .qemu).isEmpty)
    harness.cli.configure { $0.toolchain = qemuMissing }

    await harness.model.selectVMType(.qemu)

    #expect(harness.model.missingExecutables(for: .qemu) == ["qemu-img", "qemu-system-aarch64"])
    #expect(harness.model.missingExecutables(for: .vz).isEmpty)
  }

  @Test func theToolchainIsLookedUpAgainOnAppearAndOnEveryVMTypeChange() async {
    let harness = await Harness.runningVZ()
    let initial = harness.preflightCount

    await harness.model.onAppear()
    #expect(harness.preflightCount == initial + 1)

    await harness.model.selectVMType(.krunkit)
    #expect(harness.preflightCount == initial + 2)
    #expect(harness.model.vmType == .krunkit)

    await harness.model.selectVMType(.krunkit)
    #expect(harness.preflightCount == initial + 2)
  }

  // MARK: unreadable VM type

  @Test func submitWithAnUnreadableVMTypeNeverWritesTheSettings() async {
    for instanceVMType: Result<VMType?, ColimaFileError> in [
      .success(nil), .failure(.unreadable(path: "/x", reason: "denied")),
    ] {
      let harness = await Harness(
        observation: .present(instance()),
        profile: .success(profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .vz)),
        instanceVMType: instanceVMType)
      harness.model.cpusText = "6"

      let result = await harness.model.submit()

      guard case .unavailable(let reason) = result else {
        Issue.record("expected unavailable, got \(result)")
        continue
      }
      #expect(!reason.isEmpty)
      #expect(harness.writes.isEmpty)
      #expect(harness.controller.pendingConfirmation == nil)
    }
  }

  @Test func theInstanceTypeIsReadAgainWhenSubmitting() async {
    let harness = await Harness.runningVZ()
    harness.files.configure { $0.instanceVMType = .success(nil) }

    let result = await harness.model.submit()

    guard case .unavailable = result else {
      Issue.record("expected unavailable, got \(result)")
      return
    }
    #expect(harness.writes.isEmpty)
  }

  @Test func refreshingTheInstanceTypeUpdatesThePrimaryAction() async {
    let harness = await Harness.runningVZ()
    harness.files.configure { $0.instanceVMType = .success(.qemu) }
    #expect(harness.model.primaryAction == .save)

    harness.model.refreshInstanceVMType()

    #expect(harness.model.primaryAction == .recreate)
  }

  // MARK: create

  @Test func createStartsTheCreateCommandWithTheFormValues() async {
    let harness = await Harness(observation: .absent)
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 0)]] }
    harness.model.cpusText = "4"
    harness.model.memoryGiBText = "6"
    harness.model.diskGiBText = "80"
    await harness.model.selectVMType(.vz)

    let result = await harness.model.submit()
    await harness.controller.operationTask?.value

    #expect(result == .createStarted)
    let expected = VMSettingsValidator.validate(
      SettingsFormInput(cpus: "4", memoryGiB: "6", diskGiB: "80", vmType: .vz), diskFloorGiB: nil)
    guard case .success(let spec) = expected else {
      Issue.record("fixture spec must validate")
      return
    }
    #expect(harness.runs == [.create(spec)])
    #expect(harness.writes.isEmpty)
  }

  @Test func createWhileColimaCannotBeFoundReportsFailureInsteadOfStarting() async {
    let harness = await Harness(observation: .absent)
    #expect(harness.model.primaryAction == .create)
    harness.controller.toolchain = ToolchainStatus(
      colima: .missing(searched: ["/x"]), missingByVMType: [:])

    let result = await harness.model.submit()

    guard case .failed = result else {
      Issue.record("expected failed, got \(result)")
      return
    }
    #expect(harness.runs.isEmpty)
  }

  @Test func primaryActionIsUnavailableWhenColimaIsMissing() async {
    let harness = await Harness(observation: .absent)
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(colima: .missing(searched: ["/x"]), missingByVMType: [:])
    }
    await harness.controller.redetectToolchain()

    guard case .unavailable = harness.model.primaryAction else {
      Issue.record("expected unavailable, got \(harness.model.primaryAction)")
      return
    }
  }

  // MARK: busy

  @Test func savingIsRejectedWhileAnOperationRuns() async {
    let harness = await Harness.runningVZ()
    let process = await harness.holdARestartOpen()
    harness.model.cpusText = "6"

    let result = await harness.model.submit()

    #expect(result == .busy)
    #expect(harness.writes.isEmpty)
    await harness.releaseOperation(process)
  }

  @Test func recreatingIsRejectedWhileAnOperationRuns() async {
    let harness = await Harness.runningVZ()
    let process = await harness.holdARestartOpen()
    await harness.model.selectVMType(.krunkit)
    let preflights = harness.preflightCount

    let result = await harness.model.submit()

    #expect(result == .busy)
    #expect(harness.controller.pendingConfirmation == nil)
    #expect(harness.preflightCount == preflights)
    await harness.releaseOperation(process)
  }

  @Test func creatingIsRejectedWhileAnOperationRuns() async {
    let harness = await Harness(observation: .absent)
    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    let runsBefore = harness.runs.count

    let result = await harness.model.submit()

    #expect(result == .busy)
    #expect(harness.runs.count == runsBefore)
    await harness.releaseOperation(process)
  }

  @Test func aBusyRejectionDoesNotValidateOrReportFieldErrors() async {
    let harness = await Harness.runningVZ()
    let process = await harness.holdARestartOpen()
    harness.model.cpusText = "0"

    let result = await harness.model.submit()

    #expect(result == .busy)
    #expect(harness.model.fieldErrors.isEmpty)
    await harness.releaseOperation(process)
  }
}
