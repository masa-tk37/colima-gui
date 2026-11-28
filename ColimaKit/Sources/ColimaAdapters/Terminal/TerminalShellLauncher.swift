import ColimaCore
import ColimaProcess
import Foundation

public struct TerminalShellLauncher: TerminalLauncher {
  private static let terminalIdentifier = "com.apple.Terminal"
  private static let ghosttyIdentifier = "com.mitchellh.ghostty"

  /// Values reach Ghostty as `argv` items, never as AppleScript source, so no quoting rule applies to them.
  private static let ghosttyScript = [
    "on run argv",
    "set instanceName to item 1 of argv",
    "set limaHome to item 2 of argv",
    "set limactl to item 3 of argv",
    "tell application id \"\(ghosttyIdentifier)\"",
    "set cfg to new surface configuration from {command:limactl & \" shell --start=false \" & instanceName, environment variables:{\"LIMA_HOME=\" & limaHome}}",
    "new window with configuration cfg",
    "end tell",
    "end run",
  ]

  private let locateApplication: @Sendable (String) -> URL?
  private let invocation: LimaInvocation
  private let runner: ProcessRunner
  private let openPath: String
  private let osascriptPath: String
  private let temporaryDirectory: URL

  public init(locateApplication: @escaping @Sendable (String) -> URL?) {
    self.init(
      locateApplication: locateApplication,
      invocation: LimaInvocation(),
      runner: ProcessRunner(),
      openPath: "/usr/bin/open",
      osascriptPath: "/usr/bin/osascript",
      temporaryDirectory: FileManager.default.temporaryDirectory
    )
  }

  init(
    locateApplication: @escaping @Sendable (String) -> URL?, invocation: LimaInvocation,
    runner: ProcessRunner, openPath: String, osascriptPath: String, temporaryDirectory: URL
  ) {
    self.locateApplication = locateApplication
    self.invocation = invocation
    self.runner = runner
    self.openPath = openPath
    self.osascriptPath = osascriptPath
    self.temporaryDirectory = temporaryDirectory
  }

  public func availability(of choice: TerminalChoice) async -> TerminalAvailability {
    switch choice {
    case .terminal:
      locateApplication(Self.terminalIdentifier) == nil ? .notFound : .available
    case .ghostty:
      locateApplication(Self.ghosttyIdentifier) == nil ? .notFound : .available
    case .custom(let app):
      FileManager.default.fileExists(atPath: app.path) ? .available : .notFound
    }
  }

  public func application(at url: URL) async -> CustomTerminalApp? {
    guard url.pathExtension.lowercased() == "app",
      let bundle = Bundle(url: url),
      let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
      bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
    else { return nil }

    let displayName =
      [
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName"),
        bundle.object(forInfoDictionaryKey: "CFBundleName"),
      ]
      .compactMap { $0 as? String }
      .first { !$0.isEmpty }
      ?? url.deletingPathExtension().lastPathComponent
    return CustomTerminalApp(path: url.path, bundleIdentifier: identifier, displayName: displayName)
  }

  public func openShell(for name: MachineName, in choice: TerminalChoice) async -> Result<
    Void, ShellLaunchError
  > {
    guard await availability(of: choice) == .available else {
      return .failure(.applicationNotFound)
    }

    switch choice {
    case .terminal:
      return await openScript(for: name, openArguments: ["-b", Self.terminalIdentifier])
    case .custom(let app):
      return await openScript(for: name, openArguments: ["-a", app.path])
    case .ghostty:
      return await openGhostty(for: name)
    }
  }

  private func openScript(for name: MachineName, openArguments: [String]) async -> Result<
    Void, ShellLaunchError
  > {
    let body = ShellCommandScript.body(
      limactlPath: invocation.limactlPath, limaHome: invocation.limaHome,
      instanceName: name.instanceName)
    let file: URL
    do {
      file = try ShellCommandScript.write(body, in: temporaryDirectory)
    } catch {
      return .failure(.failed(detail: error.localizedDescription))
    }

    let result = await run(openPath, openArguments + [file.path], tool: "open")
    if case .failure = result {
      // The script deletes itself only once it runs, which it never will after a failed hand-off.
      try? FileManager.default.removeItem(at: file)
    }
    return result
  }

  private func openGhostty(for name: MachineName) async -> Result<Void, ShellLaunchError> {
    let scriptArguments = Self.ghosttyScript.flatMap { ["-e", $0] }
    let values = [name.instanceName, invocation.limaHome, invocation.limactlPath]
    let result = await run(osascriptPath, scriptArguments + values, tool: "osascript")
    if case .failure(.failed(let detail)) = result, detail.contains("-1743") {
      return .failure(.automationDenied)
    }
    return result
  }

  private func run(_ executable: String, _ arguments: [String], tool: String) async -> Result<
    Void, ShellLaunchError
  > {
    let run = await runner.runCollecting(
      ProcessInvocation(
        executable: executable, arguments: arguments, environment: ChildEnvironment.current(),
        workingDirectory: invocation.homeDirectory, timeout: nil))

    switch run.termination {
    case .exited(code: 0):
      return .success(())
    case .exited(let code):
      let text = run.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail =
        text.isEmpty
        ? String(localized: "\(tool) exited with code \(code).", bundle: #bundle) : text
      return .failure(.failed(detail: detail))
    case .launchFailed(let reason):
      return .failure(.failed(detail: reason))
    case .cancelled, .timedOut:
      return .failure(
        .failed(detail: String(localized: "Opening the shell was cancelled.", bundle: #bundle)))
    }
  }
}
