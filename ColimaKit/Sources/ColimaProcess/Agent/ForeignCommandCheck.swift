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
    await matchingPIDs(pattern, ignoringCase: ignoringCase) != []
  }

  package static func matchingPIDs(_ pattern: String, ignoringCase: Bool = false) async -> [pid_t]? {
    let result = await pgrep(["-U", String(getuid())] + (ignoringCase ? ["-i"] : []) + ["-f", pattern])
    switch result.termination {
    case .exited(code: 1): return []
    case .exited(code: 0): break
    default: return nil
    }
    let lines = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
    let pids = lines.compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    return !pids.isEmpty && pids.count == lines.count ? pids : nil
  }

  package static func hasChildren(_ pid: pid_t) async -> Bool? {
    switch await pgrep(["-P", String(pid)]).termination {
    case .exited(code: 0): true
    case .exited(code: 1): false
    default: nil
    }
  }

  private static func pgrep(_ arguments: [String]) async -> CollectedRun {
    let invocation = ProcessInvocation(
      executable: "/usr/bin/pgrep",
      arguments: arguments,
      environment: ChildEnvironment.current(),
      workingDirectory: "/",
      timeout: .seconds(5)
    )
    return await ProcessRunner().runCollecting(invocation)
  }
}
