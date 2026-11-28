import Foundation

public enum SettingsField: Sendable { case cpu, memory, disk, vmType }

public struct SettingsFieldError: Sendable, Equatable {
  public let field: SettingsField
  public let message: String

  public init(field: SettingsField, message: String) {
    self.field = field
    self.message = message
  }
}

public struct SettingsFormInput: Sendable, Equatable {
  public var cpus: String
  public var memoryGiB: String
  public var diskGiB: String
  public var vmType: VMType

  public init(cpus: String, memoryGiB: String, diskGiB: String, vmType: VMType) {
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    self.diskGiB = diskGiB
    self.vmType = vmType
  }
}

public struct SettingsValidationFailure: Error, Equatable {
  public let fields: [SettingsFieldError]
}

public enum VMSettingsValidator {
  /// `diskFloorGiB` is the actual VM disk for a save without recreation; pass `nil` for recreate and create.
  public static func validate(
    _ input: SettingsFormInput,
    diskFloorGiB: Int?
  ) -> Result<VMCreateSpec, SettingsValidationFailure> {
    var errors: [SettingsFieldError] = []

    let cpus = parseWholeNumber(input.cpus)
    if cpus == nil {
      errors.append(SettingsFieldError(field: .cpu, message: String(localized: "Enter a whole number of 1 or more for CPU.", bundle: #bundle)))
    }

    let memory = parseDecimal(input.memoryGiB)
    if memory == nil {
      errors.append(SettingsFieldError(field: .memory, message: String(localized: "Enter a number of 1 or more (GiB) for memory.", bundle: #bundle)))
    }

    let disk = parseWholeNumber(input.diskGiB)
    if let disk {
      if let floor = diskFloorGiB, disk < floor {
        errors.append(
          SettingsFieldError(
            field: .disk,
            message: String(localized: "The disk cannot be smaller than the current \(floor) GiB. To shrink it, recreate the VM.", bundle: #bundle)
          ))
      }
    } else {
      errors.append(SettingsFieldError(field: .disk, message: String(localized: "Enter a whole number of 1 or more (GiB) for the disk.", bundle: #bundle)))
    }

    guard errors.isEmpty, let cpus, let memory, let disk else {
      return .failure(SettingsValidationFailure(fields: errors))
    }
    let resources = VMResourceSettings(cpus: cpus, memoryGiB: memory, diskGiB: disk)
    return .success(VMCreateSpec(resources: resources, vmType: input.vmType))
  }

  /// ASCII digits only: `Int(_:)` would also accept a leading `+`, and `Character.isNumber` accepts non-ASCII digits.
  static func parseWholeNumber(_ text: String) -> Int? {
    let body = text.trimmingWhitespace()
    guard isASCIIDigits(body), let value = Int(body), value >= 1 else { return nil }
    return value
  }

  /// Plain decimal notation only: `Double(_:)` would also accept `nan`, `inf`, exponents, and hex floats.
  static func parseDecimal(_ text: String) -> Double? {
    let body = text.trimmingWhitespace()
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.allSatisfy({ isASCIIDigits($0) }),
      let value = Double(body), value.isFinite, value >= 1
    else { return nil }
    return value
  }

  private static func isASCIIDigits(_ text: some StringProtocol) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isWholeNumber }
  }
}

extension String {
  fileprivate func trimmingWhitespace() -> String {
    let start = firstIndex { !$0.isWhitespace } ?? endIndex
    let end = lastIndex { !$0.isWhitespace }.map { index(after: $0) } ?? startIndex
    return start < end ? String(self[start..<end]) : ""
  }
}
