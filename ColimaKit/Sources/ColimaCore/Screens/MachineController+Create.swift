import Foundation

public enum MachineCreateOutcome: Sendable, Equatable {
  case started
  case invalid(MachineValidationFailure)
  case busy
}

extension MachineController {
  /// The slot is taken before the first suspension, so a second create of the same name cannot also pass.
  public func create(_ input: MachineFormInput, templates offered: [MachineTemplate]) async -> MachineCreateOutcome {
    let templates = isLimactlFound ? offered : []
    if case .success(let name) = MachineName.parse(input.name, limaHomeUTF8Count: cli.limaHomeUTF8Count),
      operations[name.key]?.kind == .create
    {
      return .busy
    }

    let spec: MachineCreateSpec
    switch validate(
      input, templates: templates, machineKeys: listedKeys(in: listing),
      unownedKeys: listing?.unownedMachineKeys ?? [])
    {
    case .failure(let failure): return .invalid(failure)
    case .success(let validated): spec = validated
    }

    let key = spec.name.key
    operations[key] = MachineOperationProgress(kind: .create, origin: .thisSession(startedAt: Date()))
    creatingNames[key] = spec.name

    // A failed read leaves the check to the agent and Lima, which refuse an existing instance without touching it.
    if let fresh = try? await cli.listInstances() {
      let recheck = validate(
        input, templates: templates, machineKeys: listedKeys(in: fresh, ownSlot: key),
        unownedKeys: fresh.unownedMachineKeys)
      if case .failure(let failure) = recheck {
        operations[key] = nil
        creatingNames[key] = nil
        return .invalid(failure)
      }
    }

    begin(.create(spec))
    return .started
  }

  private func listedKeys(in listing: LimaListing?, ownSlot: MachineKey? = nil) -> Set<MachineKey> {
    let listed = (listing?.machines ?? []).map(\.name.key)
    let held = operations.keys.filter { $0 != ownSlot }
    return Set(listed).union(held)
  }

  private func validate(
    _ input: MachineFormInput, templates: [MachineTemplate], machineKeys: Set<MachineKey>,
    unownedKeys: Set<MachineKey>
  ) -> Result<MachineCreateSpec, MachineValidationFailure> {
    MachineSpecValidator.validateCreate(
      input,
      context: MachineCreateContext(
        host: host, homeDirectory: homeDirectory, limaHomeUTF8Count: cli.limaHomeUTF8Count,
        appMachineKeys: machineKeys, unownedMachineKeys: unownedKeys, templates: templates))
  }
}
