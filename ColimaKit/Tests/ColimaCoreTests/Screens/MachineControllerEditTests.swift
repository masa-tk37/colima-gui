import Foundation
import Observation
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(
  _ name: String, _ runState: MachineRunState = .stopped, mounts: [MachineMount] = []
) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30,
    mounts: mounts, templateID: "ubuntu")
}

private func listing(_ instances: MachineInstance...) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: [])
}

private let host = HostResources(cpus: 8, memoryGiB: 32, diskGiB: 500)

private func edit(
  cpus: String = "4", memory: String = "8", disk: String = "120", mounts: [MachineMount] = []
) -> MachineEditInput {
  MachineEditInput(cpus: cpus, memoryGiB: memory, diskGiB: disk, mounts: mounts)
}

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let controller: MachineController

  init(_ initial: LimaListing, listings: [LimaListing] = [], existingDirectories: Set<String> = []) async {
    controller = MachineController(cli: cli, host: host, directoryExists: { existingDirectories.contains($0) })
    cli.configure { $0.listInstances = ([initial] + listings).map { .success($0) } }
    await controller.refreshNow()
  }

  var runs: [MachineCommand] {
    cli.calls.compactMap { if case .run(let command) = $0 { command } else { nil } }
  }

  func task(for name: String) -> Task<Void, Never>? { controller.operationTasks[machineName(name).key] }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerEditTests {

  // MARK: Availability

  @Test func editNeedsAStoppedMachineAndShellNeedsARunningOne() async {
    let harness = await Harness(
      listing(
        instance("on", .running), instance("off", .stopped), instance("odd", .other(rawStatus: "Paused")),
        instance("bad", .broken(errors: ["no config"]))))
    let controller = harness.controller
    func flags(_ name: String) -> [Bool] {
      let name = machineName(name)
      return [controller.canEdit(name), controller.canOpenShell(name)]
    }

    #expect(flags("on") == [false, true])
    #expect(flags("off") == [true, false])
    #expect(flags("odd") == [false, false])
    #expect(flags("bad") == [false, false])
    #expect(flags("ghost") == [false, false])
  }

  @Test func aMachineHoldingASlotCanNeitherBeEditedNorOpenAShell() async {
    let harness = await Harness(
      listing(instance("web", .stopped), instance("api", .running)),
      listings: [listing(instance("web", .running), instance("api", .running))])
    let web = machineName("web")
    let api = machineName("api")

    harness.controller.performStart(web)
    harness.controller.stop(api)

    #expect(!harness.controller.canEdit(web))
    #expect(!harness.controller.canOpenShell(web))
    #expect(!harness.controller.canEdit(api))
    #expect(!harness.controller.canOpenShell(api))

    await harness.cli.process(at: 0).exit(code: 0)
    await harness.cli.process(at: 1).exit(code: 0)
    await harness.task(for: "web")?.value
    await harness.task(for: "api")?.value
  }

  @Test func nothingIsPossibleBeforeTheFirstListOrWhileLimactlIsMissing() async {
    let harness = await Harness(listing(instance("off", .stopped), instance("on", .running)))
    harness.cli.configure {
      $0.toolchain = .missing(searched: ["/opt/homebrew/bin/limactl"])
      $0.listInstances = [.failure(.limactlMissing)]
    }
    await harness.controller.refreshNow()

    #expect(!harness.controller.canEdit(machineName("off")))
    #expect(!harness.controller.canOpenShell(machineName("on")))
    #expect(!harness.controller.canCreate)
    #expect(harness.controller.saveEdit(machineName("off"), edit()) == .mustStopFirst)
    #expect(harness.runs.isEmpty)
  }

  // MARK: Refusals

  @Test func aRunningOrUnlistedMachineMustBeStoppedFirstAndRunsNothing() async {
    let harness = await Harness(listing(instance("on", .running)))

    #expect(harness.controller.saveEdit(machineName("on"), edit()) == .mustStopFirst)
    #expect(harness.controller.saveEdit(machineName("ghost"), edit()) == .mustStopFirst)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.runs.isEmpty)
  }

  @Test func aMachineWithASlotIsBusy() async {
    let harness = await Harness(
      listing(instance("web", .stopped)), listings: [listing(instance("web", .running))])
    let web = machineName("web")
    harness.controller.performStart(web)

    let process = await harness.cli.process(at: 0)
    #expect(harness.controller.saveEdit(web, edit()) == .busy)
    #expect(harness.runs == [.start(web)])

    process.exit(code: 0)
    await harness.task(for: "web")?.value
  }

  // MARK: Validation

  @Test func invalidInputReturnsEveryFieldErrorAndTakesNoSlot() async {
    let current = MachineMount(path: "/work", writable: true)
    let harness = await Harness(
      listing(instance("web", .stopped, mounts: [current])), existingDirectories: ["/work"])
    let missing = MachineMount(path: "/gone", writable: false)

    let outcome = harness.controller.saveEdit(
      machineName("web"), edit(cpus: "99", memory: "x", disk: "50", mounts: [current, missing]))

    guard case .invalid(let failure) = outcome else {
      Issue.record("expected invalid, got \(outcome)")
      return
    }
    #expect(failure.fields.map(\.field) == [.cpu, .memory, .disk, .mount(index: 1)])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.records.isEmpty)
    #expect(harness.runs.isEmpty)
  }

  @Test func theValidatorGetsTheCurrentDiskSoAGrowingDiskPassesAndAShrinkingOneFails() async {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")

    guard case .invalid(let failure) = harness.controller.saveEdit(web, edit(disk: "99")) else {
      Issue.record("a smaller disk must be refused")
      return
    }
    #expect(failure.fields.map(\.field) == [.disk])

    #expect(harness.controller.saveEdit(web, edit(disk: "100")) == .started)
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "web")?.value
  }

  // MARK: Running

  @Test func aValidEditTakesTheSlotAtOnceAndRunsLimactlEdit() async throws {
    let share = MachineMount(path: "/work", writable: true)
    let harness = await Harness(
      listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))],
      existingDirectories: ["/work"])
    let web = machineName("web")

    let outcome = harness.controller.saveEdit(web, edit(mounts: [share]))

    #expect(outcome == .started)
    #expect(harness.controller.operations[web.key]?.kind == .edit)
    #expect(harness.controller.rows().map(\.display) == [.saving])
    #expect(!harness.controller.canEdit(web))
    #expect(harness.controller.notice == nil)

    let process = await harness.cli.process(at: 0)
    let expected = MachineEditSpec(
      resources: MachineResources(cpus: 4, memoryGiB: 8, diskGiB: 120), mounts: [share])
    #expect(process.command == .edit(web, expected))
    process.exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
    #expect(harness.controller.records[web.key]?.outcome == .succeeded)
    #expect(harness.controller.failures.isEmpty)
  }

  // MARK: Notice

  @Test func aSuccessfulEditPostsTheSavedNoticeAndDismissClearsIt() async {
    let harness = await Harness(listing(instance("web", .stopped)), listings: [listing(instance("web", .stopped))])
    let web = machineName("web")

    harness.controller.saveEdit(web, edit())
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.controller.notice == .editSaved(web))
    harness.controller.dismissNotice()
    #expect(harness.controller.notice == nil)
  }

  @Test func aNewNoticeReplacesTheEarlierOne() async {
    let harness = await Harness(
      listing(instance("a", .stopped), instance("b", .stopped)),
      listings: [listing(instance("a", .stopped), instance("b", .stopped))])

    harness.controller.saveEdit(machineName("a"), edit())
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "a")?.value
    harness.controller.saveEdit(machineName("b"), edit())
    await harness.cli.process(at: 1).exit(code: 0)
    await harness.task(for: "b")?.value

    #expect(harness.controller.notice == .editSaved(machineName("b")))
  }

  @Test func startingAnEditDoesNotPostANoticeAndAStopDoesNotEither() async {
    let harness = await Harness(listing(instance("web", .running)), listings: [listing(instance("web", .stopped))])

    harness.controller.stop(machineName("web"))
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "web")?.value

    #expect(harness.controller.notice == nil)
  }

  // MARK: Failure

  @Test func aFailedEditKeepsLimasOutputPostsNoNoticeAndKeepsTheSettings() async throws {
    let before = instance("web", .stopped)
    let harness = await Harness(listing(before), listings: [listing(before)])
    let web = machineName("web")
    let lines = ["  FATA[0000] disk shrink refused  ", "second line"]
    harness.cli.configure { $0.scriptedRuns = [lines.map { .output($0) } + [.exited(code: 1)]] }

    #expect(harness.controller.saveEdit(web, edit()) == .started)
    await harness.task(for: "web")?.value

    let failure = try #require(harness.controller.failures[web.key])
    #expect(failure.kind == .edit)
    #expect(failure.cause == .exited(code: 1))
    #expect(failure.outputTail == lines)
    #expect(harness.controller.notice == nil)
    #expect(harness.controller.machines == [before])
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.canEdit(web))
  }

  @Test func anEarlierNoticeSurvivesAFailedEdit() async {
    let harness = await Harness(
      listing(instance("a", .stopped), instance("b", .stopped)),
      listings: [listing(instance("a", .stopped), instance("b", .stopped))])
    harness.controller.saveEdit(machineName("a"), edit())
    await harness.cli.process(at: 0).exit(code: 0)
    await harness.task(for: "a")?.value
    harness.cli.configure { $0.scriptedRuns = [[.exited(code: 1)]] }

    harness.controller.saveEdit(machineName("b"), edit())
    await harness.task(for: "b")?.value

    #expect(harness.controller.notice == .editSaved(machineName("a")))
  }
}
