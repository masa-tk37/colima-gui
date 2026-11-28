import ColimaCore
import Foundation

/// Reads `limactl list --json` (one object per line) from the shared `~/.lima`, where the user's own instances
/// sit beside the app's. Only a row's name and ownership marker are read before ownership is settled, so a
/// user's malformed row cannot fail the list.
enum LimaListDecoder {
  static func decode(_ output: [UInt8]) -> LimaListing {
    let decoder = JSONDecoder()
    var machines: [MachineInstance] = []
    var unownedKeys: Set<MachineKey> = []

    for (index, rawLine) in output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
      .enumerated()
    {
      let line = trimmed(rawLine)
      if line.isEmpty { continue }
      let data = Data(line)

      guard let head = try? decoder.decode(RowHead.self, from: data), let instanceName = head.name else {
        ColimaLog.machine.warning("limactl list: line \(index + 1) has no readable name and was dropped")
        continue
      }

      if let name = MachineName(instanceName: instanceName), head.owns {
        machines.append(instance(named: name, head: head, data: data, decoder: decoder))
      } else if let key = MachineKey(unownedInstanceName: instanceName) {
        unownedKeys.insert(key)
      }
    }
    return LimaListing(machines: machines, unownedMachineKeys: unownedKeys)
  }

  private static func instance(
    named name: MachineName, head: RowHead, data: Data, decoder: JSONDecoder
  ) -> MachineInstance {
    do {
      return try decoder.decode(Row.self, from: data).instance(named: name, marker: head.marker)
    } catch {
      let description = describe(error)
      ColimaLog.machine.error(
        "limactl list: row \(name.instanceName, privacy: .public) is unreadable: \(description, privacy: .public)")
      return MachineInstance(
        name: name, runState: .broken(errors: [description]), cpus: 0, memoryBytes: 0, diskBytes: 0,
        mounts: [], templateID: head.marker)
    }
  }

  private static func trimmed(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var slice = line
    while let first = slice.first, isWhitespace(first) { slice.removeFirst() }
    while let last = slice.last, isWhitespace(last) { slice.removeLast() }
    return slice
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
  }

  private static func describe(_ error: any Error) -> String {
    guard let decodingError = error as? DecodingError else { return error.localizedDescription }
    switch decodingError {
    case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    @unknown default: return "decoding failed"
    }
  }
}

private struct RowHead: Decodable {
  private static let markerKey = "COLIMAGUI_TEMPLATE"

  let name: String?
  let hasConfig: Bool
  let marker: String?

  /// An unreadable config cannot be told apart from a foreign one, so only a missing config or a marker owns.
  var owns: Bool { !hasConfig || marker != nil }

  private enum CodingKeys: String, CodingKey { case name, config }
  private enum ConfigKeys: String, CodingKey { case env }
  private struct EnvKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: any Decoder) throws {
    let row = try decoder.container(keyedBy: CodingKeys.self)
    name = try? row.decode(String.self, forKey: .name)
    hasConfig = row.contains(.config) && ((try? row.decodeNil(forKey: .config)) == false)

    let env = try? row.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
      .nestedContainer(keyedBy: EnvKey.self, forKey: .env)
    let value = try? env?.decode(String.self, forKey: EnvKey(stringValue: Self.markerKey))
    marker = value.flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Lima tags `cpus`, `memory`, `disk`, `errors` and the mounts' `writable` as `omitempty`; a row with no `config`
/// is an instance whose `lima.yaml` Lima could not load.
private struct Row: Decodable {
  struct Config: Decodable {
    struct Mount: Decodable {
      let location: String
      let mountPoint: String?
      let writable: Bool?
    }

    let mounts: [Mount]?
  }

  let status: String
  let cpus: Int?
  let memory: Int64?
  let disk: Int64?
  let errors: [String]?
  let config: Config?

  func instance(named name: MachineName, marker: String?) -> MachineInstance {
    guard let config else {
      let reasons = errors ?? []
      return .broken(
        name: name,
        errors: reasons.isEmpty ? ["Lima could not load lima.yaml for this instance"] : reasons)
    }
    return MachineInstance(
      name: name, runState: runState, cpus: cpus ?? 0, memoryBytes: memory ?? 0, diskBytes: disk ?? 0,
      mounts: (config.mounts ?? []).map { MachineMount(path: $0.location, writable: $0.writable ?? false, mountPoint: $0.mountPoint) },
      templateID: marker)
  }

  private var runState: MachineRunState {
    switch status {
    case "Running": .running
    case "Stopped": .stopped
    case "Broken": .broken(errors: errors ?? [])
    default: .other(rawStatus: status)
    }
  }
}
