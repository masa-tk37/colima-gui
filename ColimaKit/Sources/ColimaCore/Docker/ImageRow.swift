import Foundation

/// What `docker rmi` accepts for one image row: `repo:tag` removes only that tag, the image ID removes the image.
public enum ImageReference: Sendable, Hashable {
  case tag(repository: String, tag: String)
  case imageID(String)

  public var value: String {
    switch self {
    case .tag(let repository, let tag): "\(repository):\(tag)"
    case .imageID(let id): id
    }
  }
}

public struct ImageSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let repoTags: [String]
  public let size: Int64
  public let created: Date

  public init(id: String, repoTags: [String], size: Int64, created: Date) {
    self.id = id
    self.repoTags = repoTags
    self.size = size
    self.created = created
  }

  public var rows: [ImageRow] {
    let tagged = repoTags.compactMap { ImageRow.parse(repoTag: $0, from: self) }
    return tagged.isEmpty ? [ImageRow.untagged(from: self)] : tagged
  }
}

public struct ImageRow: Sendable, Equatable, Identifiable {
  public static let noneLabel = "<none>"

  public let imageID: String
  public let repository: String
  public let tag: String
  public let size: Int64
  public let created: Date
  public let reference: ImageReference

  public var id: String { "\(imageID)|\(repository):\(tag)" }

  init(
    imageID: String, repository: String, tag: String, size: Int64, created: Date,
    reference: ImageReference
  ) {
    self.imageID = imageID
    self.repository = repository
    self.tag = tag
    self.size = size
    self.created = created
    self.reference = reference
  }

  static func untagged(from image: ImageSummary) -> ImageRow {
    ImageRow(
      imageID: image.id, repository: noneLabel, tag: noneLabel,
      size: image.size, created: image.created, reference: .imageID(image.id)
    )
  }

  static func parse(repoTag: String, from image: ImageSummary) -> ImageRow? {
    if repoTag == "\(noneLabel):\(noneLabel)" || repoTag.isEmpty { return nil }
    // A ":" before the last "/" belongs to a registry host:port, not to a tag.
    let colon = repoTag.lastIndex(of: ":")
    let slash = repoTag.lastIndex(of: "/")
    let tagSeparator: String.Index? =
      switch (colon, slash) {
      case (let colon?, let slash?) where colon < slash: nil
      default: colon
      }
    guard let separator = tagSeparator else {
      return ImageRow(
        imageID: image.id, repository: repoTag, tag: noneLabel,
        size: image.size, created: image.created, reference: .imageID(image.id)
      )
    }
    let repository = String(repoTag[..<separator])
    let tag = String(repoTag[repoTag.index(after: separator)...])
    return ImageRow(
      imageID: image.id, repository: repository, tag: tag,
      size: image.size, created: image.created, reference: .tag(repository: repository, tag: tag)
    )
  }
}
