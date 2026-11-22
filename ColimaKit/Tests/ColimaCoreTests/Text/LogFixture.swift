import Foundation
import Testing

enum LogFixture {
  static func data(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "bin"))
    return try Data(contentsOf: url)
  }

  /// One frame of the engine's multiplexed log stream: the stream type, three zero bytes, the big-endian length.
  static func frame(_ type: UInt8, _ text: String) -> [UInt8] {
    let payload = Array(text.utf8)
    let length = UInt32(payload.count)
    return [type, 0, 0, 0] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
      + payload
  }

  static func chunks(of data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data[$0..<min($0 + size, data.count)] }
  }
}
