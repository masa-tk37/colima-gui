import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

private let hostileName = "it's a dir"

private final class LocatedIdentifiers: @unchecked Sendable {
  private let lock = NSLock()
  private var identifiers: [String] = []
  private let known: Set<String>

  init(known: Set<String>) { self.known = known }

  var asked: [String] { lock.withLock { identifiers } }

  func locate(_ identifier: String) -> URL? {
    lock.withLock { identifiers.append(identifier) }
    return known.contains(identifier)
      ? URL(fileURLWithPath: "/Applications/\(identifier).app") : nil
  }
}

/// Real `ProcessRunner` over fake `open`, `osascript`, and `limactl` scripts, so no terminal window ever opens.
private struct Harness {
  let bin: FakeBin
  let home: String
  let homebrew: String
  let temporary: URL
  let located: LocatedIdentifiers

  init(known: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty"]) throws {
    bin = try FakeBin()
    home = bin.directory.appendingPathComponent("home \(hostileName)").path
    homebrew = bin.directory.appendingPathComponent("brew \(hostileName)").path
    temporary = bin.directory.appendingPathComponent("tmp", isDirectory: true)
    located = LocatedIdentifiers(known: known)
    for path in [home, homebrew, temporary.path] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
  }

  func launcher() -> TerminalShellLauncher {
    TerminalShellLauncher(
      locateApplication: { [located] in located.locate($0) },
      invocation: LimaInvocation(homebrewDirectory: homebrew, homeDirectory: home),
      runner: ProcessRunner(pipeEOFGrace: .milliseconds(500), killGrace: .seconds(2)),
      openPath: bin.path("open"),
      osascriptPath: bin.path("osascript"),
      temporaryDirectory: temporary
    )
  }

  func installOpen(exitCode: Int32 = 0, stderr: String = "") throws {
    try bin.install(
      "open", script: recorder(exitCode: exitCode, stderr: stderr, inspectLastArgument: true))
  }

  func installOsascript(exitCode: Int32 = 0, stderr: String = "") throws {
    try bin.install(
      "osascript", script: recorder(exitCode: exitCode, stderr: stderr, inspectLastArgument: false))
  }

  func installLimactl() throws {
    let script = """
      #!/bin/sh
      d="$(dirname "$0")"
      for a in "$@"; do printf '%s\\0' "$a"; done > "$d/limactl.args"
      printf '%s' "$LIMA_HOME" > "$d/limactl.home"
      """
    let url = URL(fileURLWithPath: homebrew).appendingPathComponent("limactl")
    try Data((script + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func recorder(exitCode: Int32, stderr: String, inspectLastArgument: Bool) -> String {
    var lines = [
      "#!/bin/sh",
      "d=\"$(dirname \"$0\")\"",
      "name=\"$(basename \"$0\")\"",
      "for a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$d/$name.args\"",
    ]
    if inspectLastArgument {
      lines += [
        "for last; do :; done",
        "stat -f %Lp \"$last\" > \"$d/$name.mode\"",
        "cp \"$last\" \"$d/$name.copy\"",
      ]
    }
    if !stderr.isEmpty {
      lines.append("printf '%s' '\(stderr.replacingOccurrences(of: "'", with: #"'\''"#))' >&2")
    }
    lines.append("exit \(exitCode)")
    return lines.joined(separator: "\n") + "\n"
  }

  func recordedArguments(_ tool: String, in directory: String? = nil) throws -> [String] {
    let text = try recorded("\(tool).args", in: directory)
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  func didRun(_ tool: String) -> Bool {
    FileManager.default.fileExists(atPath: bin.path("\(tool).args"))
  }

  func recorded(_ name: String, in directory: String? = nil) throws -> String {
    let base = directory.map { URL(fileURLWithPath: $0) } ?? bin.directory
    return try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
  }

  var scriptFiles: [String] {
    let directory = temporary.appendingPathComponent("cc.tk37.ColimaGUI").path
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
  }
}

private func machine(_ name: String = "dev") throws -> MachineName {
  try MachineName.parse(name, limaHomeUTF8Count: 20).get()
}

private func customApp(path: String = "/Applications/iTerm.app") -> CustomTerminalApp {
  CustomTerminalApp(path: path, bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm")
}

@Suite("ShellCommandScript")
struct ShellCommandScriptTests {
  @Test func singleQuoteIsEscapedInsideSingleQuotes() {
    #expect(ShellCommandScript.quote("it's") == #"'it'\''s'"#)
    #expect(ShellCommandScript.quote("") == "''")
    #expect(ShellCommandScript.quote("a b $HOME `x` \"y\" \\z") == "'a b $HOME `x` \"y\" \\z'")
    #expect(ShellCommandScript.quote("'") == #"''\'''"#)
  }

  @Test func aScriptThatNeverRanIsRemovedOnTheNextWriteButARecentOneIsKept() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "scripts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let directory = temporary.appendingPathComponent(ShellCommandScript.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stale = directory.appendingPathComponent("shell-stale.command")
    let recent = directory.appendingPathComponent("shell-recent.command")
    let unrelated = directory.appendingPathComponent("notes.txt")
    for file in [stale, recent, unrelated] { try Data("x".utf8).write(to: file) }
    let now = Date()
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-ShellCommandScript.staleAfter - 60)], ofItemAtPath: stale.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-ShellCommandScript.staleAfter - 60)], ofItemAtPath: unrelated.path)

    let written = try ShellCommandScript.write("#!/bin/sh\n", in: temporary, now: now)

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(FileManager.default.fileExists(atPath: written.path))
  }

  @Test func bodyHasTheDesignedShape() {
    let body = ShellCommandScript.body(
      limactlPath: "/opt/homebrew/bin/limactl", limaHome: "/Users/a/.lima", instanceName: "cg-dev")

    #expect(
      body == """
        #!/bin/sh
        rm -f -- "$0"
        export PATH='\(ChildEnvironment.path)'
        export LIMA_HOME='/Users/a/.lima'
        exec '/opt/homebrew/bin/limactl' shell --start=false 'cg-dev'

        """)
  }
}

@Suite("TerminalShellLauncher: Terminal.app と任意のアプリ")
struct TerminalShellLauncherScriptTests {
  @Test func terminalGetsAScriptThroughOpenWithItsBundleIdentifier() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen()

    let result = await harness.launcher().openShell(for: try machine(), in: .terminal)

    #expect(result.isSuccess)
    let arguments = try harness.recordedArguments("open")
    #expect(arguments.count == 3)
    #expect(Array(arguments.prefix(2)) == ["-b", "com.apple.Terminal"])
    let file = try #require(arguments.last)
    #expect(
      file.hasPrefix(harness.temporary.appendingPathComponent("cc.tk37.ColimaGUI").path + "/shell-")
    )
    #expect(file.hasSuffix(".command"))
    #expect(harness.scriptFiles.count == 1)
  }

  @Test func scriptFileIsOwnerOnly() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen()

    _ = await harness.launcher().openShell(for: try machine(), in: .terminal)

    #expect(
      try harness.recorded("open.mode").trimmingCharacters(in: .whitespacesAndNewlines) == "700")
  }

  @Test func customAppReceivesItsPathWithDashA() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen()
    let app = try harness.makeAppDirectory(named: "iTerm.app")

    let result = await harness.launcher().openShell(
      for: try machine(), in: .custom(customApp(path: app)))

    #expect(result.isSuccess)
    let arguments = try harness.recordedArguments("open")
    #expect(Array(arguments.prefix(2)) == ["-a", app])
    #expect(arguments.count == 3)
  }

  @Test func scriptQuotesHostilePathsAndRunsLimactlThenDeletesItself() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen()
    try harness.installLimactl()

    _ = await harness.launcher().openShell(for: try machine("dev"), in: .terminal)

    let copy = harness.bin.path("open.copy")
    let body = try harness.recorded("open.copy")
    #expect(
      body.contains(
        "exec '\(harness.homebrew.replacingOccurrences(of: "'", with: #"'\''"#))/limactl'"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [copy]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(
      try harness.recordedArguments("limactl", in: harness.homebrew) == [
        "shell", "--start=false", "cg-dev",
      ])
    #expect(try harness.recorded("limactl.home", in: harness.homebrew) == harness.home + "/.lima")
    #expect(!FileManager.default.fileExists(atPath: copy))
  }

  @Test func openFailureIsReportedWithItsStderrAndLeavesNoScript() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen(exitCode: 1, stderr: "Unable to find application named 'X'")

    let result = await harness.launcher().openShell(for: try machine(), in: .terminal)

    #expect(result.failure == .failed(detail: "Unable to find application named 'X'"))
    #expect(harness.scriptFiles.isEmpty)
  }

  @Test func openFailureWithoutStderrStillNamesTheExitCode() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen(exitCode: 3)

    let result = await harness.launcher().openShell(for: try machine(), in: .terminal)

    guard case .failed(let detail) = result.failure else {
      Issue.record("expected .failed, got \(String(describing: result.failure))")
      return
    }
    #expect(detail.contains("3"))
  }

  @Test func missingOpenExecutableIsAFailure() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }

    let result = await harness.launcher().openShell(for: try machine(), in: .terminal)

    guard case .failed(let detail) = result.failure else {
      Issue.record("expected .failed, got \(String(describing: result.failure))")
      return
    }
    #expect(!detail.isEmpty)
    #expect(harness.scriptFiles.isEmpty)
  }

  @Test func unknownTerminalSpawnsNothingAndWritesNoFile() async throws {
    let harness = try Harness(known: [])
    defer { harness.bin.remove() }
    try harness.installOpen()

    let result = await harness.launcher().openShell(for: try machine(), in: .terminal)

    #expect(result.failure == .applicationNotFound)
    #expect(!harness.didRun("open"))
    #expect(harness.scriptFiles.isEmpty)
  }

  @Test func missingCustomAppSpawnsNothing() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOpen()

    let result = await harness.launcher().openShell(
      for: try machine(), in: .custom(customApp(path: harness.bin.path("Gone.app"))))

    #expect(result.failure == .applicationNotFound)
    #expect(!harness.didRun("open"))
    #expect(harness.scriptFiles.isEmpty)
  }
}

@Suite("TerminalShellLauncher: Ghostty")
struct TerminalShellLauncherGhosttyTests {
  @Test func ghosttyGetsAnAppleScriptWithTheValuesAsArguments() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOsascript()

    let result = await harness.launcher().openShell(for: try machine("dev"), in: .ghostty)

    #expect(result.isSuccess)
    let arguments = try harness.recordedArguments("osascript")
    #expect(
      Array(arguments.suffix(3)) == [
        "cg-dev", harness.home + "/.lima", harness.homebrew + "/limactl",
      ])
    let flags = arguments.dropLast(3)
    #expect(!flags.isEmpty)
    #expect(flags.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element == "-e" : true })
    let script = stride(from: 1, to: flags.count, by: 2).map { flags[flags.startIndex + $0] }
      .joined(separator: "\n")
    #expect(script.contains(#"tell application id "com.mitchellh.ghostty""#))
    #expect(script.contains("new surface configuration"))
    #expect(script.contains("new window with configuration"))
    #expect(script.contains("environment variables"))
    #expect(!script.contains("cg-dev"))
    #expect(!script.contains(harness.home))
    #expect(harness.scriptFiles.isEmpty)
    #expect(!harness.didRun("open"))
  }

  @Test func deniedAutomationIsClassified() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOsascript(
      exitCode: 1,
      stderr: "execution error: Not authorized to send Apple events to Ghostty. (-1743)")

    let result = await harness.launcher().openShell(for: try machine(), in: .ghostty)

    #expect(result.failure == .automationDenied)
  }

  @Test func otherOsascriptFailuresKeepTheirText() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    try harness.installOsascript(
      exitCode: 1, stderr: "syntax error: Expected end of line (-2741)\n")

    let result = await harness.launcher().openShell(for: try machine(), in: .ghostty)

    #expect(result.failure == .failed(detail: "syntax error: Expected end of line (-2741)"))
  }

  @Test func missingGhosttySpawnsNothing() async throws {
    let harness = try Harness(known: ["com.apple.Terminal"])
    defer { harness.bin.remove() }
    try harness.installOsascript()

    let result = await harness.launcher().openShell(for: try machine(), in: .ghostty)

    #expect(result.failure == .applicationNotFound)
    #expect(!harness.didRun("osascript"))
  }
}

@Suite("TerminalShellLauncher: アプリの有無と選択の検証")
struct TerminalShellLauncherApplicationTests {
  @Test func availabilityLooksUpTheBundleIdentifierOfEachBuiltInChoice() async throws {
    let harness = try Harness(known: ["com.apple.Terminal"])
    defer { harness.bin.remove() }
    let launcher = harness.launcher()

    #expect(await launcher.availability(of: .terminal) == .available)
    #expect(await launcher.availability(of: .ghostty) == .notFound)
    #expect(harness.located.asked == ["com.apple.Terminal", "com.mitchellh.ghostty"])
  }

  @Test func customAvailabilityIsTheExistenceOfThePath() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    let launcher = harness.launcher()
    let app = try harness.makeAppDirectory(named: "Here.app")

    #expect(await launcher.availability(of: .custom(customApp(path: app))) == .available)
    #expect(
      await launcher.availability(of: .custom(customApp(path: harness.bin.path("Gone.app"))))
        == .notFound)
    #expect(harness.located.asked.isEmpty)
  }

  @Test func applicationBundleIsAccepted() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    let app = try harness.makeAppDirectory(
      named: "Fancy Term.app",
      info: [
        "CFBundleIdentifier": "org.example.fancy", "CFBundlePackageType": "APPL",
        "CFBundleName": "Fancy",
      ])

    let accepted = await harness.launcher().application(at: URL(fileURLWithPath: app))

    #expect(
      accepted
        == CustomTerminalApp(path: app, bundleIdentifier: "org.example.fancy", displayName: "Fancy")
    )
  }

  @Test func displayNameFallsBackToTheFileName() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    let app = try harness.makeAppDirectory(
      named: "Plain.app",
      info: ["CFBundleIdentifier": "org.example.plain", "CFBundlePackageType": "APPL"])

    let accepted = await harness.launcher().application(at: URL(fileURLWithPath: app))

    #expect(accepted?.displayName == "Plain")
  }

  @Test func nonApplicationsAreRejected() async throws {
    let harness = try Harness()
    defer { harness.bin.remove() }
    let launcher = harness.launcher()
    let valid: [String: String] = [
      "CFBundleIdentifier": "org.example.x", "CFBundlePackageType": "APPL",
    ]

    let plainFile = harness.bin.path("file.app")
    try Data("x".utf8).write(to: URL(fileURLWithPath: plainFile))
    let notApp = try harness.makeAppDirectory(named: "Folder", info: valid)
    let noIdentifier = try harness.makeAppDirectory(
      named: "NoId.app", info: ["CFBundlePackageType": "APPL"])
    let framework = try harness.makeAppDirectory(
      named: "Lib.app",
      info: ["CFBundleIdentifier": "org.example.lib", "CFBundlePackageType": "FMWK"])
    let noInfo = bin(harness, "Bare.app")
    try FileManager.default.createDirectory(atPath: noInfo, withIntermediateDirectories: true)

    for path in [
      plainFile, notApp, noIdentifier, framework, noInfo, harness.bin.path("Missing.app"),
    ] {
      #expect(await launcher.application(at: URL(fileURLWithPath: path)) == nil, "\(path)")
    }
  }

  private func bin(_ harness: Harness, _ name: String) -> String { harness.bin.path(name) }
}

extension Harness {
  fileprivate func makeAppDirectory(
    named name: String,
    info: [String: String] = [
      "CFBundleIdentifier": "org.example.iterm", "CFBundlePackageType": "APPL",
    ]
  ) throws -> String {
    let contents = bin.directory.appendingPathComponent(name).appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return bin.directory.appendingPathComponent(name).path
  }
}

extension Result where Success == Void, Failure == ShellLaunchError {
  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  fileprivate var failure: ShellLaunchError? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
