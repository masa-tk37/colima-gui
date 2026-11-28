import Foundation
import Synchronization
import Testing

@testable import ColimaAdapters

private func matches(_ line: String) throws -> Bool {
  let regex = try NSRegularExpression(pattern: AgentRegistration.limactlMutatingPattern)
  return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

@Suite("App-side check for running agent commands")
struct AgentRegistrationCommandTests {
  @Test(arguments: [
    "/opt/homebrew/bin/limactl start --tty=false cg-dev",
    "limactl stop --tty=false cg-dev",
    "limactl delete --tty=false --force cg-dev",
    "limactl edit --tty=false cg-dev --cpus=2",
    "/opt/homebrew/bin/limactl create --tty=false --name=cg-dev template:debian",
    "limactl start",
    "limactl start colima",
  ])
  func aMutatingLimactlCommandOnAnyInstanceMatches(line: String) throws {
    #expect(try matches(line))
  }

  @Test(arguments: [
    "limactl hostagent --pidfile /Users/u/.lima/cg-dev/ha.pid cg-dev",
    "limactl shell cg-dev",
    "limactl list --json",
    "limactl startx",
    "limactl",
    "/Users/u/.lima/cg-dev/limactl-helper start cg-dev",
    "colima start",
    "tail -f /Users/u/.lima/cg-dev/ha.stderr.log",
  ])
  func anythingElseDoesNotMatch(line: String) throws {
    #expect(try !matches(line))
  }

  @Test(arguments: [(false, false, false), (true, false, true), (false, true, true), (true, true, true)])
  func theAgentIsBusyWhenEitherKindOfCommandIsRunning(colima: Bool, limactl: Bool, expected: Bool)
    async
  {
    let result = await AgentRegistration.agentCommandIsRunning(
      colima: { colima }, limactl: { limactl })

    #expect(result == expected)
  }

  @Test func theRealPgrepSeesAMutatingLimactlOnAnyInstance() async throws {
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.install("limactl", script: "#!/bin/sh\nsleep 30 &\ntrap 'kill $!; exit 0' TERM\nwait\n")
    let external = Process()
    external.executableURL = URL(fileURLWithPath: scripts.path("limactl"))
    external.arguments = ["start", "--tty=false", "cg-\(UUID().uuidString.prefix(8).lowercased())"]
    try external.run()
    defer { external.terminate() }

    #expect(await AgentRegistration.limactlCommandIsRunning())
    #expect(await AgentRegistration.agentCommandIsRunning())
  }
}

@Suite("Agent replacement deferral")
struct AgentReplacementDeferralTests {
  private func defers(
    _ readiness: AgentClient.UpdateReadiness, colima: Bool = false, limactl: Bool = false
  ) async -> Bool {
    await AgentRegistration.shouldDeferReplacement(readiness: readiness) {
      await AgentRegistration.agentCommandIsRunning(colima: { colima }, limactl: { limactl })
    }
  }

  @Test func aBusyAgentDefersWithoutLookingOutside() async {
    let asked = Mutex(false)
    let result = await AgentRegistration.shouldDeferReplacement(readiness: .busy) {
      asked.withLock { $0 = true }
      return false
    }

    #expect(result)
    #expect(!asked.withLock { $0 })
  }

  @Test func anIdleAgentProceedsWithoutLookingOutside() async {
    let asked = Mutex(false)
    let result = await AgentRegistration.shouldDeferReplacement(readiness: .idle) {
      asked.withLock { $0 = true }
      return true
    }

    #expect(!result)
    #expect(!asked.withLock { $0 })
  }

  @Test func anUnreachableAgentDefersWhileAColimaCommandRuns() async {
    #expect(await defers(.unreachable, colima: true))
  }

  @Test func anUnreachableAgentDefersWhileALimactlCommandRuns() async {
    #expect(await defers(.unreachable, limactl: true))
  }

  @Test func anUnreachableAgentProceedsWhenNothingRuns() async {
    #expect(await !defers(.unreachable))
  }
}
