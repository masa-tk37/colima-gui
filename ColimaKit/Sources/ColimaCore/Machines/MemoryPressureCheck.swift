import Foundation

public struct MemoryWarning: Sendable, Equatable {
  public let totalBytes: Int64
  public let physicalBytes: Int64
  public let thresholdBytes: Int64
}

public enum MemoryPressureCheck {
  public static func thresholdBytes(physicalBytes: Int64) -> Int64 {
    physicalBytes * 3 / 4
  }

  /// Nil when the default VM adds nothing to the total.
  ///
  /// `VMDisplayState` reads a restart's stop stage and a recreate's delete stage as stopping and a
  /// create reads as absent, so the rule works from the operation kind and the observation instead.
  public static func defaultVMBytes(
    operationKind: VMOperationKind?, observation: VMObservation, createSpec: VMCreateSpec?
  ) -> Int64? {
    switch operationKind {
    case .create, .recreate:
      return createSpec.map { Int64(($0.resources.memoryGiB * Double(1 << 30)).rounded()) }
    case .start, .restart:
      guard case .present(let instance) = observation else { return nil }
      return instance.memoryBytes
    case .stop, nil:
      guard case .present(let instance) = observation, instance.runState.isRunning else {
        return nil
      }
      return instance.memoryBytes
    }
  }

  public static func evaluate(
    defaultVMBytes: Int64?, otherMachineBytes: [Int64], targetBytes: Int64, physicalBytes: Int64
  ) -> MemoryWarning? {
    let total = (defaultVMBytes ?? 0) + otherMachineBytes.reduce(0, +) + targetBytes
    let threshold = thresholdBytes(physicalBytes: physicalBytes)
    guard total > threshold else { return nil }
    return MemoryWarning(totalBytes: total, physicalBytes: physicalBytes, thresholdBytes: threshold)
  }
}
