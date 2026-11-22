import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func decodeList(_ json: String) throws -> [NetworkListItemWire] {
  try JSONDecoder().decode([NetworkListItemWire].self, from: Data(json.utf8))
}

private func decodeInspect(_ json: String) throws -> NetworkInspectWire {
  try JSONDecoder().decode(NetworkInspectWire.self, from: Data(json.utf8))
}

@Test func capturedNetworkListConvertsWithIPAM() throws {
  let wires = try JSONDecoder().decode(
    [NetworkListItemWire].self, from: try wireFixture("docker-networks-list.json"))
  let networks = wires.map { $0.toDomain() }

  #expect(
    networks.map(\.name) == ["none", "host", "bridge", "cgprobe-fx_default", "cgprobe-net-empty"])
  #expect(networks.map(\.driver) == ["null", "host", "bridge", "bridge", "bridge"])
  #expect(networks.allSatisfy { $0.scope == "local" })

  #expect(networks[0].ipam.isEmpty)
  #expect(networks[1].ipam.isEmpty)
  #expect(networks[2].ipam == [IPAMConfig(subnet: "172.17.0.0/16", gateway: "172.17.0.1")])
  #expect(
    networks[3].id
      == NetworkID(
        rawValue: "87ab70b460d3ebd229501cb30d3de61985e9e13785d26a96217c341237e8bc37"))
  #expect(networks[3].ipam == [IPAMConfig(subnet: "172.18.0.0/16", gateway: "172.18.0.1")])
}

@Test func builtInNetworksFromTheCaptureAreNotDeletable() throws {
  let wires = try JSONDecoder().decode(
    [NetworkListItemWire].self, from: try wireFixture("docker-networks-list.json"))

  #expect(wires.map { $0.toDomain().deletableID != nil } == [false, false, false, true, true])
}

@Test func networkWithMissingOrNullIPAMHasNoConfigs() throws {
  let networks = try decodeList(
    """
    [{"Name":"a","Id":"1","Driver":"bridge","Scope":"local"},
     {"Name":"b","Id":"2","Driver":"bridge","Scope":"local","IPAM":null},
     {"Name":"c","Id":"3","Driver":"bridge","Scope":"local","IPAM":{"Config":null}},
     {"Name":"d","Id":"4","Driver":"bridge","Scope":"local","IPAM":{"Config":[]}}]
    """
  ).map { $0.toDomain() }

  #expect(networks.map(\.ipam) == [[], [], [], []])
}

@Test func ipamEntryWithEmptyOrMissingFieldsYieldsNil() throws {
  let network = try decodeList(
    """
    [{"Name":"a","Id":"1","Driver":"bridge","Scope":"local",
      "IPAM":{"Config":[{"Subnet":"","Gateway":""},{"Subnet":"fd00::/64"}]}}]
    """)[0].toDomain()

  #expect(
    network.ipam == [
      IPAMConfig(subnet: nil, gateway: nil), IPAMConfig(subnet: "fd00::/64", gateway: nil),
    ])
}

@Test func capturedConnectedInspectExposesContainerWithCIDRAddress() throws {
  let wire = try JSONDecoder().decode(
    NetworkInspectWire.self, from: try wireFixture("docker-network-inspect-connected.json"))
  let detail = wire.toDomain()

  #expect(
    detail.id
      == NetworkID(rawValue: "87ab70b460d3ebd229501cb30d3de61985e9e13785d26a96217c341237e8bc37"))
  #expect(detail.name == "cgprobe-fx_default")
  #expect(
    detail.containers == [
      NetworkContainer(
        id: ContainerID(
          rawValue: "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74"),
        name: "cgprobe-fx-running",
        ipv4Address: "172.18.0.2/16",
        ipv6Address: nil)
    ])
}

@Test func capturedEmptyInspectHasNoContainers() throws {
  let wire = try JSONDecoder().decode(
    NetworkInspectWire.self, from: try wireFixture("docker-network-inspect-empty.json"))
  let detail = wire.toDomain()

  #expect(detail.name == "cgprobe-net-empty")
  #expect(detail.containers.isEmpty)
}

@Test func inspectWithNullOrMissingContainersIsEmpty() throws {
  #expect(
    try decodeInspect(#"{"Id":"1","Name":"a","Containers":null}"#).toDomain().containers.isEmpty)
  #expect(try decodeInspect(#"{"Id":"1","Name":"a"}"#).toDomain().containers.isEmpty)
}

@Test func inspectContainersAreOrderedByNameThenID() throws {
  let detail = try decodeInspect(
    """
    {"Id":"1","Name":"a","Containers":{
      "z9":{"Name":"web","IPv4Address":"10.0.0.3/24","IPv6Address":"fd00::3/64"},
      "b2":{"Name":"db","IPv4Address":"10.0.0.2/24","IPv6Address":""},
      "a1":{"Name":"db"}}}
    """
  ).toDomain()

  #expect(detail.containers.map(\.id.rawValue) == ["a1", "b2", "z9"])
  #expect(detail.containers.map(\.name) == ["db", "db", "web"])
  #expect(detail.containers.map(\.ipv4Address) == [nil, "10.0.0.2/24", "10.0.0.3/24"])
  #expect(detail.containers.map(\.ipv6Address) == [nil, nil, "fd00::3/64"])
}
