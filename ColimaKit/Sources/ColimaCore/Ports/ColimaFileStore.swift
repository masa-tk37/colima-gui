public protocol ColimaFileStore: Sendable {
  /// `nil` when `colima.yaml` is absent.
  func readProfileSettings() throws(ColimaFileError) -> ProfileSettings?
  func writeProfileSettings(_ settings: VMResourceSettings) throws(ColimaFileError)
  func readInstanceVMType() throws(ColimaFileError) -> VMType?
}

public struct ProfileSettings: Sendable, Equatable {
  public let resources: VMResourceSettings
  public let vmType: VMType?

  public init(resources: VMResourceSettings, vmType: VMType?) {
    self.resources = resources
    self.vmType = vmType
  }
}

public enum ColimaFileError: Error, Equatable {
  case unreadable(path: String, reason: String)
  /// A key is missing, duplicated, or not a scalar on column 0.
  case unexpectedFormat(key: String, reason: String)
  case writeFailed(path: String, reason: String)
}
