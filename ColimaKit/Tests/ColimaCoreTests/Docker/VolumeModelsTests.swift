import Foundation
import Testing

@testable import ColimaCore

@Test func capturedFixtureSeparatesOneAnonymousFromFourNamedVolumes() throws {
  let volumes = try DockerFixture.volumes("docker-volumes-list")
  #expect(volumes.count == 5)
  let anonymous = volumes.filter(\.isAnonymous)
  #expect(
    anonymous.map(\.name) == ["9905b01da8a923b46fa99c9c367f85183e9d579a68fb396d4e0b8cb5a23806ac"])
  let named = volumes.filter { !$0.isAnonymous }
  #expect(
    named.map(\.name) == [
      "cgprobe-vol-unref", "cgprobe-vol-ref-running", "cgprobe-vol-ref-exited",
      "cgprobe-vol-ref-created",
    ])
  #expect(volumes.allSatisfy { $0.driver == "local" && $0.createdAt != nil })
}

@Test func missingOrEmptyLabelsMeanNamed() {
  #expect(
    VolumeSummary(name: "v", driver: "local", createdAt: nil, labels: nil).isAnonymous == false)
  #expect(
    VolumeSummary(name: "v", driver: "local", createdAt: nil, labels: [:]).isAnonymous == false)
  #expect(
    VolumeSummary(name: "v", driver: "local", createdAt: nil, labels: ["app": "x"]).isAnonymous
      == false)
}

@Test func anonymousLabelPresenceMarksAnonymousRegardlessOfValue() {
  let empty = VolumeSummary(
    name: "v", driver: "local", createdAt: nil, labels: ["com.docker.volume.anonymous": ""]
  )
  let valued = VolumeSummary(
    name: "v", driver: "local", createdAt: nil,
    labels: ["com.docker.volume.anonymous": "true", "a": "b"]
  )
  #expect(empty.isAnonymous)
  #expect(valued.isAnonymous)
}

@Test func volumeIdentityIsItsName() {
  #expect(VolumeSummary(name: "data", driver: "local", createdAt: nil, labels: nil).id == "data")
}

@Test func dockerSizeMinusOneIsUnknown() {
  #expect(VolumeSize(dockerSize: -1) == .unknown)
  #expect(VolumeSize(dockerSize: -1).bytes == nil)
}

@Test func nonNegativeDockerSizeIsKnownBytes() {
  #expect(VolumeSize(dockerSize: 0) == .bytes(0))
  #expect(VolumeSize(dockerSize: 4_096).bytes == 4_096)
}

@Test func capturedDiskUsageFixtureGivesKnownSizesPerVolume() throws {
  let sizes = try DockerFixture.volumeSizes("docker-system-df-volume-verbose")
  #expect(sizes.count == 5)
  #expect(sizes["cgprobe-vol-unref"] == .bytes(0))
  #expect(sizes.values.allSatisfy { $0 == .bytes(0) })
}

@Test func volumeSizeBytesFeedPruneReportWithUnknownAsNil() {
  let sizes: [VolumeSize] = [.bytes(1_000), .unknown, .bytes(24)]
  let report = PruneReport(deletedSizes: sizes.map(\.bytes), failures: [:])
  #expect(report.deletedCount == 3)
  #expect(report.estimatedReclaimedBytes == 1_024)
  #expect(report.unknownSizeCount == 1)
}
