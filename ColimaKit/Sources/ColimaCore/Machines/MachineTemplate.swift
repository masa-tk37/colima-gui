import Foundation

public enum MachineDistribution: String, Sendable, CaseIterable {
  case almalinux, alpine, archlinux, centosStream = "centos-stream", debian, fedora
  case opensuse, opensuseLeap = "opensuse-leap", oraclelinux, rocky, ubuntu

  var familyName: String {
    switch self {
    case .almalinux: "AlmaLinux"
    case .alpine: "Alpine Linux"
    case .archlinux: "Arch Linux"
    case .centosStream: "CentOS Stream"
    case .debian: "Debian"
    case .fedora: "Fedora"
    case .opensuse: "openSUSE"
    case .opensuseLeap: "openSUSE Leap"
    case .oraclelinux: "Oracle Linux"
    case .rocky: "Rocky Linux"
    case .ubuntu: "Ubuntu"
    }
  }
}

public struct MachineTemplate: Sendable, Hashable {
  public let distribution: MachineDistribution
  /// nil is the alias that follows the latest version.
  public let version: String?

  public var id: String {
    version.map { "\(distribution.rawValue)-\($0)" } ?? distribution.rawValue
  }

  public var displayName: String {
    guard let version else { return String(localized: "\(distribution.familyName) (latest)", bundle: #bundle) }
    return "\(distribution.familyName) \(version)"
  }

  public init?(id: String) {
    for distribution in MachineDistribution.allCases {
      let family = distribution.rawValue
      if id == family {
        self.init(distribution: distribution, version: nil)
        return
      }
      guard id.hasPrefix(family + "-") else { continue }
      let version = String(id.dropFirst(family.count + 1))
      if Self.isVersion(version) {
        self.init(distribution: distribution, version: version)
        return
      }
    }
    return nil
  }

  private init(distribution: MachineDistribution, version: String?) {
    self.distribution = distribution
    self.version = version
  }

  public static func linuxTemplates(from limaTemplateIDs: [String]) -> [MachineTemplate] {
    limaTemplateIDs.compactMap(MachineTemplate.init(id:))
  }

  private static func isVersion(_ text: String) -> Bool {
    let groups = text.split(separator: ".", omittingEmptySubsequences: false)
    return groups.allSatisfy { group in !group.isEmpty && group.allSatisfy { $0.isASCII && $0.isNumber } }
  }
}
