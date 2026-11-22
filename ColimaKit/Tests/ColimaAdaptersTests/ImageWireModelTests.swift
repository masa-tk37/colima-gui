import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

@Test func capturedImageListConvertsToSummaryWithAllTags() throws {
  let wires = try JSONDecoder().decode(
    [ImageListItemWire].self, from: try wireFixture("docker-images-list.json"))
  let images = wires.map { $0.toDomain() }

  #expect(
    images == [
      ImageSummary(
        id: "sha256:a731f68fd7e3a3d084e5936b8213042fe4efc67d4ee89d6415f04d0e88036948",
        repoTags: ["amazon/aws-cli:latest", "cgprobe-img:a", "cgprobe-img:b"],
        size: 691_953_477,
        created: Date(timeIntervalSince1970: 1_795_205_079))
    ])
  #expect(images[0].rows.count == 3)
}

@Test func imageWithNullTagsYieldsSingleNoneRow() throws {
  let wires = try JSONDecoder().decode(
    [ImageListItemWire].self,
    from: Data(#"[{"Id":"sha256:abc","Created":1700000000,"Size":12,"RepoTags":null}]"#.utf8))
  let image = wires[0].toDomain()

  #expect(image.repoTags.isEmpty)
  #expect(image.rows.map(\.repository) == ["<none>"])
}

@Test func imageWithLiteralNoneTagKeepsItAsReported() throws {
  let wires = try JSONDecoder().decode(
    [ImageListItemWire].self,
    from: Data(
      #"[{"Id":"sha256:abc","Created":1700000000,"Size":12,"RepoTags":["<none>:<none>"]}]"#.utf8))

  #expect(wires[0].toDomain().rows.map(\.reference) == [.imageID("sha256:abc")])
}

@Test func imageMissingSizeDecodesAsZeroInsteadOfFailing() throws {
  let wires = try JSONDecoder().decode(
    [ImageListItemWire].self, from: Data(#"[{"Id":"sha256:abc","Created":1700000000}]"#.utf8))

  #expect(wires[0].toDomain().size == 0)
}
