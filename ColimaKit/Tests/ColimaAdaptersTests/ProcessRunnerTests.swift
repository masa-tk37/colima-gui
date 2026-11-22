import Darwin
import Foundation
import Testing

@testable import ColimaProcess

private struct Sandbox {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func path(_ name: String) -> String {
    directory.appendingPathComponent(name).path
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func waitForFile(_ name: String, timeout: Duration = .seconds(20)) async throws -> String {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if let text = try? String(contentsOfFile: path(name), encoding: .utf8), text.hasSuffix("\n") {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(name)")
    return ""
  }
}

private func shell(_ script: String, timeout: Duration? = nil, in sandbox: Sandbox)
  -> ProcessInvocation
{
  ProcessInvocation(
    executable: "/bin/sh",
    arguments: ["-c", script],
    environment: ChildEnvironment.make(
      home: sandbox.directory.path, user: "tester", tmp: sandbox.directory.path + "/"),
    workingDirectory: sandbox.directory.path,
    timeout: timeout
  )
}

private func isAlive(_ pid: pid_t) -> Bool {
  kill(pid, 0) == 0
}

struct ProcessRunnerTests {
  @Test func collectsStdoutAndStderrSeparately() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().runCollecting(
      shell("echo out1; echo err1 >&2; echo out2", in: sandbox))

    #expect(run.termination == .exited(code: 0))
    #expect(run.stdoutText == "out1\nout2\n")
    #expect(run.stderrText == "err1\n")
  }

  @Test func nonZeroExitReportsCode() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().runCollecting(
      shell("echo partial; echo boom >&2; exit 3", in: sandbox))

    #expect(run.termination == .exited(code: 3))
    #expect(run.stdoutText == "partial\n")
    #expect(run.stderrText == "boom\n")
  }

  @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let script = "yes x | head -c 1000000 >&2 & yes y | head -c 1000000; wait"
    let run = await ProcessRunner().runCollecting(shell(script, in: sandbox))

    #expect(run.termination == .exited(code: 0))
    #expect(run.stdout.count == 1_000_000)
    #expect(run.stderr.count == 1_000_000)
  }

  @Test func invalidUTF8BecomesReplacementCharacterInText() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().runCollecting(
      shell(#"printf 'a\377b'; printf '\376' >&2"#, in: sandbox))

    #expect(run.stdout == [0x61, 0xFF, 0x62])
    #expect(run.stdoutText == "a\u{FFFD}b")
    #expect(run.stderrText == "\u{FFFD}")
  }

  @Test func missingExecutableIsLaunchFailed() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    var invocation = shell("true", in: sandbox)
    invocation = ProcessInvocation(
      executable: sandbox.path("does-not-exist"),
      arguments: [],
      environment: invocation.environment,
      workingDirectory: invocation.workingDirectory,
      timeout: nil
    )

    let run = await ProcessRunner().runCollecting(invocation)

    guard case .launchFailed(let reason) = run.termination else {
      Issue.record("expected launchFailed, got \(run.termination)")
      return
    }
    #expect(!reason.isEmpty)
    #expect(run.stdout.isEmpty)
    #expect(run.stderr.isEmpty)
  }

  @Test func environmentIsExactlyTheInvocationSet() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let environment = ChildEnvironment.make(home: "/Users/x", user: "x", tmp: "/tmp/x/")
    let invocation = ProcessInvocation(
      executable: "/usr/bin/env",
      arguments: [],
      environment: environment,
      workingDirectory: sandbox.directory.path,
      timeout: nil
    )

    let run = await ProcessRunner().runCollecting(invocation)

    #expect(run.termination == .exited(code: 0))
    let lines = run.stdoutText.split(separator: "\n").map(String.init)
    let seen = Dictionary(
      uniqueKeysWithValues: lines.compactMap { line -> (String, String)? in
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return (String(line[..<eq]), String(line[line.index(after: eq)...]))
      })
    #expect(seen == environment)
  }

  @Test func stdinIsDevNullAndWorkingDirectoryIsTheInvocationDirectory() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().runCollecting(
      shell(#"if read line; then echo "got:$line"; else echo eof; fi; pwd -P"#, in: sandbox)
    )

    let lines = run.stdoutText.split(separator: "\n").map(String.init)
    #expect(lines.first == "eof")
    #expect(lines.last == realpath(sandbox.directory.path, nil).map { String(cString: $0) })
  }

  @Test func timeoutTerminatesTheChild() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let started = ContinuousClock.now
    let run = await ProcessRunner().runCollecting(
      shell("echo $$ > pid; exec sleep 60", timeout: .milliseconds(500), in: sandbox)
    )

    #expect(run.termination == .timedOut)
    #expect(ContinuousClock.now - started < .seconds(20))
    let pid = try #require(Int32(try await sandbox.waitForFile("pid")))
    #expect(!isAlive(pid))
  }

  @Test func taskCancellationTerminatesTheChild() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let invocation = shell("echo $$ > pid; echo started; exec sleep 60", in: sandbox)
    let task = Task { await ProcessRunner().runCollecting(invocation) }
    let pid = try #require(Int32(try await sandbox.waitForFile("pid")))

    task.cancel()
    let run = await task.value

    #expect(run.termination == .cancelled)
    #expect(!isAlive(pid))
  }

  @Test func cancellationBeforeStartDoesNotLaunch() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let invocation = shell("echo ran > ran", in: sandbox)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await ProcessRunner().runCollecting(invocation)
    }
    let run = await task.value

    #expect(run.termination == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: sandbox.path("ran")))
  }

  @Test func childIgnoringSIGTERMIsKilledAfterTheKillGrace() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let runner = ProcessRunner(killGrace: .milliseconds(500))
    let script = "trap '' TERM; echo $$ > pid; while :; do sleep 0.1; done"
    let run = await runner.runCollecting(shell(script, timeout: .milliseconds(800), in: sandbox))

    #expect(run.termination == .timedOut)
    let pid = try #require(Int32(try await sandbox.waitForFile("pid")))
    #expect(!isAlive(pid))
  }

  @Test func outputWrittenAfterParentExitIsStillCollected() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let started = ContinuousClock.now
    let run = await ProcessRunner().runCollecting(
      shell("(sleep 1; echo late) & echo first", in: sandbox)
    )

    #expect(run.termination == .exited(code: 0))
    #expect(run.stdoutText == "first\nlate\n")
    #expect(ContinuousClock.now - started < .seconds(4))
  }

  @Test func grandchildHoldingThePipesDelaysTheResultByAtMostFiveSeconds() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let started = ContinuousClock.now
    let run = await ProcessRunner().runCollecting(
      shell("sleep 30 & echo $! > grandchild; echo hi", in: sandbox)
    )
    let elapsed = ContinuousClock.now - started

    let grandchild = Int32(try await sandbox.waitForFile("grandchild"))
    if let grandchild { kill(grandchild, SIGKILL) }

    #expect(run.termination == .exited(code: 0))
    #expect(run.stdoutText == "hi\n")
    #expect(elapsed >= .seconds(4.5))
    #expect(elapsed < .seconds(9))
  }
}
