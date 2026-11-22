import Foundation
import Testing

@testable import ColimaCore

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Test func completeLinesAreReturnedAndNothingIsPending() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("a\nb\n")) == ["a", "b"])
  #expect(assembler.pending == "")
  #expect(assembler.finish() == nil)
}

@Test func emptyLinesAreKept() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("a\n\nb\n")) == ["a", "", "b"])
}

@Test func lineSplitAcrossChunksIsJoined() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("hel")) == [])
  #expect(assembler.pending == "hel")
  #expect(assembler.append(bytes("lo\nwor")) == ["hello"])
  #expect(assembler.pending == "wor")
}

@Test func multibyteCharacterSplitAcrossChunksIsCarriedOver() {
  let full = Array("日本語\n".utf8)
  for split in 1..<full.count - 1 {
    var assembler = LineAssembler()
    #expect(assembler.append(Data(full[..<split])) == [], "split at \(split)")
    #expect(!assembler.pending.contains("\u{FFFD}"), "split at \(split)")
    #expect(assembler.append(Data(full[split...])) == ["日本語"], "split at \(split)")
    #expect(assembler.pending == "")
  }
}

@Test func pendingExcludesAnIncompleteTrailingMultibyteSequence() {
  let full = Array("ab日".utf8)
  var assembler = LineAssembler()
  _ = assembler.append(Data(full[..<3]))
  #expect(assembler.pending == "ab")
  _ = assembler.append(Data(full[3..<4]))
  #expect(assembler.pending == "ab")
  _ = assembler.append(Data(full[4...]))
  #expect(assembler.pending == "ab日")
}

@Test func pendingKeepsAFourByteCharacterOnceComplete() {
  var assembler = LineAssembler()
  let full = Array("x😀".utf8)
  _ = assembler.append(Data(full[..<4]))
  #expect(assembler.pending == "x")
  _ = assembler.append(Data(full[4...]))
  #expect(assembler.pending == "x😀")
}

@Test func lineWithoutTrailingNewlineIsPendingThenFlushedByFinish() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("done\npartial")) == ["done"])
  #expect(assembler.pending == "partial")
  #expect(assembler.finish() == "partial")
  #expect(assembler.pending == "")
  #expect(assembler.finish() == nil)
}

@Test func finishReplacesAnUnfinishedMultibyteSequence() {
  var assembler = LineAssembler()
  _ = assembler.append(Data(Array("ab日".utf8).dropLast()))
  #expect(assembler.finish() == "ab\u{FFFD}")
}

@Test func crlfIsStrippedLikeLf() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("a\r\nb\r\n")) == ["a", "b"])
}

@Test func crlfSplitBetweenCarriageReturnAndLineFeed() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("a\r")) == [])
  #expect(assembler.pending == "a")
  #expect(assembler.append(bytes("\nb")) == ["a"])
  #expect(assembler.pending == "b")
}

@Test func carriageReturnInsideALineIsKept() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("10%\r20%\r30%\n")) == ["10%\r20%\r30%"])
}

@Test func onlyOneCarriageReturnIsStrippedBeforeLineFeed() {
  var assembler = LineAssembler()
  #expect(assembler.append(bytes("a\r\r\n")) == ["a\r"])
}

@Test func invalidUTF8InACompleteLineBecomesAReplacementCharacter() {
  var assembler = LineAssembler()
  #expect(assembler.append(Data([0x61, 0xFF, 0x62, 0x0A])) == ["a\u{FFFD}b"])
}

@Test func readingPendingDoesNotChangeAssembledLines() {
  let chunks: [Data] = [
    bytes("out-line-1\r"), bytes("\nout-line-2 "), Data([0xE6, 0x97]), Data([0xA5, 0xE6]),
    Data([0x9C, 0xAC, 0xE8, 0xAA, 0x9E, 0x0A]), bytes("partial"), bytes("-tail\r"),
  ]
  var observed = LineAssembler()
  var untouched = LineAssembler()
  var observedLines: [String] = []
  var untouchedLines: [String] = []
  for chunk in chunks {
    observedLines += observed.append(chunk)
    _ = observed.pending
    _ = observed.pending
    untouchedLines += untouched.append(chunk)
  }
  #expect(observedLines == untouchedLines)
  #expect(observedLines == ["out-line-1", "out-line-2 日本語"])
  #expect(observed.finish() == untouched.finish())
}

@Test func ttyFixtureAssemblesIntoCrlfStrippedLines() throws {
  let data = try LogFixture.data("log-tty")
  for size in [1, 2, 3, 7, data.count] {
    var assembler = LineAssembler()
    var lines: [String] = []
    for chunk in LogFixture.chunks(of: data, size: size) {
      lines += assembler.append(chunk)
    }
    #expect(
      lines == ["out-line-1", "err-line-1", "out-line-2 日本語", "err-line-2"], "chunk size \(size)")
    #expect(assembler.pending == "partial-no-newline")
    #expect(assembler.finish() == "partial-no-newline")
  }
}
