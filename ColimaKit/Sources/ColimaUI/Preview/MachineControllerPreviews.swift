#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct MachineControllerScene {
    let controller: MachineController
    let cli: PreviewLimaCLI
  }

  @MainActor
  enum MachineControllerPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case noMachines
      case limactlMissing
      case listFailed
      case mixed
      case brokenRow

      case creating
      case createCancelRequested
      case createCancelled
      case createFailed
      case starting
      case startFailed
      case earlierSession

      case pendingMemoryWarning
      case pendingDeleteRunning
      case pendingDeleteStopped
    }

    static let createInput = MachineFormInput(
      name: PreviewMachineData.creating.rawValue, templateID: "ubuntu", cpus: "2", memoryGiB: "4", diskGiB: "50")

    static func make(_ scenario: Scenario) async -> MachineControllerScene {
      let cli = PreviewLimaCLI()
      let host = scenario == .pendingMemoryWarning ? PreviewMachineData.constrainedHost : PreviewMachineData.host
      let controller = MachineController(
        cli: cli, host: host, homeDirectory: PreviewMachineData.homeDirectory, directoryExists: { _ in true })
      let scene = MachineControllerScene(controller: controller, cli: cli)

      switch scenario {
      case .noMachines:
        await scene.read(PreviewMachineData.emptyListing)
      case .limactlMissing:
        cli.configure {
          $0.toolchain = .missing(searched: PreviewMachineData.limactlSearched)
          $0.listing = .failure(.limactlMissing)
        }
        await controller.refreshNow()
      case .listFailed:
        cli.configure { $0.listing = .failure(.nonZeroExit(code: 1, output: PreviewMachineData.listFailureOutput)) }
        await controller.refreshNow()
      case .mixed:
        await scene.read(PreviewMachineData.mixedListing)
      case .brokenRow:
        await scene.read(PreviewMachineData.brokenListing)

      case .creating:
        await scene.read(PreviewMachineData.mixedListing)
        await scene.create()
      case .createCancelRequested:
        cli.configure { $0.terminateEndsRun = false }
        await scene.read(PreviewMachineData.mixedListing)
        await scene.create()
        await scene.cancelCreate()
      case .createCancelled:
        await scene.read(PreviewMachineData.mixedListing)
        await scene.create()
        await scene.cancelCreate()
        await PreviewSettle.until("the cancelled create was reported") { controller.notice != nil }
      case .createFailed:
        cli.configure { $0.runs = [.exits(code: 1, lines: PreviewMachineData.createFailureOutput)] }
        await scene.read(PreviewMachineData.mixedListing)
        await scene.startCreate()
        await PreviewSettle.until("the create failure was kept") { !controller.failures.isEmpty }
      case .starting:
        await scene.read(PreviewMachineData.mixedListing)
        controller.requestStart(PreviewMachineData.stopped)
        await scene.showOutput(PreviewMachineData.startOutput, of: PreviewMachineData.stopped)
      case .startFailed:
        cli.configure { $0.runs = [.exits(code: 1, lines: PreviewMachineData.startFailureOutput)] }
        await scene.read(PreviewMachineData.mixedListing)
        controller.requestStart(PreviewMachineData.stopped)
        await PreviewSettle.until("the start failure was kept") { !controller.failures.isEmpty }
      case .earlierSession:
        cli.configure {
          $0.listing = .success(PreviewMachineData.mixedListing)
          $0.earlierOperations = [
            ActiveMachineOperation(runID: UUID(), name: PreviewMachineData.creating, kind: .create),
            ActiveMachineOperation(runID: UUID(), name: PreviewMachineData.stopped, kind: .start),
          ]
        }
        let monitoring = Task { await controller.monitor() }
        await PreviewSettle.until("the earlier session's operations were applied") {
          controller.operations.count == 2
        }
        monitoring.cancel()
        await monitoring.value

      case .pendingMemoryWarning:
        await scene.read(PreviewMachineData.mixedListing)
        controller.requestStart(PreviewMachineData.stopped)
      case .pendingDeleteRunning:
        await scene.read(PreviewMachineData.mixedListing)
        controller.requestDelete(PreviewMachineData.running)
      case .pendingDeleteStopped:
        await scene.read(PreviewMachineData.mixedListing)
        controller.requestDelete(PreviewMachineData.stopped)
      }
      return scene
    }
  }

  extension MachineControllerScene {
    fileprivate func read(_ listing: LimaListing) async {
      cli.configure { $0.listing = .success(listing) }
      await controller.refreshNow()
    }

    fileprivate func create() async {
      await startCreate()
      await showOutput(PreviewMachineData.createOutput, of: PreviewMachineData.creating)
    }

    fileprivate func startCreate() async {
      let templates = (try? await cli.listTemplates()) ?? []
      _ = await controller.create(MachineControllerPreviews.createInput, templates: templates)
    }

    fileprivate func cancelCreate() async {
      let name = PreviewMachineData.creating
      await PreviewSettle.until("the create could be cancelled") { controller.canCancelCreate(name) }
      controller.cancelCreate(name)
    }

    fileprivate func showOutput(_ lines: [String], of name: MachineName) async {
      await PreviewSettle.until("the operation reached its child process") { cli.runCount == 1 }
      lines.forEach(cli.emit)
      await PreviewSettle.until("the output was recorded") {
        controller.records[name.key]?.lines.count == lines.count
      }
    }
  }
#endif
