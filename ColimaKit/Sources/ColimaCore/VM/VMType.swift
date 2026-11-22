public enum VMType: String, Sendable, Hashable, CaseIterable, Codable {
  case qemu
  case vz
  case krunkit

  /// Executables Colima looks up on PATH for this VM type, beyond `colima` itself.
  public var requiredExecutables: [String] {
    switch self {
    case .qemu: ["qemu-img", "qemu-system-aarch64"]
    case .vz: []
    case .krunkit: ["krunkit"]
    }
  }
}
