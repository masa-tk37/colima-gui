import ColimaCore
import Foundation

public struct ColimaProfileFiles: ColimaFileStore {
  private let profilePath: String
  private let statePath: String

  public init(baseDirectory: URL) {
    profilePath = baseDirectory.appendingPathComponent(".colima/default/colima.yaml").path
    statePath = baseDirectory.appendingPathComponent(".colima/_lima/colima/colima.yaml").path
  }

  public func readProfileSettings() throws(ColimaFileError) -> ProfileSettings? {
    // lstat, not stat: a dangling link must surface as unreadable rather than as an absent file.
    guard Self.entryExists(atPath: profilePath) else { return nil }
    let text = try Self.readText(atPath: Self.resolvedPath(of: profilePath))
    return try Self.parseProfile(text)
  }

  public func writeProfileSettings(_ settings: VMResourceSettings) throws(ColimaFileError) {
    let realPath = try Self.resolvedPath(of: profilePath)
    let current = try Self.readText(atPath: realPath)

    let updated: String
    do {
      updated = try ColimaConfigRewriter.rewrite(current, settings: settings)
    } catch {
      throw .unexpectedFormat(key: error.key, reason: error.reason)
    }
    try Self.replaceFile(atPath: realPath, with: Data(updated.utf8))
  }

  public func readInstanceVMType() throws(ColimaFileError) -> VMType? {
    guard Self.entryExists(atPath: statePath) else { return nil }
    let text = try Self.readText(atPath: statePath)
    guard let value = try YAMLTopLevelScalars.value(forKey: "vmType", in: text) else { return nil }
    return VMType(rawValue: value)
  }

  // MARK: - Reading

  private static func parseProfile(_ text: String) throws(ColimaFileError) -> ProfileSettings {
    let cpu = try requiredValue("cpu", in: text)
    let memory = try requiredValue("memory", in: text)
    let disk = try requiredValue("disk", in: text)

    guard let cpus = Int(cpu) else {
      throw .unexpectedFormat(key: "cpu", reason: String(localized: "The value `\(cpu)` of `cpu:` is not an integer.", bundle: #bundle))
    }
    guard let memoryGiB = Double(memory), memoryGiB.isFinite else {
      throw .unexpectedFormat(key: "memory", reason: String(localized: "The value `\(memory)` of `memory:` is not a number.", bundle: #bundle))
    }
    guard let diskGiB = Int(disk) else {
      throw .unexpectedFormat(key: "disk", reason: String(localized: "The value `\(disk)` of `disk:` is not an integer.", bundle: #bundle))
    }

    let vmType = try YAMLTopLevelScalars.value(forKey: "vmType", in: text).flatMap(
      VMType.init(rawValue:))
    return ProfileSettings(
      resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
      vmType: vmType
    )
  }

  private static func requiredValue(_ key: String, in text: String) throws(ColimaFileError)
    -> String
  {
    guard let value = try YAMLTopLevelScalars.value(forKey: key, in: text) else {
      throw .unexpectedFormat(key: key, reason: String(localized: "The settings file has no `\(key):` line at the start of a line.", bundle: #bundle))
    }
    return value
  }

  private static func entryExists(atPath path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func readText(atPath path: String) throws(ColimaFileError) -> String {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw .unreadable(path: path, reason: error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw .unreadable(path: path, reason: String(localized: "The file is not valid UTF-8.", bundle: #bundle))
    }
    return text
  }

  /// `realpath` follows the whole link chain and fails for a dangling link, so the write never creates the target.
  private static func resolvedPath(of path: String) throws(ColimaFileError) -> String {
    guard let resolved = realpath(path, nil) else {
      throw .unreadable(path: path, reason: String(cString: strerror(errno)))
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  // MARK: - Writing

  private static func replaceFile(atPath path: String, with data: Data) throws(ColimaFileError) {
    func failure(_ step: String) -> ColimaFileError {
      .writeFailed(path: path, reason: "\(step): \(String(cString: strerror(errno)))")
    }

    var original = stat()
    guard stat(path, &original) == 0 else { throw failure("stat") }

    let directory = (path as NSString).deletingLastPathComponent
    let temporaryPath = "\(directory)/.colima.yaml.\(UUID().uuidString).tmp"
    let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw failure("open") }

    var step: String? = writeAll(data, to: descriptor)
    if step == nil, fchmod(descriptor, original.st_mode & 0o7777) != 0 { step = "fchmod" }
    if step == nil, fsync(descriptor) != 0 { step = "fsync" }
    let failed = step.map(failure)
    let closeResult = close(descriptor)
    if let failed {
      unlink(temporaryPath)
      throw failed
    }
    guard closeResult == 0 else {
      let error = failure("close")
      unlink(temporaryPath)
      throw error
    }
    guard rename(temporaryPath, path) == 0 else {
      let error = failure("rename")
      unlink(temporaryPath)
      throw error
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) -> String? {
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          return "write"
        }
        offset += written
      }
      return nil
    }
  }
}

enum YAMLTopLevelScalars {
  static func value(forKey key: String, in text: String) throws(ColimaFileError) -> String? {
    let prefixCount = "\(key):".unicodeScalars.count
    let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
    let matches = lines.filter { ColimaConfigRewriter.isKeyLine($0, key: key) }

    guard let line = matches.first else { return nil }
    guard matches.count == 1 else {
      throw .unexpectedFormat(key: key, reason: String(localized: "The settings file has \(matches.count) `\(key):` lines at the start of a line.", bundle: #bundle))
    }

    let rest = line.dropFirst(prefixCount).drop { $0 == " " || $0 == "\t" }
    let token = rest.prefix { $0 != " " && $0 != "\t" && $0 != "\r" }
    guard !token.isEmpty, token.first != "#" else {
      throw .unexpectedFormat(key: key, reason: String(localized: "There is no value on the same line as `\(key):`.", bundle: #bundle))
    }
    return unquoted(String(String.UnicodeScalarView(token)))
  }

  private static func unquoted(_ token: String) -> String {
    guard token.count >= 2, let quote = token.first, quote == "\"" || quote == "'",
      token.last == quote
    else {
      return token
    }
    return String(token.dropFirst().dropLast())
  }
}
