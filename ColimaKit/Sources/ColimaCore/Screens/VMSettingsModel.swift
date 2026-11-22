import Foundation
import Observation

public enum SaveOutcome: Sendable, Equatable { case appliesOnNextStart, restartRequired }

public enum SettingsPrimaryAction: Sendable, Equatable {
  case save, recreate, create
  case unavailable(reason: String)
}

public enum SettingsSubmitResult: Sendable, Equatable {
  case saved(SaveOutcome)
  /// The confirmation is pending in `VMController.pendingConfirmation`; nothing has been deleted yet.
  case recreateRequested
  case createStarted
  case invalid([SettingsFieldError])
  case busy
  case unavailable(reason: String)
  case recreateRejected(RecreatePlanError)
  case failed(reason: String)
}

/// One instance lives as long as the app; the screen calls `onAppear()` each time it is shown.
@MainActor @Observable
public final class VMSettingsModel {
  public var cpusText = ""
  public var memoryGiBText = ""
  public var diskGiBText = ""
  public private(set) var vmType: VMType = .vz
  public private(set) var fieldErrors: [SettingsFieldError] = []
  public private(set) var loadFailureReason: String?

  @ObservationIgnored private let controller: VMController
  @ObservationIgnored private let files: any ColimaFileStore
  private var profile: ProfileSettings?
  private var instanceVMType: InstanceVMTypeReading = .unreadable(reason: "")
  @ObservationIgnored private var loadedInput: SettingsFormInput?

  private enum InstanceVMTypeReading: Equatable {
    case known(VMType)
    case unreadable(reason: String)
  }

  public init(controller: VMController, files: any ColimaFileStore) {
    self.controller = controller
    self.files = files
    reloadFromFiles()
  }

  public var input: SettingsFormInput {
    SettingsFormInput(
      cpus: cpusText, memoryGiB: memoryGiBText, diskGiB: diskGiBText, vmType: vmType)
  }

  public var unappliedFields: Set<SettingsField> {
    guard case .present(let actual) = controller.observation, actual.runState.isRunning,
      let profile
    else { return [] }
    var fields: Set<SettingsField> = []
    if profile.resources.cpus != actual.cpus { fields.insert(.cpu) }
    if Self.bytes(gib: profile.resources.memoryGiB) != actual.memoryBytes { fields.insert(.memory) }
    if Self.bytes(gib: Double(profile.resources.diskGiB)) != actual.diskBytes {
      fields.insert(.disk)
    }
    if let fileType = profile.vmType, case .known(let actualType) = instanceVMType,
      fileType != actualType
    {
      fields.insert(.vmType)
    }
    return fields
  }

  /// The smallest disk a save accepts: the VM's current disk, since only a recreate can shrink it.
  public var diskFloorGiB: Int? {
    guard case .save = primaryAction, case .present(let actual) = controller.observation else { return nil }
    return Self.diskFloorGiB(of: actual)
  }

  private static func diskFloorGiB(of actual: VMInstance) -> Int {
    Int((actual.diskBytes + bytesPerGiB - 1) / bytesPerGiB)
  }

  public var primaryAction: SettingsPrimaryAction {
    switch controller.observation {
    case .unknown(let reason):
      return .unavailable(
        reason: String(localized: "Could not check the VM state: \(reason)", bundle: #bundle))
    case .absent:
      return .create
    case .present:
      switch instanceVMType {
      case .unreadable(let reason):
        return .unavailable(reason: reason)
      case .known(let actual):
        return vmType == actual ? .save : .recreate
      }
    }
  }

  public func missingExecutables(for type: VMType) -> [String] {
    controller.toolchain?.missingExecutables(for: type) ?? []
  }

  public func onAppear() async {
    await controller.redetectToolchain()
    reloadFromFiles()
  }

  /// The screen calls this when the observation changes to `.present`: a VM created or recreated meanwhile has a
  /// new state file.
  public func refreshInstanceVMType() {
    instanceVMType = readInstanceVMType()
  }

  public func selectVMType(_ type: VMType) async {
    guard type != vmType else { return }
    vmType = type
    await controller.redetectToolchain()
  }

  public func requestRestart() {
    controller.requestRestart()
  }

  /// The instance VM type is read again first so a stale display cannot turn into a save for a VM whose type is unknown.
  public func submit() async -> SettingsSubmitResult {
    guard controller.activeOperation == nil else { return .busy }
    refreshInstanceVMType()
    switch primaryAction {
    case .unavailable(let reason): return .unavailable(reason: reason)
    case .save: return save()
    case .recreate: return await recreate()
    case .create: return create()
    }
  }

  // MARK: Actions

  private func save() -> SettingsSubmitResult {
    guard case .present(let actual) = controller.observation else {
      return .unavailable(reason: String(localized: "Could not check the VM state.", bundle: #bundle))
    }
    guard let spec = validated(diskFloorGiB: Self.diskFloorGiB(of: actual)) else { return .invalid(fieldErrors) }
    do {
      try files.writeProfileSettings(spec.resources)
    } catch {
      ColimaLog.vm.error("saving the settings file failed")
      return .failed(reason: Self.describe(error))
    }
    loadedInput = input
    readProfile()
    return .saved(actual.runState.isRunning ? .restartRequired : .appliesOnNextStart)
  }

  private func recreate() async -> SettingsSubmitResult {
    guard case .known(let current) = instanceVMType else {
      return .unavailable(reason: String(localized: "Could not check the VM type.", bundle: #bundle))
    }
    guard let spec = validated(diskFloorGiB: nil) else { return .invalid(fieldErrors) }
    guard let plan = await makePlan(spec: spec, current: current) else {
      return .failed(reason: String(localized: "Could not check the executables.", bundle: #bundle))
    }
    switch plan {
    case .failure(let error):
      return .recreateRejected(error)
    case .success(let plan):
      switch await controller.requestRecreate(plan) {
      case .confirmationRequested: return .recreateRequested
      case .rejected(let error): return .recreateRejected(error)
      case .busy: return .busy
      case .nothingToRetry: return .failed(reason: String(localized: "Could not start recreating the VM.", bundle: #bundle))
      }
    }
  }

  /// A rejection for missing executables is checked once more against a fresh lookup: the user may have installed them since the display was last refreshed.
  private func makePlan(spec: VMCreateSpec, current: VMType) async -> Result<
    RecreatePlan, RecreatePlanError
  >? {
    if controller.toolchain == nil { await controller.redetectToolchain() }
    guard let toolchain = controller.toolchain else { return nil }
    let first = RecreatePlan.make(spec: spec, currentVMType: current, toolchain: toolchain)
    guard case .failure(.missingExecutables) = first else { return first }
    await controller.redetectToolchain()
    guard let fresh = controller.toolchain else { return nil }
    return RecreatePlan.make(spec: spec, currentVMType: current, toolchain: fresh)
  }

  private func create() -> SettingsSubmitResult {
    guard controller.isColimaFound else { return .failed(reason: String(localized: "colima was not found.", bundle: #bundle)) }
    guard let spec = validated(diskFloorGiB: nil) else { return .invalid(fieldErrors) }
    controller.create(spec)
    guard controller.activeOperation != nil else { return .failed(reason: String(localized: "Could not start creating the VM.", bundle: #bundle)) }
    return .createStarted
  }

  private func validated(diskFloorGiB: Int?) -> VMCreateSpec? {
    switch VMSettingsValidator.validate(input, diskFloorGiB: diskFloorGiB) {
    case .success(let spec):
      fieldErrors = []
      return spec
    case .failure(let failure):
      fieldErrors = failure.fields
      return nil
    }
  }

  // MARK: Files

  private func reloadFromFiles() {
    readProfile()
    refreshInstanceVMType()
    guard loadedInput == nil || input == loadedInput else { return }
    let fresh = initialInput()
    cpusText = fresh.cpus
    memoryGiBText = fresh.memoryGiB
    diskGiBText = fresh.diskGiB
    vmType = fresh.vmType
    loadedInput = fresh
  }

  private func readProfile() {
    do {
      profile = try files.readProfileSettings()
      loadFailureReason = nil
    } catch {
      ColimaLog.vm.error("settings file unreadable while loading the form")
      profile = nil
      loadFailureReason = String(localized: "Could not read the settings file, so defaults are shown. \(Self.describe(error))", bundle: #bundle)
    }
  }

  private func initialInput() -> SettingsFormInput {
    let resources: VMResourceSettings
    let type: VMType
    if let profile, let fileType = profile.vmType {
      resources = profile.resources
      type = fileType
    } else {
      let defaults = controller.creationDefaults()
      resources = profile?.resources ?? defaults.resources
      type = defaults.vmType
    }
    return SettingsFormInput(
      cpus: String(resources.cpus), memoryGiB: Self.text(gib: resources.memoryGiB),
      diskGiB: String(resources.diskGiB), vmType: type)
  }

  private func readInstanceVMType() -> InstanceVMTypeReading {
    do {
      guard let type = try files.readInstanceVMType() else {
        return .unreadable(reason: String(localized: "The VM type state file was not found.", bundle: #bundle))
      }
      return .known(type)
    } catch {
      return .unreadable(
        reason: String(localized: "Could not read the VM type. \(Self.describe(error))", bundle: #bundle))
    }
  }

  // MARK: Units

  private static let bytesPerGiB: Int64 = 1 << 30

  private static func bytes(gib: Double) -> Int64 {
    Int64((gib * Double(bytesPerGiB)).rounded())
  }

  private static func text(gib: Double) -> String {
    gib == gib.rounded() && gib < 1_000_000 ? String(Int(gib)) : String(gib)
  }

  private static func describe(_ error: ColimaFileError) -> String {
    switch error {
    case .unreadable(let path, let reason): String(localized: "Could not read \(path): \(reason)", bundle: #bundle)
    case .unexpectedFormat(let key, let reason):
      String(localized: "The format of \(key) in the settings file is not as expected: \(reason)", bundle: #bundle)
    case .writeFailed(let path, let reason): String(localized: "Could not write to \(path): \(reason)", bundle: #bundle)
    }
  }
}
