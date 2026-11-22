import ColimaCore
import Darwin
import Foundation
import Testing

@testable import ColimaProcess

private struct Sandbox {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProcessRunnerStreamingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func path(_ name: String) -> String {
    directory.appendingPathComponent(name).path
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func waitForPID(timeout: Duration = .seconds(20)) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if let text = try? String(contentsOfFile: path("pid"), encoding: .utf8), text.hasSuffix("\n"),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return pid
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for pid")
    return 0
  }
}

private func shell(_ script: String, in sandbox: Sandbox) -> ProcessInvocation {
  ProcessInvocation(
    executable: "/bin/sh",
    arguments: ["-c", script],
    environment: ChildEnvironment.make(
      home: sandbox.directory.path, user: "tester", tmp: sandbox.directory.path + "/"),
    workingDirectory: sandbox.directory.path,
    timeout: nil
  )
}

private func isAlive(_ pid: pid_t) -> Bool {
  kill(pid, 0) == 0
}

struct ProcessRunnerStreamingTests {
  @Test func everyLineOfAFastScriptArrivesBeforeExited() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let script = "for i in 1 2 3 4 5 6 7 8 9 10; do echo out$i; echo err$i >&2; done"
    let run = await ProcessRunner().run(shell(script, in: sandbox))
    let events = await collectEvents(run)

    #expect(events.last == .exited(code: 0))
    let lines = events.dropLast().compactMap { event -> String? in
      if case .output(let line) = event { line } else { nil }
    }
    #expect(events.count == 21)
    #expect(lines.filter { $0.hasPrefix("out") }.sorted() == (1...10).map { "out\($0)" }.sorted())
    #expect(lines.filter { $0.hasPrefix("err") }.sorted() == (1...10).map { "err\($0)" }.sorted())
  }

  @Test func stdoutAndStderrLinesAreMergedInArrivalOrder() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let script =
      "echo out1; sleep 0.3; echo err1 >&2; sleep 0.3; echo out2; sleep 0.3; echo err2 >&2"
    let events = await collectEvents(await ProcessRunner().run(shell(script, in: sandbox)))

    #expect(
      events == [
        .output("out1"), .output("err1"), .output("out2"), .output("err2"), .exited(code: 0),
      ])
  }

  @Test func unterminatedLastLineIsFlushedPerStreamBeforeExited() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let events = await collectEvents(
      await ProcessRunner().run(shell("printf 'a\\nb'; printf 'c' >&2", in: sandbox)))

    #expect(events.last == .exited(code: 0))
    let lines = events.dropLast().compactMap { event -> String? in
      if case .output(let line) = event { line } else { nil }
    }
    #expect(lines.sorted() == ["a", "b", "c"])
    #expect(events.count == 4)
  }

  @Test func nonZeroExitCodeIsReported() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let events = await collectEvents(
      await ProcessRunner().run(shell("echo boom >&2; exit 3", in: sandbox)))

    #expect(events == [.output("boom"), .exited(code: 3)])
  }

  @Test func terminateEndsASleepingChildWithExited() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().run(
      shell("echo $$ > pid; echo started; exec sleep 60", in: sandbox))
    let pid = try await sandbox.waitForPID()

    #expect(await run.terminate())
    let events = await collectEvents(run)

    #expect(events.first == .output("started"))
    #expect(events.last == .exited(code: 128 + SIGTERM))
    #expect(!isAlive(pid))
  }

  @Test func terminateKillsAChildThatIgnoresSIGTERMAfterTheKillGrace() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner(killGrace: .milliseconds(500))
      .run(shell("trap '' TERM; echo $$ > pid; while :; do sleep 0.1; done", in: sandbox))
    let pid = try await sandbox.waitForPID()

    #expect(await run.terminate())
    _ = await run.terminate()
    let events = await collectEvents(run)

    #expect(events == [.exited(code: 128 + SIGKILL)])
    #expect(!isAlive(pid))
  }

  @Test func cancellingTheEventConsumerDoesNotTerminateTheChild() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let run = await ProcessRunner().run(shell("echo $$ > pid; exec sleep 60", in: sandbox))
    let consumer = Task { await collectEvents(run) }
    let pid = try await sandbox.waitForPID()
    try await Task.sleep(for: .milliseconds(100))

    consumer.cancel()
    _ = await consumer.value
    try await Task.sleep(for: .milliseconds(500))

    #expect(isAlive(pid))

    #expect(await run.terminate())
    let deadline = ContinuousClock.now + .seconds(20)
    while isAlive(pid), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!isAlive(pid))
  }

  @Test func cancellingTheCallingTaskStillLaunchesAndDoesNotTerminate() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let invocation = shell("echo $$ > pid; echo ran; sleep 1; echo done", in: sandbox)
    let runner = ProcessRunner()
    let events = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let run = await runner.run(invocation)
      return await Task { await collectEvents(run) }.value
    }.value

    #expect(events == [.output("ran"), .output("done"), .exited(code: 0)])
  }

  @Test func missingExecutableEndsWithLaunchFailedOnly() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let invocation = ProcessInvocation(
      executable: sandbox.path("does-not-exist"),
      arguments: [],
      environment: [:],
      workingDirectory: sandbox.directory.path,
      timeout: nil
    )
    let run = await ProcessRunner().run(invocation)
    #expect(await run.terminate() == false)
    let events = await collectEvents(run)

    #expect(events.count == 1)
    guard case .launchFailed(let reason) = events.first else {
      Issue.record("expected launchFailed, got \(events)")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func grandchildHoldingThePipesDoesNotKeepExitedFromArriving() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }

    let started = ContinuousClock.now
    let run = await ProcessRunner(pipeEOFGrace: .milliseconds(500))
      .run(shell("sleep 30 & echo $! > pid; echo hi", in: sandbox))
    let events = await collectEvents(run)
    let elapsed = ContinuousClock.now - started

    if let pid = try? await sandbox.waitForPID() { kill(pid, SIGKILL) }

    #expect(events == [.output("hi"), .exited(code: 0)])
    #expect(elapsed < .seconds(10))
  }
}
