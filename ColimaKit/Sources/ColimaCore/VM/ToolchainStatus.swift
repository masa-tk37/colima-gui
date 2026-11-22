public struct ToolchainStatus: Sendable, Equatable {
  public enum ColimaLookup: Sendable, Equatable {
    case found(path: String)
    case missing(searched: [String])
  }

  public let colima: ColimaLookup
  public let missingByVMType: [VMType: [String]]

  public init(colima: ColimaLookup, missingByVMType: [VMType: [String]]) {
    self.colima = colima
    self.missingByVMType = missingByVMType
  }

  public init(colima: ColimaLookup, installedExecutables: Set<String>) {
    var missing: [VMType: [String]] = [:]
    for type in VMType.allCases {
      missing[type] = type.requiredExecutables.filter { !installedExecutables.contains($0) }
    }
    self.init(colima: colima, missingByVMType: missing)
  }

  public func missingExecutables(for type: VMType) -> [String] {
    missingByVMType[type] ?? []
  }
}
