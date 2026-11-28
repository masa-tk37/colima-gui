import ColimaProcess
import Foundation

enum ShellCommandScript {
  static let directoryName = "cc.tk37.ColimaGUI"

  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// Terminal.app runs the file by its path, so `$0` is the file itself and the script removes itself on start.
  static func body(limactlPath: String, limaHome: String, instanceName: String) -> String {
    """
    #!/bin/sh
    rm -f -- "$0"
    export PATH=\(quote(ChildEnvironment.path))
    export LIMA_HOME=\(quote(limaHome))
    exec \(quote(limactlPath)) shell --start=false \(quote(instanceName))

    """
  }

  /// An app that opens `.command` as a document never runs the script, so it would stay behind; a script that has not
  /// run within this long never will.
  static let staleAfter: TimeInterval = 3600

  /// The owner-only mode is part of the creation call, so the file is never readable by others.
  static func write(_ body: String, in temporaryDirectory: URL, now: Date = Date()) throws -> URL {
    let directory = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    removeStaleScripts(in: directory, now: now)
    let file = directory.appendingPathComponent("shell-\(UUID().uuidString).command")

    let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o700)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }

    do {
      guard fchmod(descriptor, 0o700) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(
        contentsOf: Data(body.utf8))
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    return file
  }

  private static func removeStaleScripts(in directory: URL, now: Date) {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files where file.lastPathComponent.hasPrefix("shell-") && file.pathExtension == "command" {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, now.timeIntervalSince(modified) > staleAfter {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
}
