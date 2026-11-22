import ColimaCore
import Foundation

enum ColimaListDecoder {
  private static let profileName = "default"

  static func decode(_ output: [UInt8]) throws(ColimaCLIError) -> VMObservation {
    let decoder = JSONDecoder()
    var observation = VMObservation.absent
    var foundDefault = false

    for (index, rawLine) in output.split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false
    ).enumerated() {
      let line = trimmed(rawLine)
      if line.isEmpty { continue }

      do {
        let data = Data(line)
        let head = try decoder.decode(RowHead.self, from: data)
        // Other profiles are only checked for being a named object; their fields must not break the default row's observation.
        guard head.name == profileName, !foundDefault else { continue }
        observation = .present(try decoder.decode(Row.self, from: data).instance)
        foundDefault = true
      } catch {
        throw .undecodable(
          detail:
            "colima list --json: line \(index + 1) is not a valid profile row (\(describe(error)))")
      }
    }
    return observation
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
  let name: String
}

/// Colima tags every list field `omitempty`: `runtime` is dropped when the profile's state file cannot be
/// loaded, and `arch`/`cpus`/`memory`/`disk` are dropped when Lima cannot load the instance's lima.yaml.
/// Only `status` is guaranteed.
private struct Row: Decodable {
  let status: String
  let arch: String?
  let cpus: Int?
  let memory: Int64?
  let disk: Int64?
  let runtime: String?

  var instance: VMInstance {
    VMInstance(
      runState: VMRunState(colimaStatus: status),
      arch: arch ?? "",
      cpus: cpus ?? 0,
      memoryBytes: memory ?? 0,
      diskBytes: disk ?? 0,
      runtime: runtime ?? ""
    )
  }
}
