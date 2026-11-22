import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func decodeList(_ json: String) throws -> [ContainerListItemWire] {
  try JSONDecoder().decode([ContainerListItemWire].self, from: Data(json.utf8))
}

private func decodeInspect(_ json: String) throws -> ContainerInspectWire {
  try JSONDecoder().decode(ContainerInspectWire.self, from: Data(json.utf8))
}

@Test func capturedContainerListConvertsToSummaries() throws {
  let wires = try JSONDecoder().decode(
    [ContainerListItemWire].self, from: try wireFixture("docker-containers-list.json"))
  let summaries = wires.map { $0.toDomain() }

  #expect(
    summaries.map(\.name) == [
      "cgprobe-log-tty", "cgprobe-log-notty", "cgprobe-fx-created", "cgprobe-fx-exited",
      "cgprobe-fx-running",
    ])
  #expect(Set(summaries.map(\.imageID)) == ["sha256:a731f68fd7e3a3d084e5936b8213042fe4efc67d4ee89d6415f04d0e88036948"])
  #expect(
    summaries.map(\.state) == [
      .other(rawState: "exited"), .other(rawState: "exited"), .other(rawState: "created"),
      .other(rawState: "exited"), .running,
    ])

  let running = try #require(summaries.last)
  #expect(
    running.id
      == ContainerID(rawValue: "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74"))
  #expect(running.image == "amazon/aws-cli:latest")
  #expect(
    running.ports == [
      ContainerPort(ip: "127.0.0.1", privatePort: 8080, publicPort: 32768, protocolName: "tcp")
    ])
  #expect(running.labels["com.docker.compose.project"] == "cgprobe-fx")
  #expect(running.labels["com.docker.compose.service"] == "web")
  #expect(running.networkNames == ["cgprobe-fx_default"])

  let plain = summaries[0]
  #expect(plain.labels.isEmpty)
  #expect(plain.ports.isEmpty)
  #expect(plain.networkNames == ["bridge"])
}

@Test func containerListToleratesNullAndMissingOptionalFields() throws {
  let wires = try decodeList(
    #"[{"Id":"abc123def4567890","Names":null,"Image":"alpine","State":"running","Ports":null,"Labels":null}]"#
  )
  let summary = wires[0].toDomain()

  #expect(summary.name == "abc123def456")
  #expect(summary.ports.isEmpty)
  #expect(summary.labels.isEmpty)
  #expect(summary.networkNames.isEmpty)
}

@Test func containerNameStripsLeadingSlashAndPrefersOwnNameOverLinkAliases() throws {
  let plain = try decodeList(#"[{"Id":"a","Names":["/web"],"Image":"i","State":"running"}]"#)
  #expect(plain[0].toDomain().name == "web")

  let linked = try decodeList(
    #"[{"Id":"a","Names":["/app/db","/db"],"Image":"i","State":"running"}]"#)
  #expect(linked[0].toDomain().name == "db")

  let noSlash = try decodeList(#"[{"Id":"a","Names":["web"],"Image":"i","State":"running"}]"#)
  #expect(noSlash[0].toDomain().name == "web")
}

@Test func unpublishedAndUDPPortsKeepOptionalFieldsNil() throws {
  let wires = try decodeList(
    #"""
    [{"Id":"a","Names":["/n"],"Image":"i","State":"running","Ports":[
      {"PrivatePort":53,"PublicPort":5353,"Type":"udp","IP":"0.0.0.0"},
      {"PrivatePort":9000,"Type":"tcp"}
    ]}]
    """#)

  #expect(
    wires[0].toDomain().ports == [
      ContainerPort(ip: "0.0.0.0", privatePort: 53, publicPort: 5353, protocolName: "udp"),
      ContainerPort(ip: nil, privatePort: 9000, publicPort: nil, protocolName: "tcp"),
    ])
}

@Test func capturedInspectFixturesConvertToDetails() throws {
  let running = try JSONDecoder().decode(
    ContainerInspectWire.self, from: try wireFixture("docker-container-inspect-running.json")
  ).toDomain()
  #expect(
    running
      == ContainerDetail(
        id: ContainerID(
          rawValue: "470c6b6fea506f60cff9b49bac40df5976f883b2f20f869a996d27fe28a69c74"),
        hasTTY: false, isRunning: true, networkNames: ["cgprobe-fx_default"]))

  let exited = try JSONDecoder().decode(
    ContainerInspectWire.self, from: try wireFixture("docker-container-inspect-exited.json")
  ).toDomain()
  #expect(!exited.isRunning)
  #expect(!exited.hasTTY)

  let created = try JSONDecoder().decode(
    ContainerInspectWire.self, from: try wireFixture("docker-container-inspect-created.json"))
  #expect(!created.toDomain().isRunning)
}

@Test func inspectReadsTTYFlagAndSortsNetworkNames() throws {
  let detail = try decodeInspect(
    #"""
    {"Id":"abc","State":{"Running":true},"Config":{"Tty":true},
     "NetworkSettings":{"Networks":{"zeta":{},"alpha":{}}}}
    """#
  ).toDomain()

  #expect(detail.hasTTY)
  #expect(detail.networkNames == ["alpha", "zeta"])
}

@Test func inspectWithoutNetworksYieldsEmptyNames() throws {
  let detail = try decodeInspect(
    #"{"Id":"abc","State":{"Running":false},"Config":{"Tty":false},"NetworkSettings":{"Networks":null}}"#
  )
  .toDomain()
  #expect(detail.networkNames.isEmpty)
}

@Test func inspectMissingTTYFlagFailsToDecodeInsteadOfGuessing() {
  #expect(throws: DecodingError.self) {
    _ = try decodeInspect(#"{"Id":"abc","State":{"Running":true},"Config":{}}"#)
  }
}

private struct TimestampBox: Decodable { let at: WireTimestamp }

@Test func wireTimestampAcceptsEpochNumbersAndRFC3339Strings() throws {
  func dateFrom(_ literal: String) throws -> Date {
    try JSONDecoder().decode(TimestampBox.self, from: Data(#"{"at":\#(literal)}"#.utf8)).at.date
  }

  #expect(try dateFrom("1795284864") == Date(timeIntervalSince1970: 1_795_284_864))
  #expect(try dateFrom("1795284864.5") == Date(timeIntervalSince1970: 1_795_284_864.5))
  #expect(try dateFrom(#""2026-11-21T18:14:24Z""#) == Date(timeIntervalSince1970: 1_795_284_864))
  #expect(
    try dateFrom(#""2026-11-21T18:14:24.5Z""#) == Date(timeIntervalSince1970: 1_795_284_864.5))
  #expect(
    try dateFrom(#""2026-11-22T03:14:24+09:00""#) == Date(timeIntervalSince1970: 1_795_284_864))
  #expect(
    abs(
      try dateFrom(#""2026-11-21T18:14:23.672321303Z""#).timeIntervalSince1970
        - 1_795_284_863.672321) < 0.001)
  #expect(
    abs(
      try dateFrom(#""2026-11-22T03:14:23.612061732+09:00""#).timeIntervalSince1970
        - 1_795_284_863.612) < 0.001)
  // The engine's "never happened" sentinel parses; Foundation's pre-1582 calendar puts it near, not exactly at, Go's zero time.
  #expect(try dateFrom(#""0001-01-01T00:00:00Z""#) < Date(timeIntervalSince1970: -62_000_000_000))
}

@Test func wireTimestampRejectsUnparseableStrings() {
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(TimestampBox.self, from: Data(#"{"at":"yesterday"}"#.utf8))
  }
}
