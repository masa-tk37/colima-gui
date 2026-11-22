import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private let idleLoop = "while :; do sleep 1; done"
private let busyLoop = "while :; do :; done"

extension Live {
  @Suite struct EngineContainers {
    @Test func startStopRestartRemoveAndTheirRefusals() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let container = try scope.createContainer("life", script: idleLoop)
        let id = try scope.owned(container.id)

        let created = try #require(try await client.listContainers().first { $0.id == id })
        #expect(created.name == container.name)
        #expect(created.image == LiveEnvironment.imageReference)
        #expect(created.state == .other(rawState: "created"))
        #expect(created.labels["cgprobe"] == "1")
        let detail = try await client.inspectContainer(id: id)
        #expect(detail.isRunning == false && detail.hasTTY == false)

        try await client.perform(.start, on: id)
        #expect(try await client.inspectContainer(id: id).isRunning)
        #expect(try await client.listContainers().first { $0.id == id }?.state == .running)
        try await client.perform(.start, on: id)

        let refusal = await failure { () async throws(DockerError) in
          try await client.removeContainer(id: id)
        }
        if case .api(let status, let message) = refusal {
          #expect((400..<500).contains(status))
          #expect(!message.isEmpty && !message.hasPrefix("HTTP "))
          recordFinding(
            "removing a running container without force: status=\(status) message=\"\(message)\"")
        } else {
          Issue.record("expected the engine to refuse, got \(String(describing: refusal))")
        }
        #expect(try await client.inspectContainer(id: id).isRunning)

        try await client.perform(.stop, on: id)
        #expect(try await client.inspectContainer(id: id).isRunning == false)
        try await client.perform(.stop, on: id)
        try await client.perform(.restart, on: id)
        #expect(try await client.inspectContainer(id: id).isRunning)

        try await client.perform(.stop, on: id)
        try await client.removeContainer(id: id)
        #expect(try await !client.listContainers().contains { $0.id == id })
        let gone = await failure { () async throws(DockerError) in
          _ = try await client.inspectContainer(id: id)
        }
        guard case .api(404, _) = gone else {
          Issue.record("expected 404 for a removed container, got \(String(describing: gone))")
          return
        }
      }
    }

    @Test func statsOfARunningThenStoppedContainer() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let container = try scope.createContainer(
          "stats", script: busyLoop, extraArguments: ["--cpus", "0.5"])
        let id = try scope.owned(container.id)
        try await client.perform(.start, on: id)

        let first = try await client.containerStats(id: id)
        let second = try await client.containerStats(id: id)
        let percent = try #require(
          second.cpuPercent, "a second sample must have a previous read to diff against")
        #expect(percent > 0 && percent < 100 * Double(second.onlineCPUs ?? 1))
        let memory = try #require(second.memoryBytes)
        #expect(memory > 0)
        recordFinding(
          "(5) stats?stream=false of a freshly started busy container: first sample previousCPUTotalUsage=\(first.previousCPUTotalUsage) previousSystemCPUUsage=\(String(describing: first.previousSystemCPUUsage)) cpuPercent=\(String(describing: first.cpuPercent)) memoryBytes=\(String(describing: first.memoryBytes)); second sample cpuPercent=\(percent) (container limited to 0.5 CPU) onlineCPUs=\(String(describing: second.onlineCPUs))"
        )

        try await client.perform(.stop, on: id)
        let stopped = try await client.containerStats(id: id)
        #expect(stopped.cpuPercent == nil)
        recordFinding(
          "(5) stats of the stopped container: cpuPercent=\(String(describing: stopped.cpuPercent)) memoryBytes=\(String(describing: stopped.memoryBytes))"
        )
      }
    }
  }
}
