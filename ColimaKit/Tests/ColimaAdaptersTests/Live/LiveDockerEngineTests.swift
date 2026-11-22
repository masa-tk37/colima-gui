import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

func failure(of call: () async throws(DockerError) -> Void) async -> DockerError? {
  do throws(DockerError) {
    try await call()
    return nil
  } catch {
    return error
  }
}

extension Live {
  @Suite struct EngineReads {
    @Test func listsMatchTheDockerCLI() async throws {
      try await withLiveScope { scope in
        let client = scope.client

        let containers = try await client.listContainers()
        #expect(
          Set(containers.map(\.id.rawValue))
            == Set(try dockerLines(["ps", "-a", "-q", "--no-trunc"])))

        let images = try await client.listImages()
        #expect(Set(images.map(\.id)) == Set(try dockerLines(["image", "ls", "-q", "--no-trunc"])))

        let volumes = try await client.listVolumes(danglingOnly: false)
        let dangling = try await client.listVolumes(danglingOnly: true)
        let sizes = try await client.volumeSizes()
        let volumeNames = Set(volumes.map(\.name))
        #expect(volumeNames == Set(try dockerLines(["volume", "ls", "-q"])))
        #expect(Set(dangling.map(\.name)).isSubset(of: volumeNames))
        #expect(volumeNames.isSubset(of: Set(sizes.keys)))

        let networks = try await client.listNetworks(danglingOnly: false)
        #expect(
          Set(networks.map(\.id.rawValue))
            == Set(try dockerLines(["network", "ls", "-q", "--no-trunc"])))
        let builtIn = networks.filter { NetworkSummary.builtInNames.contains($0.name) }
        #expect(Set(builtIn.map(\.name)) == NetworkSummary.builtInNames)
        #expect(builtIn.allSatisfy { $0.deletableID == nil })
        let danglingNetworks = try await client.listNetworks(danglingOnly: true)
        #expect(danglingNetworks.allSatisfy { $0.deletableID != nil })
        recordFinding(
          "(1) `Host: docker` over the Unix socket: listContainers/listImages/listVolumes/volumeSizes/listNetworks all returned 2xx through DockerEngineClient (\(containers.count) containers, \(images.count) images, \(volumes.count) volumes, \(networks.count) networks)"
        )
      }
    }

    @Test func engineSpeaksTheApiVersionThePathsAreBuiltFor() async throws {
      try await withLiveScope { _ in
        let data = try rawEngineGET("/version")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let api = try #require(root["ApiVersion"] as? String)
        let minimum = try #require(root["MinAPIVersion"] as? String)
        func parts(_ version: String) -> [Int] {
          version.split(separator: ".").compactMap { Int($0) }
        }
        #expect(
          parts(api).lexicographicallyPrecedes(
            parts(DockerEngineClient.apiVersion.dropFirst().description)) == false,
          "engine API \(api) is older than the v1.54 the adapter requests")
        #expect(
          !parts(DockerEngineClient.apiVersion.dropFirst().description).lexicographicallyPrecedes(
            parts(minimum)))
        recordFinding(
          "engine ApiVersion=\(api) MinAPIVersion=\(minimum) Version=\(String(describing: root["Version"]))"
        )
      }
    }

    @Test func missingContainerIsAnApiErrorWithTheEnginesMessage() async throws {
      try await withLiveScope { scope in
        let error = await failure { () async throws(DockerError) in
          _ = try await scope.client.inspectContainer(
            id: ContainerID(rawValue: scope.name("does-not-exist")))
        }
        guard case .api(let status, let message) = error else {
          Issue.record("expected an api error, got \(String(describing: error))")
          return
        }
        #expect(status == 404)
        #expect(!message.isEmpty && !message.hasPrefix("HTTP "))
        recordFinding("inspect of an unknown container: status=\(status) message=\"\(message)\"")
      }
    }

    @Test func manyRequestsOverTheSameClientAllSucceed() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        var sequential = 0
        for _ in 0..<20 where (try? await client.listContainers()) != nil { sequential += 1 }
        #expect(sequential == 20)

        let concurrent = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
          for index in 0..<40 {
            group.addTask {
              if index.isMultiple(of: 2) { return (try? await client.listContainers()) != nil }
              return (try? await client.listNetworks(danglingOnly: false)) != nil
            }
          }
          return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(concurrent == 40)
        recordFinding(
          "(8) 20 sequential and 40 concurrent mixed requests over one DockerEngineClient all succeeded (reuse of a keep-alive connection itself was not observed, only that nothing failed)"
        )
      }
    }
  }

  @Suite struct EngineNetworks {
    private let ipv4Subnet = "172.29.77.0/24"

    private func validated(_ name: String, subnet: String) throws -> ValidatedNetworkCreate {
      switch NetworkCreateForm(name: name, subnet: subnet).validate(existingNames: [String]()) {
      case .success(let value): return value
      case .failure(let failure):
        throw LiveError.unexpectedOutput("form rejected \(failure.fields)")
      }
    }

    @Test func createConnectDisconnectAndRemove() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let networkName = scope.name("net")
        let id = try await client.createNetwork(
          try validated(try scope.owned(networkName), subnet: ipv4Subnet))

        let listed = try #require(
          try await client.listNetworks(danglingOnly: false).first { $0.id == id })
        #expect(listed.name == networkName)
        #expect(listed.driver == "bridge")
        #expect(listed.scope == "local")
        #expect(listed.ipam.first?.subnet == ipv4Subnet)
        #expect(listed.ipam.first?.gateway == "172.29.77.1")
        #expect(listed.deletableID != nil)
        #expect(try await client.listNetworks(danglingOnly: true).contains { $0.id == id })
        #expect(try await client.inspectNetwork(id: id).containers.isEmpty)

        let container = try scope.createContainer("c", script: "while :; do sleep 1; done")
        try await client.perform(.start, on: try scope.owned(container.id))
        try await client.connect(container: container.id, to: id)

        let attached = try await client.inspectNetwork(id: id)
        let member = try #require(attached.containers.first)
        #expect(attached.containers.count == 1)
        #expect(member.id == container.id)
        #expect(member.name == container.name)
        #expect(member.ipv4Address?.hasPrefix("172.29.77.") == true)
        #expect(member.ipv4Address?.hasSuffix("/24") == true)
        #expect(
          try await client.inspectContainer(id: container.id).networkNames.contains(networkName))
        #expect(try await !client.listNetworks(danglingOnly: true).contains { $0.id == id })

        let deletable = try #require(listed.deletableID)
        let refusal = await failure { () async throws(DockerError) in
          try await client.removeNetwork(deletable)
        }
        if case .api(let status, let message) = refusal {
          #expect((400..<500).contains(status))
          #expect(!message.isEmpty && !message.hasPrefix("HTTP "))
          recordFinding(
            "(2) removing a network with a connected running container: status=\(status) message=\"\(message)\""
          )
        } else {
          Issue.record("expected the engine to refuse, got \(String(describing: refusal))")
        }
        #expect(try await client.listNetworks(danglingOnly: false).contains { $0.id == id })

        try await client.disconnect(container: container.id, from: id)
        #expect(try await client.inspectNetwork(id: id).containers.isEmpty)
        #expect(
          try await client.inspectContainer(id: container.id).networkNames.contains(networkName)
            == false)

        try await client.removeNetwork(deletable)
        #expect(try await !client.listNetworks(danglingOnly: false).contains { $0.id == id })
        let again = await failure { () async throws(DockerError) in
          try await client.removeNetwork(deletable)
        }
        recordFinding("removing the same network twice: \(String(describing: again))")
        #expect(again != nil)
      }
    }

    @Test func ipv6OnlySubnetIsAcceptedOrRefusedWithTheEnginesMessage() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let networkName = scope.name("v6")
        // A ULA prefix; the form rejects anything that is not a valid IPv6 literal before the engine sees it.
        let subnet = "fd00:cb:1::/64"
        let request = try validated(try scope.owned(networkName), subnet: subnet)
        #expect(request.subnet?.family == .ipv6)
        var created: NetworkID?
        let rejection = await failure { () async throws(DockerError) in
          created = try await client.createNetwork(request)
        }
        if let id = created {
          let listed = try #require(
            try await client.listNetworks(danglingOnly: false).first { $0.id == id })
          #expect(listed.ipam.contains { $0.subnet == subnet })
          recordFinding(
            "(3) IPv6-only subnet \(subnet) with EnableIPv6: ACCEPTED, ipam=\(listed.ipam)")
          try await client.removeNetwork(try #require(listed.deletableID))
        } else if case .api(let status, let message) = rejection {
          #expect((400..<600).contains(status))
          #expect(!message.isEmpty)
          recordFinding(
            "(3) IPv6-only subnet \(subnet) with EnableIPv6: REJECTED status=\(status) message=\"\(message)\""
          )
        } else {
          Issue.record("expected an engine answer, got \(String(describing: rejection))")
        }
      }
    }
  }
}
