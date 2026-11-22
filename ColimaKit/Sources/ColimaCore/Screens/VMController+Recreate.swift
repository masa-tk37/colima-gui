import Foundation

extension VMController {
  /// Looks the executables up again without taking the operation slot, so the menu bar keeps showing the observed state meanwhile.
  public func requestRecreate(_ plan: RecreatePlan) async -> RecreateRequestResult {
    await requestConfirmation(for: plan)
  }

  /// The plan cannot be rebuilt from the settings file because the VM and its configuration may already be gone.
  /// Asks for a fresh confirmation: the earlier approval covered the earlier attempt only.
  public func requestRetryRecreate() async -> RecreateRequestResult {
    guard activeOperation == nil else { return .busy }
    guard canRetryRecreate, let plan = lastRecreatePlan else { return .nothingToRetry }
    return await requestConfirmation(for: plan)
  }

  /// `lastRecreatePlan` is not observed; it is set before the failure this reads, so `lastFailure` drives updates.
  public var canRetryRecreate: Bool {
    lastFailure?.stage == .deleting && lastRecreatePlan != nil
  }

  private func requestConfirmation(for plan: RecreatePlan) async -> RecreateRequestResult {
    guard activeOperation == nil else { return .busy }
    await detectToolchain()
    guard activeOperation == nil else { return .busy }

    guard let toolchain, case .found = toolchain.colima else {
      return .rejected(.missingExecutables(vmType: plan.spec.vmType, missing: ["colima"]))
    }
    switch RecreatePlan.make(
      spec: plan.spec, currentVMType: plan.currentVMType, toolchain: toolchain)
    {
    case .failure(let error):
      return .rejected(error)
    case .success(let valid):
      pendingConfirmation = Self.recreateConfirmation(for: valid)
      return .confirmationRequested
    }
  }

  func performRecreate(_ plan: RecreatePlan) async -> StageFailure? {
    if let failure = await runPreflight(for: plan.spec.vmType) { return failure }
    if let failure = await runStage(.deleting, command: .delete) { return failure }

    // Exit code 0 does not prove the VM is gone; creating over a surviving one would not apply the new VM type.
    await refreshNow()
    switch observation {
    case .absent: break
    case .present: return (.deleting, .stillPresentAfterDelete)
    case .unknown: return (.deleting, .deleteNotConfirmed)
    }

    lastCreatedSpec = plan.spec
    return await runStage(.creating, command: .create(plan.spec))
  }

  private static func recreateConfirmation(for plan: RecreatePlan) -> ConfirmationRequest {
    ConfirmationRequest(
      intent: .recreateVM(plan),
      origin: .window,
      title: String(localized: "Delete and recreate the VM?", bundle: #bundle),
      message: String(
        localized: """
          Changing the VM type from \(plan.currentVMType.rawValue) to \(plan.spec.vmType.rawValue) deletes the VM and recreates it. \
          All containers, images, and volumes in the VM are lost and cannot be recovered. \
          Colima settings other than the VM type, such as mounts and networks, return to their defaults.
          """, bundle: #bundle),
      itemGroups: [],
      confirmLabel: String(localized: "Delete and recreate", bundle: #bundle)
    )
  }
}
