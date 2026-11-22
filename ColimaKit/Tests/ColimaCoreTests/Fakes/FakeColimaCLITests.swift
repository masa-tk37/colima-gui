import Testing

@testable import ColimaCore

private func collect(_ run: VMCommandRun) async -> [ProcessEvent] {
  var events: [ProcessEvent] = []
  for await event in run.events { events.append(event) }
  return events
}

private let missingColima = ToolchainStatus(
  colima: .missing(searched: ["/opt/homebrew/bin"]), missingByVMType: [:])

@Test func cliRecordsCallsInInvocationOrder() async throws {
  let cli = FakeColimaCLI()
  _ = await cli.preflight()
  _ = try await cli.listDefault()
  let run = await cli.run(.stop)
  _ = await run.terminate()
  _ = await cli.run(.delete)
  _ = try? await cli.sampleUsage()

  #expect(cli.calls == [.preflight, .listDefault, .run(.stop), .run(.delete), .sampleUsage])
}

@Test func cliReturnsConfiguredPreflightAndObservations() async throws {
  let cli = FakeColimaCLI()
  cli.configure {
    $0.toolchain = missingColima
    $0.listDefault = [.success(.unknown(reason: "first")), .success(.absent), .failure(.timedOut)]
  }

  #expect(await cli.preflight() == missingColima)
  #expect(try await cli.listDefault() == .unknown(reason: "first"))
  #expect(try await cli.listDefault() == .absent)
  await #expect(throws: ColimaCLIError.timedOut) { try await cli.listDefault() }
  await #expect(throws: ColimaCLIError.timedOut) { try await cli.listDefault() }
}

@Test func cliUnconfiguredUsageSampleFailsInsteadOfInventingData() async {
  let cli = FakeColimaCLI()
  await #expect(
    throws: ColimaCLIError.undecodable(detail: "FakeColimaCLI.sampleUsage is not configured")
  ) {
    try await cli.sampleUsage()
  }
}

private func cancelledResult<T: Sendable>(
  _ body: @escaping @Sendable () async throws -> T
) async -> ColimaCLIError? {
  await Task { () -> ColimaCLIError? in
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      _ = try await body()
      return nil
    } catch {
      return error as? ColimaCLIError
    }
  }.value
}

@Test func cliCancelledTaskGetsCancelledErrorOverConfiguredResult() async {
  let cli = FakeColimaCLI()
  cli.configure { $0.listDefault = [.success(.absent)] }

  #expect(await cancelledResult { try await cli.listDefault() } == .cancelled)
  #expect(await cancelledResult { try await cli.sampleUsage() } == .cancelled)
}

@Test func cliManualRunDeliversFedOutputThenExit() async {
  let cli = FakeColimaCLI()
  let run = await cli.run(.start)
  let process = await cli.process(at: 0)

  process.send("booting")
  process.send("ready")
  process.exit(code: 0)
  process.send("ignored after exit")

  #expect(process.command == .start)
  #expect(await collect(run) == [.output("booting"), .output("ready"), .exited(code: 0)])
}

@Test func cliRunCanReportLaunchFailure() async {
  let cli = FakeColimaCLI()
  let run = await cli.run(.start)
  await cli.process(at: 0).failLaunch(reason: "no such file")
  #expect(await collect(run) == [.launchFailed(reason: "no such file")])
}

@Test func cliTerminateIsRecordedAndStillEndsTheStream() async {
  let cli = FakeColimaCLI()
  let run = await cli.run(.start)
  let process = await cli.process(at: 0)
  process.send("starting")

  #expect(process.terminateCount == 0)
  #expect(await run.terminate())
  #expect(await run.terminate() == false)

  #expect(process.terminateCount == 2)
  #expect(await collect(run) == [.output("starting"), .exited(code: 143)])
}

@Test func cliTerminateAfterExitKeepsTheOriginalExit() async {
  let cli = FakeColimaCLI()
  let run = await cli.run(.stop)
  let process = await cli.process(at: 0)
  process.exit(code: 0)
  await run.terminate()

  #expect(process.terminateCount == 1)
  #expect(await collect(run) == [.exited(code: 0)])
}

@Test func cliScriptedRunDeliversItsEventsImmediately() async {
  let cli = FakeColimaCLI()
  cli.configure {
    $0.scriptedRuns = [[.output("a"), .exited(code: 1)]]
  }

  let first = await cli.run(.start)
  let second = await cli.run(.start)
  await cli.process(at: 1).exit(code: 0)

  #expect(await collect(first) == [.output("a"), .exited(code: 1)])
  #expect(await collect(second) == [.exited(code: 0)])
  #expect(cli.processes.count == 2)
}

@Test func cliProcessLookupWaitsForARunStartedLater() async {
  let cli = FakeColimaCLI()
  let waiter = Task { await cli.process(at: 0).command }
  await Task.yield()
  _ = await cli.run(.delete)
  #expect(await waiter.value == .delete)
}
