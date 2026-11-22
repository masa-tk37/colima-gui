import Foundation
import Testing

@testable import ColimaCore

private let created = Date(timeIntervalSince1970: 1_795_205_079)

private func summary(id: String = "sha256:aaa", tags: [String], size: Int64 = 100) -> ImageSummary {
  ImageSummary(id: id, repoTags: tags, size: size, created: created)
}

@Test func imageWithThreeTagsBecomesThreeRowsFromTheCapturedFixture() throws {
  let images = try DockerFixture.images("docker-images-list")
  #expect(images.count == 1)
  let rows = try #require(images.first).rows
  #expect(rows.count == 3)
  #expect(rows.map(\.repository) == ["amazon/aws-cli", "cgprobe-img", "cgprobe-img"])
  #expect(rows.map(\.tag) == ["latest", "a", "b"])
  #expect(
    rows.map(\.reference.value) == ["amazon/aws-cli:latest", "cgprobe-img:a", "cgprobe-img:b"])
  #expect(Set(rows.map(\.id)).count == 3)
  #expect(rows.allSatisfy { $0.size == 691_953_477 && $0.created == created })
  #expect(rows.allSatisfy { $0.imageID == images[0].id })
}

@Test func untaggedImageYieldsOneNoneRowReferencedByImageID() {
  for tags in [[], ["<none>:<none>"]] {
    let rows = summary(tags: tags).rows
    #expect(rows.count == 1)
    #expect(rows[0].repository == "<none>")
    #expect(rows[0].tag == "<none>")
    #expect(rows[0].reference == .imageID("sha256:aaa"))
    #expect(rows[0].reference.value == "sha256:aaa")
  }
}

@Test func taggedRowReferencesRepoColonTag() {
  let row = summary(tags: ["nginx:1.27"]).rows[0]
  #expect(row.reference == .tag(repository: "nginx", tag: "1.27"))
  #expect(row.reference.value == "nginx:1.27")
}

@Test func registryPortColonIsNotTheTagSeparator() {
  let rows = summary(tags: ["localhost:5000/team/app:v2", "localhost:5000/team/app"]).rows
  #expect(rows[0].repository == "localhost:5000/team/app")
  #expect(rows[0].tag == "v2")
  #expect(rows[0].reference.value == "localhost:5000/team/app:v2")
  #expect(rows[1].repository == "localhost:5000/team/app")
  #expect(rows[1].tag == "<none>")
}

@Test func tagWithoutColonUsesImageIDForDeletion() {
  let row = summary(tags: ["busybox"]).rows[0]
  #expect(row.repository == "busybox")
  #expect(row.tag == "<none>")
  #expect(row.reference == .imageID("sha256:aaa"))
}

@Test func rowsOfDifferentImagesWithTheSameTagHaveDistinctIDs() {
  let a = summary(id: "sha256:aaa", tags: []).rows[0]
  let b = summary(id: "sha256:bbb", tags: []).rows[0]
  #expect(a.id != b.id)
}
