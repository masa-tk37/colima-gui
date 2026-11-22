import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private let shortTimeouts = DockerHTTPTransport.Timeouts(
  read: .seconds(5),
  mutate: .seconds(5),
  logHead: .seconds(5)
)

/// The server answers and closes the moment it has read the request, which can beat the client's final write
/// of a request body and surface as a spurious `.connectionLost`. A short delay lets the client finish first.
private let replyDelay = Duration.milliseconds(30)

private func jsonReply(_ body: Data) -> ScriptedBehavior {
  .reply(
    ScriptedReply(
      status: 200, headers: ["Content-Type": "application/json"], body: Array(body),
      delay: replyDelay))
}

private func jsonReply(_ text: String) -> ScriptedBehavior {
  jsonReply(Data(text.utf8))
}

private func emptyReply(_ status: Int) -> ScriptedBehavior {
  .reply(ScriptedReply(status: status, delay: replyDelay))
}

private func errorReply(_ status: Int, _ message: String) -> ScriptedBehavior {
  .reply(
    ScriptedReply(
      status: status,
      headers: ["Content-Type": "application/json"],
      body: Array(#"{"message":"\#(message)"}"#.utf8),
      delay: replyDelay
    ))
}

private func withClient<T: Sendable>(
  _ server: TestUnixHTTPServer,
  _ body: (DockerEngineClient) async throws -> T
) async throws -> T {
  let client = DockerEngineClient(socketPath: server.socketPath, timeouts: shortTimeouts)
  do {
    let value = try await body(client)
    await client.shutdown()
    return value
  } catch {
    await client.shutdown()
    throw error
  }
}

private func failure<T>(_ operation: () async throws -> T) async -> DockerError? {
  do {
    _ = try await operation()
    return nil
  } catch {
    if let error = error as? DockerError { return error }
    Issue.record("the client threw a non-DockerError: \(error)")
    return .unexpectedResponse(detail: String(describing: error))
  }
}

private func validatedCreate(name: String, subnet: String = "") throws -> ValidatedNetworkCreate {
  switch NetworkCreateForm(name: name, subnet: subnet).validate(existingNames: [String]()) {
  case .success(let value): return value
  case .failure(let failure):
    throw TestFailure("form rejected: \(failure.fields.map(\.message))")
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func deletable(id: String, name: String = "user-net") throws -> DeletableNetworkID {
  let summary = NetworkSummary(
    id: NetworkID(rawValue: id), name: name, driver: "bridge", scope: "local", ipam: [])
  return try #require(summary.deletableID)
}

private func jsonObject(_ bytes: [UInt8]) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
}

@Suite struct DockerEngineClientNetworkTests {
  // MARK: List and inspect

  @Test func listsAllNetworksWithoutAFilter() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "GET", path: "/v1.54/networks",
      jsonReply(try wireFixture("docker-networks-list.json")))

    let networks = try await withClient(server) { try await $0.listNetworks(danglingOnly: false) }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/networks")
    #expect(request.query == nil)
    #expect(
      networks.map(\.name) == ["none", "host", "bridge", "cgprobe-fx_default", "cgprobe-net-empty"])
    #expect(networks[2].ipam == [IPAMConfig(subnet: "172.17.0.0/16", gateway: "172.17.0.1")])
  }

  @Test func listsDanglingNetworksWithAJSONFilterQuery() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(method: "GET", path: "/v1.54/networks", jsonReply("[]"))

    let networks = try await withClient(server) { try await $0.listNetworks(danglingOnly: true) }

    let request = try #require(server.requests.first)
    #expect(request.path == "/v1.54/networks")
    #expect(request.queryItems == ["filters": #"{"dangling":["true"]}"#])
    #expect(request.query?.contains("%7B%22dangling%22%3A%5B%22true%22%5D%7D") == true)
    #expect(networks.isEmpty)
  }

  @Test func inspectsANetworkWithItsContainers() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(try wireFixture("docker-network-inspect-connected.json")))

    let detail = try await withClient(server) { client in
      try await client.inspectNetwork(id: NetworkID(rawValue: "abc123"))
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1.54/networks/abc123")
    #expect(request.query == nil)
    #expect(detail.containers.count == 1)
    #expect(detail.containers.first?.ipv4Address?.contains("/") == true)
  }

  @Test func inspectingAMissingNetworkSurfacesTheNotFoundMessage() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(errorReply(404, "network gone not found"))

    let error = try await withClient(server) { client in
      await failure { try await client.inspectNetwork(id: NetworkID(rawValue: "gone")) }
    }

    #expect(error == .api(status: 404, message: "network gone not found"))
  }

  // MARK: Create

  @Test func createsABridgeNetworkWithoutIPAMWhenNoSubnetIsGiven() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(
      method: "POST", path: "/v1.54/networks/create",
      .reply(
        ScriptedReply(
          status: 201, headers: ["Content-Type": "application/json"],
          body: Array(#"{"Id":"net-1","Warning":""}"#.utf8), delay: replyDelay)))

    let id = try await withClient(server) { client in
      try await client.createNetwork(try validatedCreate(name: "app-net"))
    }

    #expect(id == NetworkID(rawValue: "net-1"))
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1.54/networks/create")
    #expect(request.query == nil)
    #expect(request.headers["content-type"] == "application/json")
    let body = try jsonObject(request.body)
    #expect(body["Name"] as? String == "app-net")
    #expect(body["Driver"] as? String == "bridge")
    #expect(body["IPAM"] == nil)
    #expect(body["EnableIPv6"] == nil)
  }

  @Test func createsAnIPv4SubnetNetworkWithoutEnablingIPv6() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"{"Id":"net-2"}"#))

    let id = try await withClient(server) { client in
      try await client.createNetwork(try validatedCreate(name: "v4-net", subnet: "172.28.0.0/16"))
    }

    #expect(id.rawValue == "net-2")
    let body = try jsonObject(try #require(server.requests.first).body)
    #expect(body["Name"] as? String == "v4-net")
    #expect(body["Driver"] as? String == "bridge")
    let ipam = try #require(body["IPAM"] as? [String: Any])
    let config = try #require(ipam["Config"] as? [[String: Any]])
    #expect(config.count == 1)
    #expect(config.first?["Subnet"] as? String == "172.28.0.0/16")
    #expect(config.first?.count == 1)
    #expect(body["EnableIPv6"] == nil)
  }

  @Test func createsAnIPv6SubnetNetworkWithIPv6Enabled() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"{"Id":"net-3"}"#))

    _ = try await withClient(server) { client in
      try await client.createNetwork(try validatedCreate(name: "v6-net", subnet: "fd00:1::/64"))
    }

    let body = try jsonObject(try #require(server.requests.first).body)
    #expect(body["Name"] as? String == "v6-net")
    #expect(body["Driver"] as? String == "bridge")
    #expect(body["EnableIPv6"] as? Bool == true)
    let ipam = try #require(body["IPAM"] as? [String: Any])
    let config = try #require(ipam["Config"] as? [[String: Any]])
    #expect(config.first?["Subnet"] as? String == "fd00:1::/64")
  }

  @Test func aCreateResponseWithoutAnIDIsAnUnexpectedResponse() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(jsonReply(#"{"Warning":""}"#))

    let error = try await withClient(server) { client in
      await failure { try await client.createNetwork(try validatedCreate(name: "x")) }
    }

    guard case .unexpectedResponse = error else {
      Issue.record("expected unexpectedResponse, got \(String(describing: error))")
      return
    }
  }

  @Test func createFailuresSurfaceTheEngineMessageVerbatim() async throws {
    let overlap = "invalid pool request: Pool overlaps with other one on this address space"
    let predefined = "operation is not permitted on predefined bridge network"
    for (status, message) in [(403, predefined), (400, overlap), (404, "plugin x not found")] {
      let server = try TestUnixHTTPServer.start()
      defer { server.stop() }
      server.script(errorReply(status, message))

      let error = try await withClient(server) { client in
        await failure { try await client.createNetwork(try validatedCreate(name: "n")) }
      }

      #expect(error == .api(status: status, message: message))
    }
  }

  // MARK: Delete

  @Test func deletesByTheDeletableIDWithoutABodyOrQuery() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(emptyReply(204))

    try await withClient(server) { client in
      try await client.removeNetwork(try deletable(id: "net-abc"))
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.path == "/v1.54/networks/net-abc")
    #expect(request.query == nil)
    #expect(request.body.isEmpty)
  }

  @Test func aDeletableIDIsOnePercentEncodedPathSegment() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(emptyReply(204))

    try await withClient(server) { client in
      try await client.removeNetwork(try deletable(id: "a/b?c"))
    }

    #expect(try #require(server.requests.first).path == "/v1.54/networks/a%2Fb%3Fc")
  }

  @Test func deleteFailuresSurfaceTheEngineMessageVerbatim() async throws {
    let cases = [
      (403, "cgprobe-net is a pre-defined network and cannot be removed"),
      (409, "error while removing network: network cgprobe-net id abc has active endpoints"),
      (404, "network abc not found"),
    ]
    for (status, message) in cases {
      let server = try TestUnixHTTPServer.start()
      defer { server.stop() }
      server.script(errorReply(status, message))

      let error = try await withClient(server) { client in
        await failure { try await client.removeNetwork(try deletable(id: "abc")) }
      }

      #expect(error == .api(status: status, message: message))
    }
  }

  // MARK: Connect and disconnect

  @Test func connectsAContainerWithJustItsID() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(emptyReply(200))

    try await withClient(server) { client in
      try await client.connect(
        container: ContainerID(rawValue: "c0ffee"), to: NetworkID(rawValue: "net-1"))
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1.54/networks/net-1/connect")
    #expect(request.query == nil)
    #expect(request.headers["content-type"] == "application/json")
    let body = try jsonObject(request.body)
    #expect(body.count == 1)
    #expect(body["Container"] as? String == "c0ffee")
  }

  @Test func disconnectsAContainerWithoutForce() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(emptyReply(200))

    try await withClient(server) { client in
      try await client.disconnect(
        container: ContainerID(rawValue: "c0ffee"), from: NetworkID(rawValue: "net-1"))
    }

    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1.54/networks/net-1/disconnect")
    #expect(request.query == nil)
    let body = try jsonObject(request.body)
    #expect(body.count == 2)
    #expect(body["Container"] as? String == "c0ffee")
    #expect(body["Force"] as? Bool == false)
  }

  @Test func networkIDsInConnectPathsAreOneEncodedSegment() async throws {
    let server = try TestUnixHTTPServer.start()
    defer { server.stop() }
    server.script(emptyReply(200))

    try await withClient(server) { client in
      try await client.connect(
        container: ContainerID(rawValue: "c"), to: NetworkID(rawValue: "a/b"))
    }

    #expect(try #require(server.requests.first).path == "/v1.54/networks/a%2Fb/connect")
  }

  @Test func connectAndDisconnectFailuresSurfaceTheEngineMessageVerbatim() async throws {
    let cases = [
      (403, "container cannot be connected to network endpoints: host"),
      (404, "No such container: c0ffee"),
    ]
    for (status, message) in cases {
      let server = try TestUnixHTTPServer.start()
      defer { server.stop() }
      server.script(errorReply(status, message), errorReply(status, message))

      let (connectError, disconnectError) = try await withClient(server) { client in
        let connect = await failure {
          try await client.connect(
            container: ContainerID(rawValue: "c0ffee"), to: NetworkID(rawValue: "n"))
        }
        let disconnect = await failure {
          try await client.disconnect(
            container: ContainerID(rawValue: "c0ffee"), from: NetworkID(rawValue: "n"))
        }
        return (connect, disconnect)
      }

      #expect(connectError == .api(status: status, message: message))
      #expect(disconnectError == .api(status: status, message: message))
    }
  }
}
