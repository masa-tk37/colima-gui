import Foundation

extension VMController {
  public func create(_ spec: VMCreateSpec) {
    guard activeOperation == nil, isColimaFound, case .absent = observation else { return }
    begin(.create(spec))
  }

  public func creationDefaults() -> VMCreateSpec {
    let profile = readProfileOrNil()
    let last = lastCreatedSpec
    let colima = CreationDefaults.colima

    let cpus = firstValid(
      .cpu, [last?.resources.cpus, profile?.resources.cpus].map { $0.map(String.init) }, colima.cpus
    )
    let memory = firstValid(
      .memory,
      [last?.resources.memoryGiB, profile?.resources.memoryGiB].map { $0.map { "\($0)" } },
      colima.memory)
    let disk = firstValid(
      .disk, [last?.resources.diskGiB, profile?.resources.diskGiB].map { $0.map(String.init) },
      colima.disk)
    let vmType = last?.vmType ?? profile?.vmType ?? colima.vmType

    let input = SettingsFormInput(cpus: cpus, memoryGiB: memory, diskGiB: disk, vmType: vmType)
    guard case .success(let spec) = VMSettingsValidator.validate(input, diskFloorGiB: nil) else {
      return CreationDefaults.colimaSpec
    }
    return spec
  }

  func performCreate(_ spec: VMCreateSpec) async -> StageFailure? {
    if let failure = await runPreflight(for: spec.vmType) { return failure }
    lastCreatedSpec = spec
    return await runStage(.creating, command: .create(spec))
  }

  func runPreflight(for vmType: VMType) async -> StageFailure? {
    activeOperation?.advance(to: .preflight, at: now())
    await detectToolchain()
    guard let toolchain, case .found = toolchain.colima else {
      return (.preflight, .launchFailed(reason: String(localized: "colima was not found", bundle: #bundle)))
    }
    let missing = toolchain.missingExecutables(for: vmType)
    return missing.isEmpty ? nil : (.preflight, .missingExecutables(vmType, missing))
  }

  private func readProfileOrNil() -> ProfileSettings? {
    do {
      return try files.readProfileSettings()
    } catch {
      ColimaLog.vm.error("settings file unreadable while choosing creation defaults")
      return nil
    }
  }

  private func firstValid(_ field: SettingsField, _ candidates: [String?], _ fallback: String)
    -> String
  {
    for candidate in candidates.compactMap({ $0 }) where isValid(candidate, for: field) {
      return candidate
    }
    return fallback
  }

  private func isValid(_ text: String, for field: SettingsField) -> Bool {
    let colima = CreationDefaults.colima
    let input = SettingsFormInput(
      cpus: field == .cpu ? text : colima.cpus,
      memoryGiB: field == .memory ? text : colima.memory,
      diskGiB: field == .disk ? text : colima.disk,
      vmType: colima.vmType)
    if case .success = VMSettingsValidator.validate(input, diskFloorGiB: nil) { return true }
    return false
  }
}

/// Colima 0.10.3's defaults for `colima start`.
private enum CreationDefaults {
  static let colima = (cpus: "2", memory: "2", disk: "100", vmType: VMType.vz)
  static let colimaSpec = VMCreateSpec(
    resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 100), vmType: .vz)
}
