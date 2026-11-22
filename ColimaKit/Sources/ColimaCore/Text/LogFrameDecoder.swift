import Foundation

public enum LogFrameError: Error, Sendable, Equatable {
  case malformedHeader
}

/// Splits the engine's multiplexed log stream (8-byte header: stream type, three zero bytes, big-endian
/// uint32 payload length).
public struct LogFrameDecoder: Sendable {
  public struct Chunk: Sendable, Equatable {
    public let stream: LogStreamKind
    public let payload: Data
  }

  private static let headerLength = 8

  private var header: [UInt8] = []
  private var current: (stream: LogStreamKind, remaining: Int)?
  private var isFailed = false

  public init() {}

  /// After a throw the decoder stays failed: the stream cannot be re-synchronized.
  public mutating func append(_ data: Data) throws(LogFrameError) -> [Chunk] {
    if isFailed { throw .malformedHeader }
    var chunks: [Chunk] = []
    var rest = data[...]
    while !rest.isEmpty {
      if let frame = current {
        let take = min(frame.remaining, rest.count)
        chunks.append(Chunk(stream: frame.stream, payload: Data(rest.prefix(take))))
        rest = rest.dropFirst(take)
        current = take == frame.remaining ? nil : (frame.stream, frame.remaining - take)
        continue
      }
      let take = min(Self.headerLength - header.count, rest.count)
      header.append(contentsOf: rest.prefix(take))
      rest = rest.dropFirst(take)
      guard header.count == Self.headerLength else { break }
      defer { header.removeAll(keepingCapacity: true) }
      guard let stream = Self.stream(forType: header[0]), header[1...3].allSatisfy({ $0 == 0 })
      else {
        isFailed = true
        throw .malformedHeader
      }
      let length = header[4...7].reduce(0) { $0 << 8 | Int($1) }
      if length > 0 { current = (stream, length) }
    }
    return chunks
  }

  private static func stream(forType type: UInt8) -> LogStreamKind? {
    switch type {
    case 0, 1: .stdout
    case 2: .stderr
    default: nil
    }
  }
}
