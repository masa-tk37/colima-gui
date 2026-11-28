import Foundation

package enum ForeignCommandCheck {
  package static let limactlMutatingVerbs = "create|start|stop|delete|edit"

  /// The name must be a whole word, so `cg-webdev` never matches `cg-dev`.
  package static func limactlPattern(instanceName: String? = nil) -> String {
    guard let instanceName else { return "(^|/)limactl (\(limactlMutatingVerbs))( |$)" }
    let escaped = instanceName.replacingOccurrences(of: ".", with: "\\.")
    return "(^|/)limactl (\(limactlMutatingVerbs)) (.* )?(--name=)?\(escaped)( |$)"
  }

  /// `-U`: another user's process drives that user's own VMs, not these. pgrep exits 1 when nothing matches; any
  /// other outcome (a match, an error, a timeout) counts as running.
  package static func isRunning(matching pattern: String, ignoringCase: Bool = false) async -> Bool {
    let pgrep = ProcessInvocation(
      executable: "/usr/bin/pgrep",
      arguments: ["-U", String(getuid())] + (ignoringCase ? ["-i"] : []) + ["-f", pattern],
      environment: ChildEnvironment.current(),
      workingDirectory: "/",
      timeout: .seconds(5)
    )
    let result = await ProcessRunner().runCollecting(pgrep)
    return result.termination != .exited(code: 1)
  }
}
