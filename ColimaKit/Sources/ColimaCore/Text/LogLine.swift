public enum LogStreamKind: Sendable, Hashable {
  case stdout
  case stderr
  /// A TTY container's output, where the engine does not distinguish the two streams.
  case combined
}

public struct LogLine: Sendable, Identifiable, Equatable {
  public let id: Int
  public let stream: LogStreamKind
  public let text: String

  public init(id: Int, stream: LogStreamKind, text: String) {
    self.id = id
    self.stream = stream
    self.text = text
  }
}
