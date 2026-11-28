import Foundation

/// Case-folded display name without the prefix; identity on case-insensitive APFS.
public struct MachineKey: Sendable, Hashable {
  public let rawValue: String

  init(foldingDisplayName displayName: String) {
    rawValue = displayName.lowercased()
  }

  /// A name without the prefix cannot share a directory with a machine, so it has no key.
  public init?(unownedInstanceName: String) {
    let prefix = MachineName.instancePrefix
    guard unownedInstanceName.prefix(prefix.count).lowercased() == prefix else { return nil }
    self.init(foldingDisplayName: String(unownedInstanceName.dropFirst(prefix.count)))
  }
}
