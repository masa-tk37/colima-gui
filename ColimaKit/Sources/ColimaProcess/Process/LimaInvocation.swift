import ColimaCore
import Foundation

package struct LimaInvocation: Sendable {
  package let homebrewDirectory: String
  package let homeDirectory: String

  package init(
    homebrewDirectory: String = "/opt/homebrew/bin", homeDirectory: String = NSHomeDirectory()
  ) {
    self.homebrewDirectory = homebrewDirectory
    self.homeDirectory = homeDirectory
  }

  package var limactlPath: String { homebrewDirectory + "/limactl" }

  /// `limactl` saves a rejected configuration as `lima.REJECTED.yaml` in its working directory.
  package var workingDirectory: String { homeDirectory + "/.colima-gui" }

  package var limaHome: String { homeDirectory + "/.lima" }

  /// Lima bounds the instance socket path using the symlink-resolved `LIMA_HOME`.
  package var limaHomeUTF8Count: Int {
    (Self.resolvedPath(limaHome) ?? limaHome).utf8.count
  }

  package func instanceDirectory(for name: MachineName) -> String {
    limaHome + "/" + name.instanceName
  }

  package func environment(
    parent: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = ChildEnvironment.current(parent: parent)
    environment["LIMA_HOME"] = limaHome
    return environment
  }

  package func make(_ arguments: [String], timeout: Duration?) -> ProcessInvocation {
    ProcessInvocation(
      executable: limactlPath,
      arguments: arguments,
      environment: environment(),
      workingDirectory: workingDirectory,
      timeout: timeout
    )
  }

  package func prepareWorkingDirectory() throws {
    try FileManager.default.createDirectory(
      atPath: workingDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  private static func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
