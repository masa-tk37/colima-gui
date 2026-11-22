import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

extension Live {
  @Suite struct EngineVolumes {
    /// The raw `Size` of one volume in `/system/df`, which the adapter folds into `VolumeSize`.
    private func rawSize(of name: String) throws -> Int64? {
      let data = try rawEngineGET("/system/df?type=volume&verbose=true")
      let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      let items = (root["VolumeUsage"] as? [String: Any])?["Items"] as? [[String: Any]] ?? []
      let item = items.first { $0["Name"] as? String == name }
      return ((item?["UsageData"] as? [String: Any])?["Size"] as? NSNumber)?.int64Value
    }

    @Test func anonymousAndNamedVolumesInUseRefusalAndRemoval() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let named = try scope.createVolume("vol")
        let anonymous = try scope.createAnonymousVolume()
        let container = try scope.createContainer(
          "holder", script: "true", extraArguments: ["-v", "\(named):/data"])

        let volumes = try await client.listVolumes(danglingOnly: false)
        let namedRow = try #require(volumes.first { $0.name == named })
        let anonymousRow = try #require(volumes.first { $0.name == anonymous })
        #expect(namedRow.isAnonymous == false)
        #expect(anonymousRow.isAnonymous == true)
        #expect(namedRow.driver == "local")
        #expect(namedRow.createdAt != nil)

        let dangling = Set(try await client.listVolumes(danglingOnly: true).map(\.name))
        #expect(dangling.contains(anonymous))
        #expect(
          !dangling.contains(named),
          "a volume referenced by a created container must not be dangling")

        let sizes = try await client.volumeSizes()
        #expect(sizes[named] != nil && sizes[anonymous] != nil)
        let rawNamed = try rawSize(of: named)
        let rawAnonymous = try rawSize(of: anonymous)
        #expect(rawNamed != nil && rawAnonymous != nil)
        recordFinding(
          "(4) /system/df raw Size of an empty named volume=\(String(describing: rawNamed)), of an empty anonymous volume=\(String(describing: rawAnonymous)); adapter VolumeSize named=\(String(describing: sizes[named])) anonymous=\(String(describing: sizes[anonymous])); anonymous label on the anonymous volume=\(anonymousRow.isAnonymous), on the named volume=\(namedRow.isAnonymous)"
        )

        let ownedNamed = try scope.owned(named)
        let refusal = await failure { () async throws(DockerError) in
          try await client.removeVolume(name: ownedNamed)
        }
        if case .api(let status, let message) = refusal {
          #expect((400..<500).contains(status))
          #expect(!message.isEmpty && !message.hasPrefix("HTTP "))
          recordFinding(
            "removing a named volume referenced by a (created) container: status=\(status) message=\"\(message)\""
          )
        } else {
          Issue.record("expected the engine to refuse, got \(String(describing: refusal))")
        }
        #expect(try await client.listVolumes(danglingOnly: false).contains { $0.name == named })

        try scope.removeContainerWithCLI(container.id)
        try await client.removeVolume(name: try scope.owned(named))
        try await client.removeVolume(name: try scope.owned(anonymous))
        let remaining = Set(try await client.listVolumes(danglingOnly: false).map(\.name))
        #expect(!remaining.contains(named) && !remaining.contains(anonymous))
      }
    }

    @Test func volumeSizeReflectsWrittenBytes() async throws {
      try await withLiveScope { scope in
        let client = scope.client
        let volume = try scope.createVolume("data")
        let writer = try scope.createContainer(
          "writer", script: "head -c 1048576 /dev/zero > /data/blob",
          extraArguments: ["-v", "\(volume):/data"])
        try await client.perform(.start, on: try scope.owned(writer.id))
        let finished = await waitUntil {
          (try? await client.inspectContainer(id: writer.id).isRunning) == false
        }
        #expect(finished)

        let size = try #require(try await client.volumeSizes()[volume])
        let bytes = try #require(size.bytes)
        #expect(bytes >= 1_048_576)
        let raw = try rawSize(of: volume)
        #expect(raw == bytes)
        #expect(try await !client.listVolumes(danglingOnly: true).contains { $0.name == volume })
        recordFinding(
          "(4) /system/df Size of a named volume holding a 1 MiB file: raw=\(String(describing: raw)) adapter=\(size)"
        )
      }
    }
  }
}
