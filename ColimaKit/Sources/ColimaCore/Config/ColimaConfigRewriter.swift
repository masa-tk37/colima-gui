import Foundation

public struct ConfigFormatError: Error, Equatable, Sendable {
  public let key: String
  public let reason: String

  public init(key: String, reason: String) {
    self.key = key
    self.reason = reason
  }
}

/// The text is edited line by line rather than parsed as YAML so comments, key order and line endings
/// survive a save.
public enum ColimaConfigRewriter {
  public static func rewrite(
    _ text: String,
    settings: VMResourceSettings
  ) throws(ConfigFormatError) -> String {
    let replacements = [
      ("cpu", String(settings.cpus)),
      ("memory", format(memoryGiB: settings.memoryGiB)),
      ("disk", String(settings.diskGiB)),
    ]

    // Split on "\n" over scalars: "\r\n" is a single Character, so a Character-level split would miss CRLF.
    var segments = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      .map { String(String.UnicodeScalarView($0)) }

    for (key, value) in replacements {
      let matches = segments.indices.filter { isKeyLine(segments[$0].unicodeScalars, key: key) }
      guard let index = matches.first else {
        throw ConfigFormatError(key: key, reason: String(localized: "The settings file has no `\(key):` line at the start of a line.", bundle: #bundle))
      }
      guard matches.count == 1 else {
        throw ConfigFormatError(
          key: key,
          reason: String(localized: "The settings file has \(matches.count) `\(key):` lines at the start of a line.", bundle: #bundle))
      }
      segments[index] = try replacingValue(in: segments[index], key: key, with: value)
    }
    return segments.joined(separator: "\n")
  }

  private static func format(memoryGiB: Double) -> String {
    if memoryGiB == memoryGiB.rounded(), abs(memoryGiB) < 1e15 {
      return String(Int(memoryGiB))
    }
    return String(memoryGiB)
  }

  package static func isKeyLine(_ line: some Collection<Unicode.Scalar>, key: String) -> Bool {
    let prefix = "\(key):".unicodeScalars
    guard line.starts(with: prefix) else { return false }
    guard let next = line.dropFirst(prefix.count).first else { return true }
    return next == " " || next == "\t" || next == "\r"
  }

  private static let notPlainScalarStarts: Set<Unicode.Scalar> = [
    "[", "{", "|", ">", "&", "*", "!", "#",
  ]

  private static func replacingValue(
    in line: String,
    key: String,
    with value: String
  ) throws(ConfigFormatError) -> String {
    let notScalar = ConfigFormatError(
      key: key,
      reason: String(localized: "There is no plain value on the same line as `\(key):`.", bundle: #bundle)
    )

    var rest = Substring(line.unicodeScalars.dropFirst(key.unicodeScalars.count + 1))
    let separatorEnd = rest.firstIndex { !isBlank($0) } ?? rest.endIndex
    let separator = rest[..<separatorEnd]
    rest = rest[separatorEnd...]

    let ending = rest.hasSuffix("\r") ? "\r" : ""
    let body = rest.dropLast(ending.count)

    guard let first = body.unicodeScalars.first, !notPlainScalarStarts.contains(first) else {
      throw notScalar
    }
    let tokenEnd = body.firstIndex { isBlank($0) } ?? body.endIndex
    let remainder = body[tokenEnd...]
    let trimmed = remainder.drop { isBlank($0) }
    guard trimmed.isEmpty || trimmed.first == "#" else { throw notScalar }

    return "\(key):\(separator)\(value)\(remainder)\(ending)"
  }

  private static func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\t"
  }
}
