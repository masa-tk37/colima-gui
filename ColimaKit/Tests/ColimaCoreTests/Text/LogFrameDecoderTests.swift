import Foundation
import Testing

@testable import ColimaCore

private func frame(_ type: UInt8, _ payload: String) -> Data {
  Data(LogFixture.frame(type, payload))
}

private func merged(_ chunks: [LogFrameDecoder.Chunk]) -> [(LogStreamKind, String)] {
  var result: [(LogStreamKind, String)] = []
  for chunk in chunks {
    if let last = result.last, last.0 == chunk.stream {
      result[result.count - 1].1 += String(decoding: chunk.payload, as: UTF8.self)
    } else {
      result.append((chunk.stream, String(decoding: chunk.payload, as: UTF8.self)))
    }
  }
  return result
}

@Test func singleFrameIsDecodedWithItsStream() throws {
  var decoder = LogFrameDecoder()
  let chunks = try decoder.append(frame(1, "hello\n") + frame(2, "oops\n"))
  #expect(chunks.map(\.stream) == [.stdout, .stderr])
  #expect(chunks.map { String(decoding: $0.payload, as: UTF8.self) } == ["hello\n", "oops\n"])
}

@Test func streamTypeZeroIsTreatedAsStdout() throws {
  var decoder = LogFrameDecoder()
  let chunks = try decoder.append(frame(0, "x"))
  #expect(chunks.map(\.stream) == [.stdout])
}

@Test func headerSplitAcrossTwoChunksAtEveryOffset() throws {
  let data = frame(2, "split-header\n")
  for split in 1..<8 {
    var decoder = LogFrameDecoder()
    var chunks = try decoder.append(data.prefix(split))
    #expect(chunks.isEmpty, "split at \(split)")
    chunks += try decoder.append(data.dropFirst(split))
    #expect(merged(chunks).count == 1, "split at \(split)")
    #expect(merged(chunks).first?.0 == .stderr, "split at \(split)")
    #expect(merged(chunks).first?.1 == "split-header\n", "split at \(split)")
  }
}

@Test func payloadSplitAcrossChunksKeepsFollowingFrameAligned() throws {
  let data = frame(1, "first\n") + frame(2, "second\n")
  for split in 1..<data.count {
    var decoder = LogFrameDecoder()
    var chunks = try decoder.append(data.prefix(split))
    chunks += try decoder.append(data.dropFirst(split))
    let result = merged(chunks)
    #expect(result.map(\.0) == [.stdout, .stderr], "split at \(split)")
    #expect(result.map(\.1) == ["first\n", "second\n"], "split at \(split)")
  }
}

@Test func zeroLengthFrameProducesNoChunk() throws {
  var decoder = LogFrameDecoder()
  let chunks = try decoder.append(frame(1, "") + frame(1, "a"))
  #expect(merged(chunks).map(\.1) == ["a"])
}

@Test func emptyInputProducesNothing() throws {
  var decoder = LogFrameDecoder()
  #expect(try decoder.append(Data()).isEmpty)
}

@Test func unknownStreamTypeThrowsAndStaysFailed() throws {
  var decoder = LogFrameDecoder()
  #expect(throws: LogFrameError.malformedHeader) { try decoder.append(frame(7, "x")) }
  #expect(throws: LogFrameError.malformedHeader) { try decoder.append(frame(1, "x")) }
}

@Test func nonZeroPaddingThrows() throws {
  var decoder = LogFrameDecoder()
  var bad = frame(1, "x")
  bad[2] = 1
  #expect(throws: LogFrameError.malformedHeader) { try decoder.append(bad) }
}

@Test func nonTTYFixtureSeparatesStreamsAndLines() throws {
  let data = try LogFixture.data("log-notty")
  for size in [1, 3, 8, 9, data.count] {
    var decoder = LogFrameDecoder()
    var stdout = LineAssembler()
    var stderr = LineAssembler()
    var stdoutLines: [String] = []
    var stderrLines: [String] = []
    for piece in LogFixture.chunks(of: data, size: size) {
      for chunk in try decoder.append(piece) {
        switch chunk.stream {
        case .stderr: stderrLines += stderr.append(chunk.payload)
        default: stdoutLines += stdout.append(chunk.payload)
        }
      }
    }
    #expect(stdoutLines == ["out-line-1", "out-line-2 日本語"], "chunk size \(size)")
    #expect(stderrLines == ["err-line-1", "err-line-2"], "chunk size \(size)")
    #expect(stdout.pending == "partial-no-newline", "chunk size \(size)")
    #expect(stdout.finish() == "partial-no-newline")
    #expect(stderr.finish() == nil)
  }
}

@Test func timestampedFixtureKeepsTimestampsInLines() throws {
  let data = try LogFixture.data("log-notty-timestamps")
  var decoder = LogFrameDecoder()
  var stdout = LineAssembler()
  var lines: [String] = []
  for chunk in try decoder.append(data) where chunk.stream == .stdout {
    lines += stdout.append(chunk.payload)
  }
  #expect(lines.count == 2)
  #expect(lines.allSatisfy { $0.hasPrefix("2026-11-21T") })
  #expect(lines[1].hasSuffix("out-line-2 日本語"))
}

@Test func logLineCarriesStreamAndIdentity() {
  let line = LogLine(id: 3, stream: .combined, text: "t")
  #expect(line.id == 3)
  #expect(line.stream == .combined)
  #expect(line.text == "t")
  #expect(line == LogLine(id: 3, stream: .combined, text: "t"))
}
