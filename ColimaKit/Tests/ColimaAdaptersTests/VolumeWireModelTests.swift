import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func decodeVolumes(_ json: String) throws -> VolumeListWire {
  try JSONDecoder().decode(VolumeListWire.self, from: Data(json.utf8))
}

private func decodeUsage(_ json: String) throws -> SystemDfVolumesWire {
  try JSONDecoder().decode(SystemDfVolumesWire.self, from: Data(json.utf8))
}

private let anonymousName = "9905b01da8a923b46fa99c9c367f85183e9d579a68fb396d4e0b8cb5a23806ac"

@Test func capturedVolumeListSeparatesAnonymousFromNamed() throws {
  let wire = try JSONDecoder().decode(
    VolumeListWire.self, from: try wireFixture("docker-volumes-list.json"))
  let volumes = wire.toDomain()

  #expect(
    volumes.map(\.name) == [
      "cgprobe-vol-unref", "cgprobe-vol-ref-running", "cgprobe-vol-ref-exited",
      "cgprobe-vol-ref-created",
      anonymousName,
    ])
  #expect(volumes.map(\.isAnonymous) == [false, false, false, false, true])
  #expect(volumes.allSatisfy { $0.driver == "local" })
  #expect(volumes.allSatisfy { $0.createdAt == Date(timeIntervalSince1970: 1_795_284_863) })
}

@Test func capturedDanglingVolumeListKeepsBothKinds() throws {
  let wire = try JSONDecoder().decode(
    VolumeListWire.self, from: try wireFixture("docker-volumes-list-dangling.json"))

  #expect(wire.toDomain().map(\.isAnonymous) == [true, false])
}

@Test func volumeListWithNullOrMissingVolumesIsEmpty() throws {
  #expect(try decodeVolumes(#"{"Volumes":null,"Warnings":null}"#).toDomain().isEmpty)
  #expect(try decodeVolumes(#"{}"#).toDomain().isEmpty)
}

@Test func volumeWithoutCreatedAtOrLabelsStillConverts() throws {
  let volumes = try decodeVolumes(#"{"Volumes":[{"Name":"v","Driver":"local"}]}"#).toDomain()

  #expect(volumes == [VolumeSummary(name: "v", driver: "local", createdAt: nil, labels: nil)])
}

@Test func volumeWithOtherLabelsIsNotAnonymous() throws {
  let volumes = try decodeVolumes(
    #"{"Volumes":[{"Name":"v","Driver":"local","Labels":{"com.docker.compose.project":"p"}}]}"#
  ).toDomain()

  #expect(volumes[0].isAnonymous == false)
}

@Test func capturedVerboseUsageMapsEveryVolumeNameToItsSize() throws {
  let wire = try JSONDecoder().decode(
    SystemDfVolumesWire.self, from: try wireFixture("docker-system-df-volume-verbose.json"))
  let sizes = wire.toDomain()

  #expect(sizes.count == 5)
  #expect(sizes["cgprobe-vol-ref-running"] == .bytes(0))
  #expect(sizes[anonymousName] == .bytes(0))
}

@Test func usageDecodesFromTheResponseThatAlsoCarriesTheLegacyVolumesKey() throws {
  let wire = try JSONDecoder().decode(
    SystemDfVolumesWire.self, from: try wireFixture("docker-system-df-volume.json"))

  #expect(wire.toDomain().count == 5)
}

@Test func negativeSizeBecomesUnknownAndPositiveSizeIsKept() throws {
  let wire = try decodeUsage(
    """
    {"VolumeUsage":{"Items":[
      {"Name":"a","UsageData":{"RefCount":0,"Size":-1}},
      {"Name":"b","UsageData":{"RefCount":1,"Size":4096}}]}}
    """)

  #expect(wire.toDomain() == ["a": .unknown, "b": .bytes(4096)])
}

@Test func missingOrNullUsageDataBecomesUnknown() throws {
  let wire = try decodeUsage(
    """
    {"VolumeUsage":{"Items":[
      {"Name":"a"},
      {"Name":"b","UsageData":null},
      {"Name":"c","UsageData":{"RefCount":0}}]}}
    """)

  #expect(wire.toDomain() == ["a": .unknown, "b": .unknown, "c": .unknown])
}

@Test func usageWithoutItemsIsEmpty() throws {
  #expect(
    try decodeUsage(#"{"VolumeUsage":{"ActiveCount":0,"Items":null,"TotalCount":0}}"#).toDomain()
      .isEmpty)
  #expect(try decodeUsage(#"{"VolumeUsage":null}"#).toDomain().isEmpty)
  #expect(try decodeUsage(#"{}"#).toDomain().isEmpty)
}
