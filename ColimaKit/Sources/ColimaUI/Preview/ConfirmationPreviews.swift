#if DEBUG
  import ColimaCore
  import Foundation

  @MainActor
  struct ConfirmationScene {
    let request: ConfirmationRequest?
    let rejectionReason: String?
    let confirm: (ConfirmationRequest.ID) -> ConfirmationOutcome
    let dismiss: () -> Void
  }

  @MainActor
  enum ConfirmationPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case stopFromWindow
      case stopFromMenuBar
      case restartVM
      case recreateVM
      case deleteContainer
      case pruneVolumes
      case pruneNetworks
      case approvalRejected
    }

    static func make(_ scenario: Scenario) async -> ConfirmationScene {
      switch scenario {
      case .stopFromWindow: return await fromController(.pendingStopFromWindow)
      case .stopFromMenuBar: return await fromController(.pendingStopFromMenuBar)
      case .restartVM: return await fromController(.pendingRestart)
      case .recreateVM: return await fromController(.pendingRecreate)
      case .approvalRejected:
        let vm = await VMControllerPreviews.make(.confirmationRejected)
        return ConfirmationScene(
          request: nil, rejectionReason: vm.rejectionReason,
          confirm: { vm.controller.confirm(id: $0) },
          dismiss: { vm.controller.dismissConfirmation() })
      case .deleteContainer:
        let scene = await ContainerStorePreviews.make(.pendingDelete)
        return ConfirmationScene(
          request: scene.store.pendingConfirmation, rejectionReason: nil,
          confirm: { scene.store.confirm(id: $0) }, dismiss: { scene.store.dismissConfirmation() })
      case .pruneVolumes:
        let scene = await VolumeStorePreviews.make(.pendingPrune)
        return ConfirmationScene(
          request: scene.store.pendingConfirmation, rejectionReason: nil,
          confirm: { scene.store.confirm(id: $0) }, dismiss: { scene.store.dismissConfirmation() })
      case .pruneNetworks:
        let scene = await NetworkStorePreviews.make(.pendingPrune)
        return ConfirmationScene(
          request: scene.store.pendingConfirmation, rejectionReason: nil,
          confirm: { scene.store.confirm(id: $0) }, dismiss: { scene.store.dismissConfirmation() })
      }
    }

    private static func fromController(_ scenario: VMControllerPreviews.Scenario) async
      -> ConfirmationScene
    {
      let vm = await VMControllerPreviews.make(scenario)
      return ConfirmationScene(
        request: vm.controller.pendingConfirmation, rejectionReason: nil,
        confirm: { vm.controller.confirm(id: $0) }, dismiss: { vm.controller.dismissConfirmation() }
      )
    }
  }
#endif
