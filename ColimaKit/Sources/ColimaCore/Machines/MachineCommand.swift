import Foundation

public enum MachineCommand: Sendable, Equatable {
  case create(MachineCreateSpec)
  case start(MachineName)
  case stop(MachineName)
  case delete(MachineName)
  case edit(MachineName, MachineEditSpec)

  public var name: MachineName {
    switch self {
    case .create(let spec): spec.name
    case .start(let name), .stop(let name), .delete(let name), .edit(let name, _): name
    }
  }

  public var kind: MachineOperationKind {
    switch self {
    case .create: .create
    case .start: .start
    case .stop: .stop
    case .delete: .delete
    case .edit: .edit
    }
  }

  /// Every flag is `--name=value` so a value never binds to the next argument; `--tty=false` keeps limactl out of
  /// the editor and confirmation prompts.
  public var arguments: [String] {
    switch self {
    case .create(let spec):
      Self.createArguments(spec)
    case .start(let name):
      ["start", "--tty=false", name.instanceName]
    case .stop(let name):
      ["stop", "--tty=false", name.instanceName]
    case .delete(let name):
      ["delete", "--tty=false", "--force", name.instanceName]
    case .edit(let name, let spec):
      ["edit", "--tty=false", name.instanceName] + Self.resourceArguments(spec.resources) + [Self.mountsArgument(spec.mounts)]
    }
  }

  private static func createArguments(_ spec: MachineCreateSpec) -> [String] {
    ["create", "--tty=false", "--name=\(spec.name.instanceName)", "--vm-type=vz"]
      + resourceArguments(spec.resources)
      + [
        "--containerd=none",
        mountsArgument(spec.mounts),
        "--set=.env.COLIMAGUI_TEMPLATE = \"\(spec.template.id)\"",
        "template:\(spec.template.id)",
      ]
  }

  private static func resourceArguments(_ resources: MachineResources) -> [String] {
    ["--cpus=\(resources.cpus)", "--memory=\(VMCommand.gibibytes(resources.memoryGiB))", "--disk=\(resources.diskGiB)"]
  }

  /// `--set` is evaluated as a yq expression and never split, unlike `--mount-only`, which splits its value as CSV
  /// and so cannot carry a path with a comma.
  private static func mountsArgument(_ mounts: [MachineMount]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let entries = mounts.map { LimaMount(location: $0.path, mountPoint: $0.mountPoint ?? $0.path, writable: $0.writable) }
    let json = (try? encoder.encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    return "--set=.mounts = \(json)"
  }

  private struct LimaMount: Encodable {
    let location: String
    let mountPoint: String
    let writable: Bool
  }
}
