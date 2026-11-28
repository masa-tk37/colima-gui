import Foundation

public enum MachineSpecValidator {
  public static func validateCreate(
    _ input: MachineFormInput, context: MachineCreateContext
  ) -> Result<MachineCreateSpec, MachineValidationFailure> {
    var errors: [MachineFieldError] = []

    let name = parseName(input.name, context: context)
    if case .failure(let problem) = name { errors.append(nameError(problem)) }

    let template = input.templateID.flatMap(MachineTemplate.init(id:)).flatMap { context.templates.contains($0) ? $0 : nil }
    if template == nil {
      errors.append(MachineFieldError(field: .template, message: String(localized: "Choose a distribution.", bundle: #bundle)))
    }

    let resources = parseResources(input.cpus, input.memoryGiB, input.diskGiB, host: context.host, currentDiskBytes: nil)
    errors += resources.errors

    guard errors.isEmpty, case .success(let name) = name, let template, let resources = resources.value else {
      return .failure(MachineValidationFailure(fields: errors))
    }
    let home = MachineMount(path: context.homeDirectory, writable: true)
    return .success(MachineCreateSpec(name: name, template: template, resources: resources, mounts: [home]))
  }

  /// A folder the machine already shares need not exist now: an unplugged volume must not block a CPU change.
  public static func validateEdit(
    _ input: MachineEditInput, currentDiskBytes: Int64, currentMounts: [MachineMount] = [], host: HostResources,
    directoryExists: (String) -> Bool
  ) -> Result<MachineEditSpec, MachineValidationFailure> {
    let resources = parseResources(
      input.cpus, input.memoryGiB, input.diskGiB, host: host, currentDiskBytes: currentDiskBytes)
    let alreadyShared = Set(currentMounts.map(\.path))
    let errors =
      resources.errors
      + mountErrors(input.mounts, directoryExists: { alreadyShared.contains($0) || directoryExists($0) })

    guard errors.isEmpty, let resources = resources.value else {
      return .failure(MachineValidationFailure(fields: errors))
    }
    return .success(MachineEditSpec(resources: resources, mounts: input.mounts))
  }

  // MARK: name

  private static func parseName(_ text: String, context: MachineCreateContext) -> Result<MachineName, MachineNameProblem> {
    switch MachineName.parse(text, limaHomeUTF8Count: context.limaHomeUTF8Count) {
    case .failure(let problem):
      return .failure(problem)
    case .success(let name):
      let key = name.key
      if MachineName.reservedKeys.contains(key) { return .failure(.conflictsWithDefaultVM) }
      if context.appMachineKeys.contains(key) { return .failure(.duplicate) }
      if context.unownedMachineKeys.contains(key) { return .failure(.conflictsWithExternalInstance) }
      return .success(name)
    }
  }

  private static func nameError(_ problem: MachineNameProblem) -> MachineFieldError {
    MachineFieldError(field: .name, message: message(for: problem))
  }

  private static func message(for problem: MachineNameProblem) -> String {
    switch problem {
    case .empty:
      String(localized: "Enter a name.", bundle: #bundle)
    case .invalidCharacters:
      String(
        localized: "Use only letters, digits, and single \".\", \"_\", or \"-\" between them. The name cannot end in .yml or .yaml.",
        bundle: #bundle)
    case .tooLong(let maxLength):
      String(localized: "The name can be at most \(maxLength) characters.", bundle: #bundle)
    case .duplicate:
      String(localized: "A machine with this name already exists.", bundle: #bundle)
    case .conflictsWithDefaultVM:
      String(localized: "This name is reserved for the default VM.", bundle: #bundle)
    case .conflictsWithExternalInstance:
      String(localized: "A Lima instance with a conflicting name already exists.", bundle: #bundle)
    }
  }

  // MARK: resources

  private static let bytesPerGiB: Int64 = 1 << 30

  /// `currentDiskBytes` is nil on create; on edit it is the disk floor and the size that stays valid above the host limit.
  private static func parseResources(
    _ cpusText: String, _ memoryText: String, _ diskText: String, host: HostResources, currentDiskBytes: Int64?
  ) -> (value: MachineResources?, errors: [MachineFieldError]) {
    var errors: [MachineFieldError] = []

    var cpus = VMSettingsValidator.parseWholeNumber(cpusText)
    if cpus == nil {
      errors.append(fieldError(.cpu, String(localized: "Enter a whole number of 1 or more for CPU.", bundle: #bundle)))
    } else if let value = cpus, value > host.cpus {
      cpus = nil
      errors.append(fieldError(.cpu, String(localized: "CPU can be at most \(host.cpus) on this Mac.", bundle: #bundle)))
    }

    var memory = VMSettingsValidator.parseDecimal(memoryText)
    if memory == nil {
      errors.append(fieldError(.memory, String(localized: "Enter a number of 1 or more (GiB) for memory.", bundle: #bundle)))
    } else if let value = memory, value * Double(bytesPerGiB) > Double(host.memoryBytes) {
      memory = nil
      errors.append(
        fieldError(.memory, String(localized: "Memory can be at most \(host.memoryGiB) GiB on this Mac.", bundle: #bundle)))
    }

    var disk = VMSettingsValidator.parseWholeNumber(diskText)
    if disk == nil {
      errors.append(fieldError(.disk, String(localized: "Enter a whole number of 1 or more (GiB) for the disk.", bundle: #bundle)))
    } else if let value = disk, let error = diskError(value, host: host, currentDiskBytes: currentDiskBytes) {
      disk = nil
      errors.append(error)
    }

    guard let cpus, let memory, let disk else { return (nil, errors) }
    return (MachineResources(cpus: cpus, memoryGiB: memory, diskGiB: disk), errors)
  }

  private static func diskError(_ disk: Int, host: HostResources, currentDiskBytes: Int64?) -> MachineFieldError? {
    let currentGiB = currentDiskBytes.map { Int(($0 + bytesPerGiB - 1) / bytesPerGiB) }
    if let currentGiB, disk < currentGiB {
      return fieldError(
        .disk,
        String(
          localized: "The disk can only be expanded. It cannot be smaller than the current \(currentGiB) GiB.",
          bundle: #bundle))
    }
    if disk > host.diskGiB, disk > (currentGiB ?? 0) {
      return fieldError(.disk, String(localized: "The disk can be at most \(host.diskGiB) GiB on this Mac.", bundle: #bundle))
    }
    return nil
  }

  private static func fieldError(_ field: MachineField, _ message: String) -> MachineFieldError {
    MachineFieldError(field: field, message: message)
  }

  // MARK: mounts

  private static func mountErrors(_ mounts: [MachineMount], directoryExists: (String) -> Bool) -> [MachineFieldError] {
    let components = mounts.map { normalizedComponents($0.path) }
    var errors: [MachineFieldError] = []
    for (index, mount) in mounts.enumerated() {
      let field = MachineField.mount(index: index)
      if !mount.path.hasPrefix("/") {
        errors.append(fieldError(field, String(localized: "Enter an absolute path.", bundle: #bundle)))
      } else if mount.path.contains("{{") {
        errors.append(fieldError(field, String(localized: "The path cannot contain \"{{\".", bundle: #bundle)))
      } else if !directoryExists(mount.path) {
        errors.append(fieldError(field, String(localized: "This folder does not exist.", bundle: #bundle)))
      } else if components[..<index].contains(where: { overlaps($0, components[index]) }) {
        errors.append(
          fieldError(field, String(localized: "This folder overlaps another shared folder.", bundle: #bundle)))
      }
    }
    return errors
  }

  private static func normalizedComponents(_ path: String) -> [Substring] {
    var result: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." {
        _ = result.popLast()
      } else {
        result.append(part)
      }
    }
    return result
  }

  private static func overlaps(_ a: [Substring], _ b: [Substring]) -> Bool {
    let shared = min(a.count, b.count)
    return a[..<shared] == b[..<shared]
  }
}
