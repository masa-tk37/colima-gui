import Foundation

public enum MachineNameProblem: Error, Sendable, Equatable {
  case empty
  case invalidCharacters
  case tooLong(maxLength: Int)
  case duplicate
  case conflictsWithDefaultVM
  /// An unowned `~/.lima` instance named `cg-<name>`, in any case.
  case conflictsWithExternalInstance
}

public struct MachineName: Sendable, Hashable {
  public static let instancePrefix = "cg-"

  /// `default` is Colima's profile name and `colima` its Lima instance name.
  public static let reservedKeys: Set<MachineKey> = [
    MachineKey(foldingDisplayName: "default"),
    MachineKey(foldingDisplayName: "colima"),
  ]

  /// Lima's `instance.Create` requires `<LIMA_HOME>/<instance>/ssh.sock.1234567890123456` to stay under 104 bytes,
  /// and caps the instance name at 76.
  private static let socketPathBudget = 103
  private static let socketPathSuffixLength = 27
  private static let maxInstanceNameLength = 76

  public let rawValue: String

  public var instanceName: String { Self.instancePrefix + rawValue }
  public var key: MachineKey { MachineKey(foldingDisplayName: rawValue) }

  private init(validated rawValue: String) {
    self.rawValue = rawValue
  }

  public static func maxLength(limaHomeUTF8Count: Int) -> Int {
    let instanceLimit = min(maxInstanceNameLength, socketPathBudget - limaHomeUTF8Count - socketPathSuffixLength)
    return max(0, instanceLimit - instancePrefix.count)
  }

  public static func parse(_ text: String, limaHomeUTF8Count: Int) -> Result<MachineName, MachineNameProblem> {
    if text.isEmpty { return .failure(.empty) }
    guard followsIdentifierRule(text) else { return .failure(.invalidCharacters) }
    let limit = maxLength(limaHomeUTF8Count: limaHomeUTF8Count)
    guard text.utf8.count <= limit else { return .failure(.tooLong(maxLength: limit)) }
    return .success(MachineName(validated: text))
  }

  /// Length is not checked, so machines survive a longer `~/.lima` path.
  public init?(instanceName: String) {
    guard instanceName.hasPrefix(Self.instancePrefix) else { return nil }
    let displayName = String(instanceName.dropFirst(Self.instancePrefix.count))
    guard Self.followsIdentifierRule(displayName) else { return nil }
    self.init(validated: displayName)
  }

  /// Lima's identifier rule `^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$`, excluding `.yml` and `.yaml` endings.
  private static func followsIdentifierRule(_ text: String) -> Bool {
    guard !text.hasSuffix(".yml"), !text.hasSuffix(".yaml") else { return false }
    var previousWasSeparator = true
    for byte in text.utf8 {
      if isAlphanumeric(byte) {
        previousWasSeparator = false
      } else if isSeparator(byte), !previousWasSeparator {
        previousWasSeparator = true
      } else {
        return false
      }
    }
    return !previousWasSeparator
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }

  private static func isSeparator(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
  }
}
