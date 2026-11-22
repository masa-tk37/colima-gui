public struct VMResourceSettings: Sendable, Equatable {
  public let cpus: Int
  public let memoryGiB: Double
  public let diskGiB: Int

  public init(cpus: Int, memoryGiB: Double, diskGiB: Int) {
    self.cpus = cpus
    self.memoryGiB = memoryGiB
    self.diskGiB = diskGiB
  }
}

/// The initializer is `internal` on purpose: outside `ColimaCore` the only sources are
/// `VMSettingsValidator.validate` and `VMController.creationDefaults()`, so an unvalidated
/// value can never reach `colima start`.
public struct VMCreateSpec: Sendable, Equatable {
  public let resources: VMResourceSettings
  public let vmType: VMType
}
