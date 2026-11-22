import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters
@testable import ColimaProcess

@Suite(
  .serialized,
  .enabled(
    if: LiveEnvironment.isEnabled, "set COLIMA_GUI_LIVE_TESTS=1 to run against the real engine"))
enum Live {}

extension Live {
  /// Only read-only colima calls (`list --json`, `ssh -- cat /proc/...`); the VM is never started, stopped or changed.
  @Suite struct Colima {
    @Test func childEnvironmentCarriesOnlyTheFixedVariables() async throws {
      try LiveEnvironment.requireEnabled()
      let environment = ChildEnvironment.current()
      #expect(Set(environment.keys) == ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"])
      #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)

      let run = await ProcessRunner().runCollecting(
        ProcessInvocation(
          executable: "/usr/bin/env",
          arguments: [],
          environment: environment,
          workingDirectory: NSHomeDirectory(),
          timeout: .seconds(5)
        ))
      #expect(run.termination == .exited(code: 0))
      let seen = Set(
        run.stdoutText.split(whereSeparator: \.isNewline).compactMap {
          $0.split(separator: "=", maxSplits: 1).first.map(String.init)
        })
      #expect(seen == Set(environment.keys))
    }

    @Test func preflightFindsColimaAndTheToolsOfTheRunningVMType() async throws {
      try LiveEnvironment.requireEnabled()
      let status = await LiveEnvironment.colimaCLI().preflight()
      #expect(status.colima == .found(path: LiveEnvironment.colimaExecutable))

      let files = ColimaProfileFiles(baseDirectory: URL(fileURLWithPath: NSHomeDirectory()))
      let vmType = try #require(try files.readInstanceVMType())
      #expect(
        status.missingExecutables(for: vmType).isEmpty, "running VM type \(vmType) misses tools")
      recordFinding(
        "(6) preflight: colima=\(LiveEnvironment.colimaExecutable) vmType=\(vmType) missingByVMType=\(status.missingByVMType)"
      )
    }

    @Test func listDefaultMatchesTheRunningVMAsSeenByAnUnrestrictedShell() async throws {
      try LiveEnvironment.requireEnabled()
      let observation = try await LiveEnvironment.colimaCLI().listDefault()
      guard case .present(let instance) = observation else {
        Issue.record("expected the default VM to be present, got \(observation)")
        return
      }
      #expect(instance.runState == .running)
      #expect(instance.runtime == "docker")
      #expect(instance.cpus > 0)

      let raw = try runBlocking(
        LiveEnvironment.colimaExecutable, ["list", "--json"],
        environment: ProcessInfo.processInfo.environment)
      #expect(raw.status == 0)
      let row = try #require(
        raw.stdout.split(whereSeparator: \.isNewline)
          .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
          .first { $0["name"] as? String == "default" })
      #expect(row["cpus"] as? Int == instance.cpus)
      #expect((row["memory"] as? NSNumber)?.int64Value == instance.memoryBytes)
      #expect((row["disk"] as? NSNumber)?.int64Value == instance.diskBytes)
      #expect(row["status"] as? String == "Running")
      recordFinding(
        "(6) listDefault with the fixed child environment equals the unrestricted `colima list --json`: cpus=\(instance.cpus) memoryBytes=\(instance.memoryBytes) diskBytes=\(instance.diskBytes)"
      )
    }

    @Test func sampleUsageWorksTwiceAndYieldsACpuPercentage() async throws {
      try LiveEnvironment.requireEnabled()
      let cli = LiveEnvironment.colimaCLI()
      guard case .present(let instance) = try await cli.listDefault() else {
        Issue.record("the default VM is not present")
        return
      }
      let first = try await cli.sampleUsage()
      try await Task.sleep(for: .milliseconds(1200))
      let second = try await cli.sampleUsage()

      for sample in [first, second] {
        #expect(sample.memoryTotalBytes > 0)
        #expect(Int64(sample.memoryTotalBytes) <= instance.memoryBytes)
        #expect(sample.memoryUsedBytes < sample.memoryTotalBytes)
      }
      #expect(first.cpuPercent(since: nil) == nil)
      let percent = try #require(second.cpuPercent(since: first))
      #expect((0.0...100.0).contains(percent))
      recordFinding(
        "(6) sampleUsage with the fixed child environment: two samples parsed, cpuPercent=\(percent) memoryUsed=\(second.memoryUsedBytes)/\(second.memoryTotalBytes)"
      )
    }
  }
}
