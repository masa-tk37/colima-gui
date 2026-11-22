import Foundation

/// Bytes are buffered up to each LF, which never occurs inside a multibyte UTF-8 sequence, so characters
/// split across chunks are decoded whole.
public struct LineAssembler: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  /// A single CR before the LF is dropped (TTY output).
  public mutating func append(_ data: Data) -> [String] {
    var lines: [String] = []
    for byte in data {
      guard byte == 0x0A else {
        buffer.append(byte)
        continue
      }
      if buffer.last == 0x0D { buffer.removeLast() }
      lines.append(String(decoding: buffer, as: UTF8.self))
      buffer.removeAll(keepingCapacity: true)
    }
    return lines
  }

  /// Excludes a trailing CR (the LF may still follow) and an incomplete multibyte sequence, so the text
  /// never contains a replacement character the next chunk would have resolved.
  public var pending: String {
    var end = buffer.count
    if buffer.last == 0x0D { end -= 1 }
    end -= Self.incompleteSuffixLength(of: buffer[..<end])
    return String(decoding: buffer[..<end], as: UTF8.self)
  }

  public mutating func finish() -> String? {
    guard !buffer.isEmpty else { return nil }
    if buffer.last == 0x0D { buffer.removeLast() }
    defer { buffer.removeAll() }
    return String(decoding: buffer, as: UTF8.self)
  }

  private static func incompleteSuffixLength(of bytes: ArraySlice<UInt8>) -> Int {
    var continuations = 0
    for byte in bytes.reversed().prefix(4) {
      if byte & 0xC0 == 0x80 {
        continuations += 1
        continue
      }
      let expected: Int
      switch byte {
      case 0xC2...0xDF: expected = 2
      case 0xE0...0xEF: expected = 3
      case 0xF0...0xF4: expected = 4
      default: return 0
      }
      return continuations + 1 < expected ? continuations + 1 : 0
    }
    return 0
  }
}
