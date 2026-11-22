import ColimaCore
import Foundation

struct ImageListItemWire: Decodable {
  let id: String
  let repoTags: [String]?
  let size: Int64?
  let created: Date

  private enum CodingKeys: String, CodingKey {
    case id = "Id"
    case repoTags = "RepoTags"
    case size = "Size"
    case created = "Created"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    repoTags = try container.decodeIfPresent([String].self, forKey: .repoTags)
    size = try container.decodeIfPresent(Int64.self, forKey: .size)
    created = try container.decode(WireTimestamp.self, forKey: .created).date
  }

  func toDomain() -> ImageSummary {
    ImageSummary(id: id, repoTags: repoTags ?? [], size: size ?? 0, created: created)
  }
}
