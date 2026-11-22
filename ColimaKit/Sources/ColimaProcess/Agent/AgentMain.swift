import ColimaCore
import Darwin
import Foundation

public enum AgentMain {
  public static func run() -> Never {
    let service = AgentService(
      launcher: LocalVMCommandLauncher(),
      peerRequirement: appPeerRequirement,
      foreignCommandIsRunning: colimaCommandIsRunning
    )
    let listener = NSXPCListener(machServiceName: AgentXPC.serviceName)
    listener.delegate = service
    listener.resume()
    ColimaLog.process.info("agent listening on \(AgentXPC.serviceName, privacy: .public)")
    dispatchMain()
  }

  /// Recomputed per connection: the agent outlives app rebuilds, and the app it trusts is the one on disk now.
  @Sendable static func appPeerRequirement() -> PeerRequirement {
    guard let appURL = enclosingAppURL() else {
      return .unavailable(reason: "the agent is not inside an app bundle")
    }
    guard let cdhash = CodeSignature.cdhash(of: appURL) else {
      return .unavailable(reason: "cannot read the signature of \(appURL.path)")
    }
    return .required("identifier \"\(AgentXPC.appIdentifier)\" and cdhash H\"\(cdhash)\"")
  }

  /// launchd starts the agent with a bundle-relative argv[0], so the path comes from the kernel instead.
  private static func enclosingAppURL() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let executable = URL(fileURLWithPath: path)
    let app = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
  }

  @Sendable package static func colimaCommandIsRunning() async -> Bool {
    let pgrep = ProcessInvocation(
      executable: "/usr/bin/pgrep",
      // `-U`: another user's colima drives that user's own VM, not this one.
      arguments: ["-U", String(getuid()), "-f", "(^|/)colima (start|stop|delete)( |$)"],
      environment: ChildEnvironment.current(),
      workingDirectory: "/",
      timeout: .seconds(5)
    )
    // pgrep exits 1 when nothing matches; any other outcome (a match, an error, a timeout) is treated as running.
    let result = await ProcessRunner().runCollecting(pgrep)
    return result.termination != .exited(code: 1)
  }
}
