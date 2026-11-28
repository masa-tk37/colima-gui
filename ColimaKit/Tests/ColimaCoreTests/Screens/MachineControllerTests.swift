import Foundation
import Testing

@testable import ColimaCore

private func machineName(_ text: String) -> MachineName {
  try! MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

private func instance(
  _ name: String, _ runState: MachineRunState = .running, templateID: String? = "ubuntu"
) -> MachineInstance {
  MachineInstance(
    name: machineName(name), runState: runState, cpus: 2, memoryBytes: 4 << 30, diskBytes: 100 << 30,
    mounts: [], templateID: templateID)
}

private func listing(_ instances: MachineInstance...) -> LimaListing {
  LimaListing(machines: instances, unownedMachineKeys: [])
}

private func operation(_ name: String, _ kind: MachineOperationKind, runID: UUID = UUID())
  -> ActiveMachineOperation
{
  ActiveMachineOperation(runID: runID, name: machineName(name), kind: kind)
}

private let missingLimactl = LimaToolchain.missing(searched: ["/opt/homebrew/bin/limactl"])

private func sleeper(_ seconds: Int) -> ManualClock.Instant { .init(offset: .seconds(seconds)) }

@MainActor
private struct Harness {
  let cli = FakeLimaCLI()
  let rounds = RoundCounter()
  let controller: MachineController

  init() {
    controller = MachineController(cli: cli)
  }

  func startMonitor(clock: ManualClock) -> Task<Void, Never> {
    let controller = controller
    let rounds = rounds
    return Task { await controller.monitor(clock: clock, didCompleteRound: rounds.roundCompleted) }
  }

  func count(_ call: FakeLimaCLI.Call) -> Int { cli.calls.filter { $0 == call }.count }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineControllerTests {

  // MARK: Nothing happens until the screen asks

  @Test func aNewControllerRunsAndFetchesNothing() {
    let harness = Harness()
    #expect(harness.cli.calls.isEmpty)
    #expect(harness.controller.toolchain == nil)
    #expect(harness.controller.machines == nil)
    #expect(harness.controller.listError == nil)
    #expect(harness.controller.rows().isEmpty)
    #expect(!harness.controller.canCreate)
  }

  // MARK: Listing

  @Test func monitorReflectsTheListedMachinesWithTheirDisplayState() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [
        .success(
          listing(
            instance("web"), instance("db", .stopped), instance("odd", .other(rawStatus: "Paused")),
            instance("bad", .broken(errors: ["no config"]))))
      ]
    }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    let rows = harness.controller.rows()
    #expect(rows.map(\.name) == ["web", "db", "odd", "bad"].map(machineName))
    #expect(
      rows.map(\.display) == [
        .running, .stopped, .other(rawStatus: "Paused"), .broken(errors: ["no config"]),
      ])
    #expect(harness.controller.machines?.count == 4)
    #expect(harness.controller.toolchain == .found(path: "/opt/homebrew/bin/limactl"))
    #expect(harness.controller.canCreate)
  }

  @Test func aRowCarriesTheInstanceItsKeyAndTheTemplateDisplayName() async throws {
    let harness = Harness()
    let web = instance("web", templateID: "ubuntu-24.04")
    let custom = instance("custom", templateID: "weird-os")
    let unknown = instance("unknown", templateID: nil)
    harness.cli.configure { $0.listInstances = [.success(listing(web, custom, unknown))] }
    await harness.controller.refreshNow()

    let rows = harness.controller.rows()
    #expect(rows[0].instance == web)
    #expect(rows[0].id == machineName("web").key)
    #expect(rows[0].distribution == MachineTemplate(id: "ubuntu-24.04")?.displayName)
    #expect(rows[0].distribution == "Ubuntu 24.04")
    #expect(rows[1].distribution == "weird-os")
    #expect(rows[2].distribution == nil)
    #expect(rows.allSatisfy { !$0.cancelRequested })
  }

  @Test func zeroMachinesIsAnEmptyListNotAnUnknownOne() async {
    let harness = Harness()
    await harness.controller.refreshNow()
    #expect(harness.controller.machines == [])
    #expect(harness.controller.rows().isEmpty)
    #expect(harness.controller.listError == nil)
  }

  @Test func theListingKeepsTheUnownedKeysForALaterCreateCheck() async throws {
    let harness = Harness()
    let unowned = try #require(MachineKey(unownedInstanceName: "CG-clash"))
    harness.cli.configure {
      $0.listInstances = [.success(LimaListing(machines: [], unownedMachineKeys: [unowned]))]
    }
    await harness.controller.refreshNow()
    #expect(harness.controller.listing?.unownedMachineKeys == [unowned])
  }

  @Test func monitorPollsEveryThreeSecondsAndReflectsStateChanges() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [
        .success(listing(instance("web", .stopped))),
        .success(listing(instance("web", .running))),
        .success(listing(instance("web", .stopped))),
      ]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await harness.rounds.waitForRounds(1)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.rows().map(\.display) == [.running])
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)
    #expect(harness.controller.rows().map(\.display) == [.stopped])

    monitor.cancel()
    await monitor.value
    #expect(harness.count(.listInstances) == 3)
  }

  @Test func switchingToBackgroundStretchesTheWaitAndBackToForegroundShortensIt() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = (1...3).map { .success(listing(instance("m\($0)"))) }
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: sleeper(3))

    harness.controller.setCadence(.background)
    await clock.waitForSleeper(until: sleeper(15))
    clock.advance(by: .seconds(3))
    #expect(harness.count(.listInstances) == 1)

    harness.controller.setCadence(.foreground)
    await harness.rounds.waitForRounds(2)
    #expect(harness.controller.rows().map(\.name) == [machineName("m2")])
    #expect(harness.count(.listInstances) == 2)

    monitor.cancel()
    await monitor.value
  }

  @Test func refreshNowFetchesAtOnceWithoutAMonitor() async {
    let harness = Harness()
    harness.cli.configure { $0.listInstances = [.success(listing(instance("web")))] }

    await harness.controller.refreshNow()

    #expect(harness.cli.calls == [.preflight, .listInstances])
    #expect(harness.controller.rows().map(\.name) == [machineName("web")])
  }

  @Test func refreshNowDoesNotRepeatAPreflightOnceLimactlIsFound() async {
    let harness = Harness()
    await harness.controller.refreshNow()
    await harness.controller.refreshNow()
    #expect(harness.cli.calls == [.preflight, .listInstances, .listInstances])
  }

  // MARK: limactl missing

  @Test func nothingIsListedOrQueriedWhileLimactlIsMissing() async {
    let harness = Harness()
    harness.cli.configure { $0.toolchain = missingLimactl }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    await harness.controller.refreshNow()
    monitor.cancel()
    await monitor.value

    #expect(harness.cli.calls.allSatisfy { $0 == .preflight })
    #expect(harness.controller.toolchain == missingLimactl)
    #expect(harness.controller.machines == nil)
    #expect(harness.controller.rows().isEmpty)
    #expect(!harness.controller.canCreate)
  }

  @Test func limactlInstalledLaterIsPickedUpByTheNextRound() async {
    let harness = Harness()
    harness.cli.configure {
      $0.toolchain = missingLimactl
      $0.listInstances = [.success(listing(instance("web")))]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    #expect(!harness.controller.canCreate)

    harness.cli.configure { $0.toolchain = .found(path: "/opt/homebrew/bin/limactl") }
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)

    #expect(harness.controller.canCreate)
    #expect(harness.controller.rows().map(\.name) == [machineName("web")])
    monitor.cancel()
    await monitor.value
  }

  @Test func limactlVanishingDuringARereadIsDetectedAgain() async {
    let harness = Harness()
    harness.cli.configure { $0.listInstances = [.success(listing(instance("web")))] }
    await harness.controller.refreshNow()
    #expect(harness.controller.canCreate)

    harness.cli.configure {
      $0.toolchain = missingLimactl
      $0.listInstances = [.failure(.limactlMissing)]
    }
    await harness.controller.refreshNow()

    #expect(harness.controller.toolchain == missingLimactl)
    #expect(!harness.controller.canCreate)
    #expect(harness.cli.calls.suffix(2) == [.listInstances, .preflight])
  }

  // MARK: Failed reads

  @Test func aFailedReadKeepsTheLastListAndTheVerbatimOutput() async {
    let harness = Harness()
    let output = ["time=... level=fatal msg=\"boom\"", "second line"]
    harness.cli.configure {
      $0.listInstances = [
        .success(listing(instance("web"))),
        .failure(.nonZeroExit(code: 1, output: output)),
        .success(listing(instance("web", .stopped))),
      ]
    }
    await harness.controller.refreshNow()
    await harness.controller.refreshNow()

    #expect(harness.controller.listError == .nonZeroExit(code: 1, output: output))
    #expect(harness.controller.rows().map(\.display) == [.running])

    await harness.controller.refreshNow()
    #expect(harness.controller.listError == nil)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
  }

  @Test func aFailureBeforeAnyListLeavesTheListUnknown() async {
    let harness = Harness()
    harness.cli.configure { $0.listInstances = [.failure(.launchFailed(reason: "spawn failed"))] }
    await harness.controller.refreshNow()
    #expect(harness.controller.machines == nil)
    #expect(harness.controller.listError == .launchFailed(reason: "spawn failed"))
  }

  @Test func aCancelledReadChangesNothing() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("web"))), .failure(.cancelled)]
    }
    await harness.controller.refreshNow()
    await harness.controller.refreshNow()
    #expect(harness.controller.listError == nil)
    #expect(harness.controller.rows().map(\.name) == [machineName("web")])
  }

  @Test func aSlowerEarlierReadDoesNotOverwriteALaterReadThatFinishedFirst() async {
    let harness = Harness()
    let initial = listing(instance("initial"))
    let slow = listing(instance("slow"))
    let fast = listing(instance("fast"))
    // The first entry is consumed by the read below that also detects limactl.
    harness.cli.configure { $0.listInstances = [.success(initial), .success(slow), .success(fast)] }
    await harness.controller.refreshNow()
    let gate = ArrivalGate()
    harness.cli.configure { $0.beforeListInstancesReturns = gate.pass }

    let first = Task { await harness.controller.refreshNow() }
    await gate.waitForArrivals(1)
    await harness.controller.refreshNow()
    #expect(harness.controller.machines == [instance("fast")])
    gate.open()
    await first.value

    #expect(harness.controller.machines == [instance("fast")])
  }

  // MARK: Operations of an earlier session

  @Test func operationsOfAnEarlierSessionTakePrecedenceOverTheActualState() async {
    let harness = Harness()
    let runID = UUID()
    harness.cli.configure {
      $0.listInstances = [
        .success(listing(instance("a", .stopped), instance("b"), instance("c"), instance("d")))
      ]
      $0.activeOperations = [
        [
          operation("a", .start, runID: runID), operation("b", .stop), operation("c", .delete),
          operation("d", .edit),
        ]
      ]
    }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    #expect(harness.controller.rows().map(\.display) == [.starting, .stopping, .deleting, .saving])
    #expect(
      harness.controller.operations[machineName("a").key]
        == MachineOperationProgress(kind: .start, origin: .earlierSession(runID: runID)))
  }

  @Test func anEarlierSessionCreateShowsACreatingRowBeforeLimaListsIt() async {
    let harness = Harness()
    harness.cli.configure { $0.activeOperations = [[operation("fresh", .create)]] }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    let rows = harness.controller.rows()
    #expect(rows.map(\.name) == [machineName("fresh")])
    #expect(rows.map(\.display) == [.creating])
    #expect(rows.first?.instance == nil)
    #expect(rows.first?.distribution == nil)
  }

  @Test func anEarlierSessionCreateWithAListedRowShowsOneRow() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("fresh", .stopped)))]
      $0.activeOperations = [[operation("fresh", .create)]]
    }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    #expect(harness.controller.rows().map(\.display) == [.creating])
    #expect(harness.controller.rows().first?.instance == instance("fresh", .stopped))
  }

  @Test func theAgentIsAskedAtMonitorStartAndThenOnlyWhileOperationsRemain() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("a", .stopped)))]
      $0.activeOperations = [
        [operation("a", .start)], [operation("a", .start)], [],
      ]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)

    await harness.rounds.waitForRounds(1)
    #expect(harness.count(.activeOperations) == 1)
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    #expect(harness.count(.activeOperations) == 2)
    await clock.waitForSleeper(until: sleeper(6))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(3)
    #expect(harness.count(.activeOperations) == 3)
    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])

    await clock.waitForSleeper(until: sleeper(9))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(4)
    #expect(harness.count(.activeOperations) == 3)

    monitor.cancel()
    await monitor.value
  }

  @Test func anUnreachableAgentShowsNoOperationsAndIsAskedOnlyOnce() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("a")))]
      $0.activeOperations = [nil]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    monitor.cancel()
    await monitor.value

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.running])
    #expect(harness.count(.activeOperations) == 1)
  }

  @Test func anAgentThatBecomesUnreachableClearsTheOperationsItReported() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("a", .stopped)))]
      $0.activeOperations = [[operation("a", .start)], nil]
    }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    #expect(harness.controller.rows().map(\.display) == [.starting])

    await clock.waitForSleeper(until: sleeper(3))
    clock.advance(by: .seconds(3))
    await harness.rounds.waitForRounds(2)
    monitor.cancel()
    await monitor.value

    #expect(harness.controller.operations.isEmpty)
    #expect(harness.controller.rows().map(\.display) == [.stopped])
  }

  @Test func unlistedCreateRowsAreOrderedByNameAfterTheListedRows() async {
    let harness = Harness()
    harness.cli.configure {
      $0.listInstances = [.success(listing(instance("zeta"), instance("alpha")))]
      $0.activeOperations = [[operation("web", .create), operation("db", .create)]]
    }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value

    #expect(harness.controller.rows().map(\.name.rawValue) == ["zeta", "alpha", "db", "web"])
  }

  @Test func twoNamesThatFoldToOneKeyDoNotTrap() async {
    let harness = Harness()
    harness.cli.configure {
      $0.activeOperations = [[operation("Dev", .create), operation("dev", .create)]]
    }
    let monitor = harness.startMonitor(clock: ManualClock())
    await harness.rounds.waitForRounds(1)
    monitor.cancel()
    await monitor.value
    #expect(harness.controller.rows().count == 1)
  }

  // MARK: One monitor per screen appearance

  @Test func aCancelledMonitorStopsAllFurtherCalls() async {
    let harness = Harness()
    harness.cli.configure { $0.activeOperations = [[operation("a", .start)]] }
    let clock = ManualClock()
    let monitor = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    await clock.waitForSleeper(until: sleeper(3))
    monitor.cancel()
    await monitor.value
    let callsAtCancel = harness.cli.calls

    clock.advance(by: .seconds(60))
    await Task.yield()

    #expect(harness.cli.calls == callsAtCancel)
  }

  @Test func aSecondMonitorPreflightsAndAsksTheAgentAgain() async {
    let harness = Harness()
    let clock = ManualClock()
    let first = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(1)
    first.cancel()
    await first.value
    #expect(harness.count(.activeOperations) == 1)

    let second = harness.startMonitor(clock: clock)
    await harness.rounds.waitForRounds(2)
    second.cancel()
    await second.value

    #expect(harness.count(.preflight) == 2)
    #expect(harness.count(.activeOperations) == 2)
  }

  // MARK: Templates and create

  @Test func availableTemplatesReturnsTheTemplatesLimaOffers() async throws {
    let harness = Harness()
    let templates = [try #require(MachineTemplate(id: "ubuntu")), try #require(MachineTemplate(id: "debian-13"))]
    harness.cli.configure { $0.listTemplates = [.success(templates)] }

    let result = await harness.controller.availableTemplates()

    #expect(result == .success(templates))
  }

  @Test func availableTemplatesPassesTheFailureThrough() async {
    let harness = Harness()
    harness.cli.configure { $0.listTemplates = [.failure(.nonZeroExit(code: 1, output: ["nope"]))] }
    let result = await harness.controller.availableTemplates()
    #expect(result == .failure(.nonZeroExit(code: 1, output: ["nope"])))
  }

  @Test func availableTemplatesDoesNotCallLimaWhileLimactlIsMissing() async {
    let harness = Harness()
    harness.cli.configure { $0.toolchain = missingLimactl }
    let result = await harness.controller.availableTemplates()
    #expect(result == .failure(.limactlMissing))
    #expect(harness.cli.calls == [.preflight])
  }

  @Test func canCreateFollowsWhetherLimactlIsFound() async {
    let harness = Harness()
    #expect(!harness.controller.canCreate)
    harness.cli.configure { $0.toolchain = missingLimactl }
    await harness.controller.refreshNow()
    #expect(!harness.controller.canCreate)
    harness.cli.configure { $0.toolchain = .found(path: "/opt/homebrew/bin/limactl") }
    await harness.controller.refreshNow()
    #expect(harness.controller.canCreate)
  }
}
