import Testing

@testable import ColimaCore

private func summary(id: String = "id1", name: String) -> NetworkSummary {
  NetworkSummary(
    id: NetworkID(rawValue: id), name: name, driver: "bridge", scope: "local", ipam: [])
}

@Test func capturedListKeepsEveryNetworkAndAllowsEmptyIPAM() throws {
  let networks = try DockerFixture.networks("docker-networks-list")
  #expect(
    networks.map(\.name) == ["none", "host", "bridge", "cgprobe-fx_default", "cgprobe-net-empty"])
  let none = try #require(networks.first { $0.name == "none" })
  #expect(none.ipam.isEmpty)
  let bridge = try #require(networks.first { $0.name == "bridge" })
  #expect(bridge.ipam == [IPAMConfig(subnet: "172.17.0.0/16", gateway: "172.17.0.1")])
  #expect(bridge.driver == "bridge" && bridge.scope == "local")
}

@Test func summaryKeepsMultipleIPAMConfigsAndBlankFields() {
  let configs = [
    IPAMConfig(subnet: "172.30.0.0/16", gateway: "172.30.0.1"),
    IPAMConfig(subnet: "fd00::/64", gateway: nil),
  ]
  let value = NetworkSummary(
    id: NetworkID(rawValue: "n"), name: "multi", driver: "bridge", scope: "local", ipam: configs
  )
  #expect(value.ipam == configs)
  #expect(value.ipam[1].gateway == nil)
}

@Test func capturedConnectedInspectListsContainerNameAndAddresses() throws {
  let detail = try DockerFixture.networkDetail("docker-network-inspect-connected")
  #expect(detail.name == "cgprobe-fx_default")
  #expect(detail.containers.count == 1)
  let container = try #require(detail.containers.first)
  #expect(container.name == "cgprobe-fx-running")
  #expect(
    container.id.rawValue == "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74")
  #expect(container.ipv4Address == "172.18.0.2/16")
  #expect(container.ipv6Address == nil)
}

@Test func capturedEmptyInspectHasNoContainers() throws {
  let detail = try DockerFixture.networkDetail("docker-network-inspect-empty")
  #expect(detail.name == "cgprobe-net-empty")
  #expect(detail.containers.isEmpty)
}

@Test(arguments: ["bridge", "host", "none"])
func builtInNetworksHaveNoDeletableID(name: String) {
  #expect(summary(name: name).deletableID == nil)
}

@Test(arguments: ["bridge", "host", "none"])
func builtInIdentityAloneBlocksDeletion(identity: String) {
  #expect(summary(id: identity, name: "renamed").deletableID == nil)
}

@Test func capturedListYieldsDeletableIDsOnlyForCustomNetworks() throws {
  let networks = try DockerFixture.networks("docker-networks-list")
  let deletable = networks.filter { $0.deletableID != nil }.map(\.name)
  #expect(deletable == ["cgprobe-fx_default", "cgprobe-net-empty"])
}

@Test func deletableIDCarriesTheNetworkID() throws {
  let id = try #require(summary(id: "abc", name: "custom").deletableID)
  #expect(id.id == NetworkID(rawValue: "abc"))
}

@Test func builtInNameMatchIsExact() {
  #expect(summary(name: "Bridge").deletableID != nil)
  #expect(summary(name: "bridge2").deletableID != nil)
}
