import ColimaCore
import Foundation
import Testing

@testable import ColimaProcess

private func key(_ displayName: String) -> MachineKey {
  MachineKey(unownedInstanceName: MachineName.instancePrefix + displayName)!
}

private func matches(_ line: String, instance: String) throws -> Bool {
  let regex = try NSRegularExpression(
    pattern: AgentMain.limactlPattern(instanceName: instance), options: [.caseInsensitive])
  return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

@Suite("External limactl detection")
struct AgentExternalCommandTests {
  @Test(arguments: [
    "/opt/homebrew/bin/limactl start --tty=false cg-dev",
    "limactl stop --tty=false cg-dev",
    "limactl delete --tty=false --force cg-dev",
    "limactl edit --tty=false cg-dev --cpus=2 --set=.mounts = []",
    "/opt/homebrew/bin/limactl create --tty=false --name=cg-dev --vm-type=vz --cpus=2 template:ubuntu-24.04",
    "limactl start cg-DEV",
    "limactl start cg-dev",
  ])
  func aMutatingCommandOnTheSameInstanceMatches(line: String) throws {
    #expect(try matches(line, instance: "cg-dev"))
  }

  @Test(arguments: [
    "limactl start --tty=false cg-webdev",
    "limactl start --tty=false cg-dev2",
    "limactl start --tty=false cg-dev-2",
    "limactl start --tty=false cg-dev.x",
    "limactl start --tty=false xcg-dev",
    "limactl create --tty=false --name=cg-webdev template:debian",
    "limactl hostagent --pidfile /Users/u/.lima/cg-dev/ha.pid --socket /Users/u/.lima/cg-dev/ha.sock cg-dev",
    "limactl shell cg-dev",
    "limactl list --json",
    "limactl start colima",
    "/Users/u/.lima/cg-dev/limactl-helper start cg-dev",
    "tail -f /Users/u/.lima/cg-dev/ha.stderr.log",
  ])
  func anythingElseDoesNotMatch(line: String) throws {
    #expect(try !matches(line, instance: "cg-dev"))
  }

  @Test func aDotInTheNameMatchesOnlyADot() throws {
    #expect(try matches("limactl start cg-a.b", instance: "cg-a.b"))
    #expect(try !matches("limactl start cg-axb", instance: "cg-a.b"))
  }

  @Test func theRealPgrepSeesAnExternalCommandOnTheSameMachineOnly() async throws {
    let id = UUID().uuidString.prefix(8).lowercased()
    let target = key("dev-\(id)")
    let other = key("webdev-\(id)")
    let scripts = try FakeBin()
    defer { scripts.remove() }
    try scripts.install("limactl", script: "#!/bin/sh\nsleep 30 &\ntrap 'kill $!; exit 0' TERM\nwait\n")

    #expect(await AgentMain.machineCommandIsRunning(target) == false)

    let external = Process()
    external.executableURL = URL(fileURLWithPath: scripts.path("limactl"))
    external.arguments = ["start", "--tty=false", "cg-DEV-\(id)"]
    try external.run()
    defer { external.terminate() }

    #expect(await AgentMain.machineCommandIsRunning(target))
    #expect(await AgentMain.foreignCommandIsRunning(for: .machine(target)))
    #expect(await AgentMain.machineCommandIsRunning(other) == false)

    let hostagent = Process()
    hostagent.executableURL = URL(fileURLWithPath: scripts.path("limactl"))
    hostagent.arguments = ["hostagent", "--socket", "/x/cg-\(id)/ha.sock", "cg-webdev-\(id)"]
    try hostagent.run()
    defer { hostagent.terminate() }
    #expect(await AgentMain.machineCommandIsRunning(other) == false)

    external.terminate()
    external.waitUntilExit()
    #expect(await AgentMain.machineCommandIsRunning(target) == false)
  }
}
