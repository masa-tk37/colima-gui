/// The initializer is `internal` on purpose: `make` is the only way in, so a plan that targets the
/// current VM type or a VM type whose executables are missing cannot exist.
public struct RecreatePlan: Sendable, Equatable {
  public let spec: VMCreateSpec
  public let currentVMType: VMType
}

public enum RecreatePlanError: Error, Equatable {
  case sameVMType
  case missingExecutables(vmType: VMType, missing: [String])
}

public enum RecreateRequestResult: Sendable, Equatable {
  case confirmationRequested
  case rejected(RecreatePlanError)
  case busy
  /// A retry was requested while the last failure was not a failed delete stage; no request was created.
  case nothingToRetry
}

extension RecreatePlan {
  /// Disk shrinking is accepted: recreation starts from a fresh disk.
  public static func make(
    spec: VMCreateSpec,
    currentVMType: VMType,
    toolchain: ToolchainStatus
  ) -> Result<RecreatePlan, RecreatePlanError> {
    guard spec.vmType != currentVMType else {
      return .failure(.sameVMType)
    }
    let missing = toolchain.missingExecutables(for: spec.vmType)
    guard missing.isEmpty else {
      return .failure(.missingExecutables(vmType: spec.vmType, missing: missing))
    }
    return .success(RecreatePlan(spec: spec, currentVMType: currentVMType))
  }
}
