#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct VMControllerScene {
    let controller: VMController
    let cli: PreviewColimaCLI
    let files: PreviewColimaFileStore
    var rejectionReason: String?
    var retryResult: RecreateRequestResult?
  }

  @MainActor
  enum VMControllerPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case running
      case stopped
      case broken
      case absent
      case colimaMissing
      case unknown

      case starting
      case stopping
      case creating
      case startingNoOutputYet
      case startingSilentForAWhile
      case startingAbortable

      case startFailed
      case createFailed
      case createFailedMissingExecutables
      case startAborted
      case dataDiskMayRemain
      case dataDiskMayRemainRetryRefused

      case pendingStopFromWindow
      case pendingStopFromMenuBar
      case pendingRestart
      case pendingRecreate
      case confirmationRejected
    }

    static func make(_ scenario: Scenario) async -> VMControllerScene {
      let cli = PreviewColimaCLI()
      let files = PreviewColimaFileStore()
      let clock = PreviewClock()
      let controller = VMController(cli: cli, files: files, previewNow: { clock.now() })
      var scene = VMControllerScene(controller: controller, cli: cli, files: files)
      let steps = VMControllerSteps(scene: scene, clock: clock)

      switch scenario {
      case .running:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
      case .stopped:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
      case .broken:
        await steps.observe(.success(.present(PreviewVMData.instance(rawStatus: "Broken"))))
      case .absent:
        await steps.observe(.success(.absent))
      case .colimaMissing:
        cli.configure {
          $0.toolchain = ToolchainStatus(
            colima: .missing(searched: ["/opt/homebrew/bin", "/usr/local/bin"]),
            installedExecutables: [])
        }
        await steps.observe(.success(.absent))
      case .unknown:
        await steps.observe(
          .failure(
            .nonZeroExit(
              code: 1,
              output: [
                "level=fatal msg=\"error retrieving instances: cannot read the lima directory\""
              ])))

      case .starting:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        await steps.operate(.start, elapsed: 5, lastOutputAgo: 2, lines: PreviewVMData.startOutput)
      case .stopping:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
        await steps.operate(.stop, elapsed: 4, lastOutputAgo: 1, lines: PreviewVMData.stopOutput)
      case .creating:
        await steps.observe(.success(.absent))
        await steps.operate(
          .start, elapsed: 20, lastOutputAgo: 3, lines: PreviewVMData.createOutput)
      case .startingNoOutputYet:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        await steps.operate(.start, elapsed: 12, lastOutputAgo: 12, lines: [])
      case .startingSilentForAWhile:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        await steps.operate(
          .start, elapsed: 95, lastOutputAgo: 40, lines: PreviewVMData.startOutput)
      case .startingAbortable:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        await steps.operate(
          .start, elapsed: 200, lastOutputAgo: 60, lines: PreviewVMData.startOutput)

      case .startFailed:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        cli.configure { $0.runs = [.exits(code: 1, lines: PreviewVMData.startFailureOutput)] }
        steps.controller.start()
        await PreviewSettle.until("start failure kept") { steps.controller.lastFailure != nil }
      case .createFailed:
        await steps.observe(.success(.absent))
        cli.configure { $0.runs = [.exits(code: 1, lines: PreviewVMData.createFailureOutput)] }
        steps.controller.start()
        await PreviewSettle.until("create failure kept") { steps.controller.lastFailure != nil }
      case .createFailedMissingExecutables:
        files.configure {
          $0.profile = .success(
            ProfileSettings(
              resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 100), vmType: .qemu))
        }
        cli.configure {
          $0.toolchain = ToolchainStatus(
            colima: .found(path: "/opt/homebrew/bin/colima"), installedExecutables: ["krunkit"])
        }
        await steps.observe(.success(.absent))
        steps.controller.start()
        await PreviewSettle.until("preflight failure kept") { steps.controller.lastFailure != nil }
      case .startAborted:
        await steps.observe(.success(.present(PreviewVMData.instance(running: false))))
        await steps.operate(
          .start, elapsed: 200, lastOutputAgo: 60, lines: PreviewVMData.startOutput)
        steps.controller.abortOperation()
        await PreviewSettle.until("abort recorded") { steps.controller.lastFailure != nil }
      case .dataDiskMayRemain:
        await steps.observe(.success(.absent))
        await steps.failRecreateInDeleteStage(target: .vz)
      case .dataDiskMayRemainRetryRefused:
        await steps.observe(.success(.absent))
        await steps.failRecreateInDeleteStage(target: .qemu)
        cli.configure {
          $0.toolchain = ToolchainStatus(
            colima: .found(path: "/opt/homebrew/bin/colima"), installedExecutables: [])
        }
        scene.retryResult = await controller.requestRetryRecreate()

      case .pendingStopFromWindow:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
        controller.requestStop(from: .window)
      case .pendingStopFromMenuBar:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
        controller.requestStop(from: .menuBar)
      case .pendingRestart:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
        controller.requestRestart()
      case .pendingRecreate:
        await steps.observe(.success(.present(PreviewVMData.instance(running: true))))
        await steps.requestRecreate()
      case .confirmationRejected:
        scene.rejectionReason = await steps.provokeRejection()
      }
      return scene
    }
  }
#endif
