import Foundation

package enum ChildEnvironment {
  /// Colima looks up `limactl` and `docker` on PATH, and a Finder launch has no Homebrew directory on it.
  package static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

  package static func make(home: String, user: String, tmp: String) -> [String: String] {
    [
      "HOME": home,
      "USER": user,
      "LOGNAME": user,
      "TMPDIR": tmp,
      "PATH": path,
    ]
  }

  package static func current(parent: [String: String] = ProcessInfo.processInfo.environment)
    -> [String:
    String]
  {
    make(
      home: parent["HOME"] ?? NSHomeDirectory(),
      user: parent["USER"] ?? parent["LOGNAME"] ?? NSUserName(),
      tmp: parent["TMPDIR"] ?? NSTemporaryDirectory()
    )
  }
}
