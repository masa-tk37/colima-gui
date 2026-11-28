import Darwin
import Foundation

/// A foreground `colima start` (brew services keeps one alive) stays after the VM is up and then changes nothing.
/// It counts as idle only when it has no children and the VM it started is Running: while booting it runs `limactl`
/// and `ssh` as children, with child-less pauses in between that the VM status still shows as not yet Running.
package enum ColimaCommandCheck {
  package static let pattern = "(^|/)colima (start|stop|delete)( |$)"

  package static func isRunning() async -> Bool {
    await isRunning(
      pids: await ForeignCommandCheck.matchingPIDs(pattern),
      arguments: arguments(of:),
      hasChildren: ForeignCommandCheck.hasChildren,
      defaultVMIsRunning: defaultVMIsRunning)
  }

  package static func isRunning(
    pids: [pid_t]?,
    arguments: (pid_t) -> [String]?,
    hasChildren: (pid_t) async -> Bool?,
    defaultVMIsRunning: () async -> Bool?
  ) async -> Bool {
    guard let pids else { return true }
    for pid in pids {
      guard let argv = arguments(pid), isForegroundStart(argv: argv), await hasChildren(pid) == false else {
        return true
      }
    }
    guard !pids.isEmpty else { return false }
    return await defaultVMIsRunning() != true
  }

  /// Only `colima start` followed by nothing but foreground flags, as brew services runs it: any other argument may
  /// name another profile, whose VM `defaultVMIsRunning` does not check. `-f` means force for `stop` and `delete`.
  /// Values follow Go's `strconv.ParseBool`, which colima's flag parser uses.
  package static func isForegroundStart(argv: [String]) -> Bool {
    guard argv.count >= 3, (argv[0] as NSString).lastPathComponent == "colima", argv[1] == "start" else {
      return false
    }
    return argv.dropFirst(2).allSatisfy { argument in
      if argument == "-f" || argument == "--foreground" { return true }
      for prefix in ["-f=", "--foreground="] where argument.hasPrefix(prefix) {
        return ["1", "t", "T", "TRUE", "true", "True"].contains(argument.dropFirst(prefix.count))
      }
      return false
    }
  }

  /// The default profile's Lima instance is `colima` under `~/.colima/_lima`.
  package static func defaultVMIsRunning() async -> Bool? {
    var environment = ChildEnvironment.current()
    environment["LIMA_HOME"] = NSHomeDirectory() + "/.colima/_lima"
    let invocation = ProcessInvocation(
      executable: LimaInvocation().limactlPath,
      arguments: ["list", "--format", "{{.Status}}", "colima"],
      environment: environment,
      workingDirectory: "/",
      timeout: .seconds(5)
    )
    let result = await ProcessRunner().runCollecting(invocation)
    guard result.termination == .exited(code: 0) else { return nil }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Running"
  }

  /// The argv of a process, element boundaries intact, from `KERN_PROCARGS2`: a 32-bit argc, the executable path,
  /// NUL padding, then argc NUL-terminated arguments.
  package static func arguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let bytes = buffer.prefix(size)

    let argc = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = bytes.startIndex + 4
    while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
    while index < bytes.endIndex, bytes[index] == 0 { index += 1 }

    var argv: [String] = []
    while argv.count < argc, index < bytes.endIndex {
      let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
      argv.append(String(decoding: bytes[index..<end], as: UTF8.self))
      index = end + 1
    }
    return argv.count == argc ? argv : nil
  }
}
