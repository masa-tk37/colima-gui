import Foundation

/// A volume's disk usage as reported by the engine; `-1` means the engine could not compute it.
public enum VolumeSize: Sendable, Equatable {
  case bytes(Int64)
  case unknown

  public init(dockerSize: Int64) {
    self = dockerSize < 0 ? .unknown : .bytes(dockerSize)
  }

  public var bytes: Int64? {
    switch self {
    case .bytes(let value): value
    case .unknown: nil
    }
  }
}

public struct VolumeSummary: Sendable, Equatable, Identifiable {
  /// The engine sets this label only on volumes it creates implicitly; named volumes carry no label.
  public static let anonymousLabel = "com.docker.volume.anonymous"

  public let name: String
  public let driver: String
  public let createdAt: Date?
  public let isAnonymous: Bool

  public var id: String { name }

  public init(name: String, driver: String, createdAt: Date?, labels: [String: String]?) {
    self.name = name
    self.driver = driver
    self.createdAt = createdAt
    self.isAnonymous = labels?[Self.anonymousLabel] != nil
  }
}

public struct VolumeRow: Sendable, Equatable, Identifiable {
  public let volume: VolumeSummary
  /// Not in the engine's `dangling=true` list, which is the engine's own definition of unused.
  public let isInUse: Bool

  public var id: String { volume.name }

  public init(volume: VolumeSummary, isInUse: Bool) {
    self.volume = volume
    self.isInUse = isInUse
  }
}
