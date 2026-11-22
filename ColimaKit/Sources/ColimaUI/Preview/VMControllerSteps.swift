#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct VMControllerSteps {
    enum Operation { case start, stop }

    let scene: VMControllerScene
    let clock: PreviewClock

    var controller: VMController { scene.controller }

    func observe(_ observation: Result<VMObservation, ColimaCLIError>) async {
      scene.cli.configure { $0.observation = observation }
      await controller.redetectToolchain()
    }

    /// The shift has to last until the output has landed: the controller stamps the stage when its task first runs and each line when it arrives.
    func operate(
      _ operation: Operation, elapsed: TimeInterval, lastOutputAgo: TimeInterval, lines: [String]
    ) async {
      clock.shift(secondsAgo: elapsed)
      switch operation {
      case .start:
        controller.start()
      case .stop:
        controller.requestStop(from: .window)
        if let id = controller.pendingConfirmation?.id { controller.confirm(id: id) }
      }
      await PreviewSettle.until("the operation reached its child process") {
        scene.cli.runCount == 1
      }
      clock.shift(secondsAgo: lastOutputAgo)
      lines.forEach(scene.cli.emit)
      await PreviewSettle.until("the output was recorded") {
        controller.latestRecord?.lines.count == lines.count
      }
      clock.shift(secondsAgo: 0)
    }

    func recreatePlan(into target: VMType) -> RecreatePlan? {
      let input = SettingsFormInput(cpus: "2", memoryGiB: "4", diskGiB: "100", vmType: target)
      guard case .success(let spec) = VMSettingsValidator.validate(input, diskFloorGiB: nil),
        let toolchain = controller.toolchain,
        case .success(let plan) = RecreatePlan.make(
          spec: spec, currentVMType: target == .vz ? .qemu : .vz, toolchain: toolchain)
      else { return nil }
      return plan
    }

    func requestRecreate(into target: VMType = .vz) async {
      guard let plan = recreatePlan(into: target) else { return }
      _ = await controller.requestRecreate(plan)
    }

    func failRecreateInDeleteStage(target: VMType) async {
      scene.cli.configure { $0.runs = [.exits(code: 1, lines: PreviewVMData.deleteFailureOutput)] }
      await requestRecreate(into: target)
      guard let id = controller.pendingConfirmation?.id else { return }
      controller.confirm(id: id)
      await PreviewSettle.until("delete failure kept") { controller.dataDiskMayRemain }
    }

    func provokeRejection() async -> String? {
      await observe(.success(.present(PreviewVMData.instance(running: true))))
      controller.requestStop(from: .window)
      guard let id = controller.pendingConfirmation?.id else { return nil }
      await observe(.success(.present(PreviewVMData.instance(running: false))))
      controller.start()
      guard case .rejectedBusy(let reason) = controller.confirm(id: id) else { return nil }
      await PreviewSettle.until("the start reached its child process") { scene.cli.runCount == 1 }
      scene.cli.finishRun(code: 0)
      await PreviewSettle.until("the start ended") { controller.activeOperation == nil }
      return reason
    }
  }
#endif
