public enum VMCommand: Sendable, Equatable {
  case start
  case stop
  case delete
  case create(VMCreateSpec)

  public var arguments: [String] {
    switch self {
    case .start:
      ["start"]
    case .stop:
      ["stop"]
    case .delete:
      // No terminal is attached, so without --force colima would wait on a confirmation prompt.
      ["delete", "--force", "--data"]
    case .create(let spec):
      Self.createArguments(spec)
    }
  }

  private static func createArguments(_ spec: VMCreateSpec) -> [String] {
    var arguments = [
      "start",
      "--vm-type", spec.vmType.rawValue,
      "--cpus", String(spec.resources.cpus),
      "--memory", gibibytes(spec.resources.memoryGiB),
      "--disk", String(spec.resources.diskGiB),
      "--template=false",
    ]
    // Colima keeps virtiofs for krunkit, which it later maps to 9p; sshfs is the mount type that works there.
    if spec.vmType == .krunkit {
      arguments += ["--mount-type", "sshfs"]
    }
    return arguments
  }

  /// Locale-independent, so a decimal separator never reaches the colima or limactl flag parser.
  static func gibibytes(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e15 {
      return String(Int(value))
    }
    return "\(value)"
  }
}
