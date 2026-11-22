import ColimaCore
import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

/// Every live test is gated twice: the `Live` suite trait skips it, and `requireEnabled()` throws if anything still reaches the helpers.
enum LiveEnvironment {
  static let variable = "COLIMA_GUI_LIVE_TESTS"

  static var isEnabled: Bool { ProcessInfo.processInfo.environment[variable] == "1" }

  static func requireEnabled() throws {
    guard isEnabled else { throw LiveError.notEnabled }
  }

  static var engineSocketPath: String { NSHomeDirectory() + "/.colima/default/docker.sock" }
  static let dockerExecutable = "/opt/homebrew/bin/docker"
  static let colimaExecutable = "/opt/homebrew/bin/colima"
  static let curlExecutable = "/usr/bin/curl"

  /// Runs VM commands in-process: a test runner cannot register the SMAppService agent.
  static func colimaCLI() -> ColimaCommandLine {
    ColimaCommandLine(
      invocation: ColimaInvocation(), runner: ProcessRunner(), vmCommands: LocalVMCommandLauncher(),
      usageTimeout: .seconds(2))
  }

  /// A local image whose `Config.Volumes` is empty, so a throwaway container cannot create anonymous volumes.
  static var imageReference: String {
    ProcessInfo.processInfo.environment["COLIMA_GUI_LIVE_IMAGE"] ?? "amazon/aws-cli:latest"
  }
}

enum LiveError: Error, CustomStringConvertible {
  case notEnabled
  case commandFailed(command: String, status: Int32, stderr: String)
  case unsafeImage(String)
  case notOwned(String)
  case unexpectedOutput(String)

  var description: String {
    switch self {
    case .notEnabled: "live tests are disabled; set \(LiveEnvironment.variable)=1"
    case .commandFailed(let command, let status, let stderr):
      "\(command) exited \(status): \(stderr)"
    case .unsafeImage(let reason): "image is not usable for throwaway containers: \(reason)"
    case .notOwned(let name): "refusing to touch a resource this test did not create: \(name)"
    case .unexpectedOutput(let detail): "unexpected output: \(detail)"
    }
  }
}

/// Facts the live run settles; the lines are copied into research.md by hand.
func recordFinding(_ text: String) {
  print("LIVE-FINDING \(text)")
}

struct ProcessOutput {
  let status: Int32
  let stdout: String
  let stderr: String
}

/// Blocking on purpose: it must also work from cleanup paths, and every command here finishes in well under a
/// second. Output is small, so reading the two pipes one after the other cannot fill either.
func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String]) throws
  -> ProcessOutput
{
  try LiveEnvironment.requireEnabled()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = environment
  let out = Pipe()
  let err = Pipe()
  process.standardOutput = out
  process.standardError = err
  process.standardInput = FileHandle.nullDevice
  try process.run()
  let stdout = out.fileHandleForReading.readDataToEndOfFile()
  let stderr = err.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return ProcessOutput(
    status: process.terminationStatus,
    stdout: String(decoding: stdout, as: UTF8.self),
    stderr: String(decoding: stderr, as: UTF8.self)
  )
}

/// The engine port has no create methods, so the fixtures of the live tests come from the CLI.
func docker(_ arguments: [String]) throws -> String {
  let output = try runBlocking(
    LiveEnvironment.dockerExecutable,
    arguments,
    environment: [
      "DOCKER_HOST": "unix://" + LiveEnvironment.engineSocketPath,
      "HOME": NSHomeDirectory(),
      "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    ]
  )
  guard output.status == 0 else {
    throw LiveError.commandFailed(
      command: "docker " + arguments.joined(separator: " "), status: output.status,
      stderr: output.stderr)
  }
  return output.stdout
}

func dockerLines(_ arguments: [String]) throws -> [String] {
  try docker(arguments).split(whereSeparator: \.isNewline).map(String.init)
}

/// Read-only raw `GET` on the engine socket, for the fields the adapter normalizes away (for example `Size: -1`).
func rawEngineGET(_ path: String) throws -> Data {
  let output = try runBlocking(
    LiveEnvironment.curlExecutable,
    [
      "--silent", "--show-error", "--unix-socket", LiveEnvironment.engineSocketPath,
      "http://docker/v1.54" + path,
    ],
    environment: ["PATH": "/usr/bin:/bin"]
  )
  guard output.status == 0 else {
    throw LiveError.commandFailed(
      command: "curl GET \(path)", status: output.status, stderr: output.stderr)
  }
  return Data(output.stdout.utf8)
}

/// The `cgprobe-` prefix keeps cleanup (a list-then-prefix filter, because `--filter name=` matches substrings)
/// away from resources of the user or of another scope. Anonymous volumes have engine-chosen names, so each is recorded at creation.
final class LiveScope: Sendable {
  let prefix: String
  let client: DockerEngineClient

  private let recorded = Mutex<(volumes: [String], containers: [ContainerID])>(([], []))

  init() {
    let token = UUID().uuidString.lowercased().prefix(8)
    prefix = "cgprobe-\(token)-"
    client = DockerEngineClient(socketPath: LiveEnvironment.engineSocketPath)
  }

  func name(_ suffix: String) -> String { prefix + suffix }

  func owned(_ name: String) throws -> String {
    let isRecorded = recorded.withLock { $0.volumes.contains(name) }
    guard name.hasPrefix(prefix) || isRecorded else { throw LiveError.notOwned(name) }
    return name
  }

  func owned(_ id: ContainerID) throws -> ContainerID {
    guard recorded.withLock({ $0.containers.contains(id) }) else {
      throw LiveError.notOwned(id.rawValue)
    }
    return id
  }

  private func requireImageWithoutVolumes() throws {
    let json = try docker(["image", "inspect", LiveEnvironment.imageReference])
    guard let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
      let config = array.first?["Config"] as? [String: Any]
    else { throw LiveError.unsafeImage("inspect output could not be read") }
    if let volumes = config["Volumes"] as? [String: Any], !volumes.isEmpty {
      throw LiveError.unsafeImage("\(LiveEnvironment.imageReference) declares VOLUME")
    }
  }

  func createContainer(
    _ suffix: String,
    script: String,
    extraArguments: [String] = []
  ) throws -> (id: ContainerID, name: String) {
    try requireImageWithoutVolumes()
    let name = name(suffix)
    let output = try docker(
      ["create", "--name", name, "--pull", "never", "--stop-timeout", "1", "--label", "cgprobe=1"]
        + extraArguments
        + ["--entrypoint", "sh", LiveEnvironment.imageReference, "-c", script]
    )
    let id = ContainerID(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines))
    guard id.rawValue.count == 64 else {
      throw LiveError.unexpectedOutput("container id: \(output)")
    }
    recorded.withLock { $0.containers.append(id) }
    return (id, name)
  }

  func createVolume(_ suffix: String) throws -> String {
    let name = name(suffix)
    _ = try docker(["volume", "create", name])
    return name
  }

  func createAnonymousVolume() throws -> String {
    let name = try docker(["volume", "create"]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
      throw LiveError.unexpectedOutput("anonymous volume name: \(name)")
    }
    recorded.withLock { $0.volumes.append(name) }
    return name
  }

  func removeContainerWithCLI(_ id: ContainerID) throws {
    _ = try docker(["rm", "-v", try owned(id).rawValue])
  }

  /// Goes through the CLI so the adapter under test cannot hide a leak.
  func cleanUp() async -> [String] {
    var failures: [String] = []
    func attempt(_ arguments: [String]) {
      do { _ = try docker(arguments) } catch { failures.append("\(error)") }
    }

    do {
      let known = recorded.withLock { $0.containers }
      let listed = try dockerLines(["ps", "-a", "--format", "{{.ID}} {{.Names}}", "--no-trunc"])
      let ours = listed.compactMap { line -> String? in
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let isOurs = parts[1].hasPrefix(prefix) || known.contains(ContainerID(rawValue: parts[0]))
        return isOurs ? parts[0] : nil
      }
      for id in ours {
        _ = try? docker(["stop", "--time", "1", id])
        attempt(["rm", "-v", id])
      }

      let networks = try dockerLines(["network", "ls", "--format", "{{.Name}}"])
      for network in networks where network.hasPrefix(prefix) {
        attempt(["network", "rm", network])
      }

      let volumes = try dockerLines(["volume", "ls", "--format", "{{.Name}}"])
      let anonymous = recorded.withLock { $0.volumes }
      for volume in volumes where volume.hasPrefix(prefix) || anonymous.contains(volume) {
        attempt(["volume", "rm", volume])
      }
    } catch {
      failures.append("listing for cleanup failed: \(error)")
    }
    await client.shutdown()
    return failures
  }
}

func withLiveScope<T>(_ body: (LiveScope) async throws -> T) async throws -> T {
  try LiveEnvironment.requireEnabled()
  let scope = LiveScope()
  let result: Result<T, any Error>
  do {
    result = .success(try await body(scope))
  } catch {
    result = .failure(error)
  }
  let failures = await scope.cleanUp()
  for failure in failures { Issue.record("cleanup failed: \(failure)") }
  return try result.get()
}

func waitUntil(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(100))
  }
  return await condition()
}

/// Awaits `operation`, cancelling it after `timeout` so a stream that never ends fails the test instead of
/// hanging the run.
func bounded<T: Sendable>(
  _ timeout: Duration = .seconds(30),
  _ operation: @escaping @Sendable () async -> T
) async -> T {
  let task = Task { await operation() }
  let watchdog = Task {
    try? await Task.sleep(for: timeout)
    task.cancel()
  }
  let value = await task.value
  watchdog.cancel()
  return value
}
