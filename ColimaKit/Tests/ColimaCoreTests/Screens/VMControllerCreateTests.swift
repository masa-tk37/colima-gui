import Foundation
import Testing

@testable import ColimaCore

private let colimaDefaults = VMCreateSpec(
  resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 100), vmType: .vz)

private func spec(cpus: Int, memoryGiB: Double, diskGiB: Int, vmType: VMType) -> VMCreateSpec {
  VMCreateSpec(
    resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
    vmType: vmType)
}

private let presentInstance = VMInstance(
  runState: .stopped(rawStatus: "Stopped"), arch: "aarch64", cpus: 2, memoryBytes: 2 << 30,
  diskBytes: 100 << 30,
  runtime: "docker")

@MainActor
private struct Harness {
  let cli = FakeColimaCLI()
  let files = InMemoryColimaFileStore()
  let controller: VMController

  init(observations: [Result<VMObservation, ColimaCLIError>] = [.success(.absent)]) async {
    controller = VMController(cli: cli, files: files)
    cli.configure { $0.listDefault = observations }
    await controller.redetectToolchain()
  }

  var runs: [VMCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func finish() async {
    await controller.operationTask?.value
  }

  func profile(cpus: Int, memoryGiB: Double, diskGiB: Int, vmType: VMType?) {
    files.configure {
      $0.profile = .success(
        ProfileSettings(
          resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
          vmType: vmType))
    }
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VMControllerCreateTests {

  // MARK: start on an absent VM

  @Test func startOnAnAbsentVMCreatesWithColimaDefaultsWhenNothingElseIsKnown() async {
    let harness = await Harness(observations: [
      .success(.absent), .success(.present(presentInstance)),
    ])

    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.create(colimaDefaults)])
    #expect(harness.controller.lastFailure == nil)
  }

  @Test func startIsIgnoredWhileColimaIsMissingEvenIfTheVMWasAbsent() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(colima: .missing(searched: []), missingByVMType: [:])
    }
    await harness.controller.redetectToolchain()

    harness.controller.start()

    #expect(harness.controller.activeOperation == nil)
    #expect(harness.runs.isEmpty)
  }

  // MARK: create preconditions

  @Test func createIsIgnoredUnlessTheVMIsAbsent() async {
    let stopped = VMObservation.present(presentInstance)
    for observation: VMObservation in [stopped, .unknown(reason: "x")] {
      let harness = await Harness(observations: [.success(observation)])
      harness.controller.create(colimaDefaults)
      #expect(harness.controller.activeOperation == nil)
      #expect(harness.runs.isEmpty)
      #expect(harness.cli.calls.filter { $0 == .preflight }.count == 1)
    }
  }

  @Test func createIsIgnoredWhileAnotherOperationHoldsTheSlot() async {
    let harness = await Harness()
    harness.controller.create(colimaDefaults)
    harness.controller.create(spec(cpus: 4, memoryGiB: 4, diskGiB: 50, vmType: .vz))

    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.create(colimaDefaults)])
  }

  // MARK: stages

  @Test func createTakesTheSlotBeforeAnyAwaitAndRunsPreflightCreateThenReads() async {
    let harness = await Harness(observations: [
      .success(.absent), .success(.present(presentInstance)),
    ])
    let callsBefore = harness.cli.calls.count

    harness.controller.create(colimaDefaults)

    #expect(harness.controller.activeOperation?.kind == .create)
    #expect(harness.controller.activeOperation?.stage == .preflight)
    #expect(harness.controller.displayState == .starting)
    #expect(harness.controller.dockerAvailability == .vmBusy(.starting))

    let process = await harness.cli.process(at: 0)
    #expect(harness.controller.activeOperation?.stage == .creating)
    process.send("creating")
    process.exit(code: 0)
    await harness.finish()

    #expect(
      harness.cli.calls.dropFirst(callsBefore) == [
        .preflight, .run(.create(colimaDefaults)), .listDefault,
      ])
    #expect(harness.controller.activeOperation == nil)
    #expect(harness.controller.lastFailure == nil)
    #expect(harness.controller.observation == .present(presentInstance))
  }

  @Test func aMissingExecutableStopsBeforeCreateAndLeavesAPreflightFailure() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .found(path: "/opt/homebrew/bin/colima"),
        missingByVMType: [.qemu: ["qemu-img", "qemu-system-aarch64"], .vz: []])
    }
    let qemu = spec(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .qemu)

    harness.controller.create(qemu)
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .create, stage: .preflight,
          cause: .missingExecutables(.qemu, ["qemu-img", "qemu-system-aarch64"]), outputLines: []))
    #expect(harness.controller.activeOperation == nil)
  }

  @Test func aMissingExecutableOfAnotherVMTypeDoesNotBlockCreate() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [.qemu: ["qemu-img"]])
    }

    harness.controller.create(colimaDefaults)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.create(colimaDefaults)])
  }

  @Test func colimaDisappearingAtPreflightFailsTheStageWithoutRunningCreate() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:])
    }

    harness.controller.create(colimaDefaults)
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(harness.controller.lastFailure?.stage == .preflight)
    #expect(harness.controller.lastFailure?.kind == .create)
    #expect(
      harness.controller.dockerAvailability == .colimaMissing(searched: ["/opt/homebrew/bin"]))
  }

  @Test func aNonZeroExitLeavesACreatingFailureWithTheOutput() async {
    let harness = await Harness()
    harness.controller.create(colimaDefaults)
    let process = await harness.cli.process(at: 0)
    process.send("fatal: boom")
    process.exit(code: 1)
    await harness.finish()

    #expect(
      harness.controller.lastFailure
        == VMOperationFailure(
          kind: .create, stage: .creating, cause: .exited(code: 1), outputLines: ["fatal: boom"]))
    #expect(harness.controller.observation == .absent)
  }

  @Test func aLaunchFailureLeavesACreatingFailure() async {
    let harness = await Harness()
    harness.cli.configure { $0.scriptedRuns = [[.launchFailed(reason: "no such file")]] }
    harness.controller.create(colimaDefaults)
    await harness.finish()

    #expect(harness.controller.lastFailure?.stage == .creating)
    #expect(harness.controller.lastFailure?.cause == .launchFailed(reason: "no such file"))
  }

  @Test func theNextOperationClearsThePreviousFailure() async {
    let harness = await Harness()
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)], [.exited(code: 0)]] }
    harness.controller.create(colimaDefaults)
    await harness.finish()
    #expect(harness.controller.lastFailure != nil)

    harness.controller.create(colimaDefaults)
    #expect(harness.controller.lastFailure == nil)
    await harness.finish()
  }

  // MARK: creationDefaults

  @Test func defaultsAreColimaDefaultsWithoutASettingsFile() async {
    let harness = await Harness()
    #expect(harness.controller.creationDefaults() == colimaDefaults)
  }

  @Test func defaultsTakeTheSettingsFileValuesAndItsVMType() async {
    let harness = await Harness()
    harness.profile(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .qemu)
    #expect(
      harness.controller.creationDefaults()
        == spec(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .qemu))
  }

  @Test func aSettingsFileWithoutAVMTypeFallsBackToVz() async {
    let harness = await Harness()
    harness.profile(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: nil)
    #expect(harness.controller.creationDefaults().vmType == .vz)
  }

  @Test func aSettingsFileValueBreakingTheRulesIsSkippedPerField() async {
    let harness = await Harness()
    harness.profile(cpus: 0, memoryGiB: 8, diskGiB: 60, vmType: .vz)
    #expect(
      harness.controller.creationDefaults() == spec(cpus: 2, memoryGiB: 8, diskGiB: 60, vmType: .vz)
    )

    harness.profile(cpus: 6, memoryGiB: 0.5, diskGiB: 0, vmType: .vz)
    #expect(
      harness.controller.creationDefaults()
        == spec(cpus: 6, memoryGiB: 2, diskGiB: 100, vmType: .vz))

    harness.profile(cpus: -1, memoryGiB: .nan, diskGiB: -5, vmType: .vz)
    #expect(harness.controller.creationDefaults() == colimaDefaults)
  }

  @Test func anUnreadableSettingsFileFallsBackToColimaDefaults() async {
    let harness = await Harness()
    harness.files.configure { $0.profile = .failure(.unreadable(path: "/x", reason: "denied")) }
    #expect(harness.controller.creationDefaults() == colimaDefaults)
  }

  @Test func theLastCreatedSpecBeatsTheSettingsFile() async {
    let harness = await Harness()
    harness.profile(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .qemu)
    let created = spec(cpus: 4, memoryGiB: 3.5, diskGiB: 80, vmType: .vz)

    harness.controller.create(created)
    let process = await harness.cli.process(at: 0)
    process.exit(code: 1)
    await harness.finish()

    #expect(harness.controller.creationDefaults() == created)
  }

  @Test func aSpecRejectedByPreflightIsNotRemembered() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [.qemu: ["qemu-img"]])
    }
    harness.profile(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .vz)

    harness.controller.create(spec(cpus: 4, memoryGiB: 4, diskGiB: 50, vmType: .qemu))
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(
      harness.controller.creationDefaults() == spec(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .vz)
    )
  }

  @Test func startOnAnAbsentVMUsesTheSettingsFileValues() async {
    let harness = await Harness()
    harness.profile(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .vz)

    harness.controller.start()
    let process = await harness.cli.process(at: 0)
    process.exit(code: 0)
    await harness.finish()

    #expect(harness.runs == [.create(spec(cpus: 6, memoryGiB: 8, diskGiB: 60, vmType: .vz))])
  }

  @Test func startOnAnAbsentVMWithAMissingExecutableLeavesAPreflightFailure() async {
    let harness = await Harness()
    harness.cli.configure {
      $0.toolchain = ToolchainStatus(
        colima: .found(path: "/opt/homebrew/bin/colima"), missingByVMType: [.qemu: ["qemu-img"]])
    }
    harness.profile(cpus: 2, memoryGiB: 2, diskGiB: 100, vmType: .qemu)

    harness.controller.start()
    await harness.finish()

    #expect(harness.runs.isEmpty)
    #expect(harness.controller.lastFailure?.stage == .preflight)
    #expect(harness.controller.lastFailure?.cause == .missingExecutables(.qemu, ["qemu-img"]))
  }
}
