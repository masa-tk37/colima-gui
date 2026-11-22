import Foundation
import Testing

@testable import ColimaCore

private func fixtureText() throws -> String {
  let url = try #require(
    Bundle.module.url(forResource: "Fixtures/colima-default", withExtension: "yaml")
  )
  return try String(contentsOf: url, encoding: .utf8)
}

private func lines(_ text: String) -> [String] {
  text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private let settings = VMResourceSettings(cpus: 4, memoryGiB: 6, diskGiB: 150)

private func formatError(
  _ text: String,
  settings: VMResourceSettings = settings
) -> ConfigFormatError? {
  do {
    _ = try ColimaConfigRewriter.rewrite(text, settings: settings)
    return nil
  } catch {
    return error
  }
}

@Test func rewritesOnlyTheThreeResourceLinesOfTheMachineFixture() throws {
  let original = try fixtureText()
  let rewritten = try ColimaConfigRewriter.rewrite(original, settings: settings)

  let before = lines(original)
  let after = lines(rewritten)
  #expect(before.count == after.count)

  let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
  #expect(changed.map(\.element.1) == ["cpu: 4", "disk: 150", "memory: 6"])
  #expect(changed.map(\.element.0) == ["cpu: 10", "disk: 100", "memory: 8"])
}

@Test func keepsVMTypeAndCommentsOfTheMachineFixture() throws {
  let original = try fixtureText()
  let rewritten = try ColimaConfigRewriter.rewrite(original, settings: settings)

  #expect(lines(rewritten).contains("vmType: vz"))
  let comments = { (text: String) in lines(text).filter { $0.hasPrefix("#") || $0.contains(" #") } }
  #expect(!comments(original).isEmpty)
  #expect(comments(rewritten) == comments(original))
}

@Test func rewritingWithTheCurrentValuesReturnsTheTextUnchanged() throws {
  let original = try fixtureText()
  let same = VMResourceSettings(cpus: 10, memoryGiB: 8, diskGiB: 100)
  #expect(try ColimaConfigRewriter.rewrite(original, settings: same) == original)
}

@Test func writesWholeMemoryWithoutDecimalPointAndFractionalMemoryWithIt() throws {
  let text = "cpu: 2\nmemory: 2\ndisk: 100\n"
  let whole = try ColimaConfigRewriter.rewrite(
    text, settings: VMResourceSettings(cpus: 2, memoryGiB: 8.0, diskGiB: 100)
  )
  #expect(lines(whole).contains("memory: 8"))
  let fractional = try ColimaConfigRewriter.rewrite(
    text, settings: VMResourceSettings(cpus: 2, memoryGiB: 8.5, diskGiB: 100)
  )
  #expect(lines(fractional).contains("memory: 8.5"))
}

@Test(arguments: ["cpu", "memory", "disk"])
func missingKeyIsAFormatError(key: String) {
  let all = ["cpu: 2", "memory: 2", "disk: 100", "vmType: vz"]
  let text = all.filter { !$0.hasPrefix("\(key):") }.joined(separator: "\n") + "\n"
  #expect(formatError(text)?.key == key)
}

@Test(arguments: ["cpu", "memory", "disk"])
func duplicateKeyIsAFormatError(key: String) {
  let text = "cpu: 2\nmemory: 2\ndisk: 100\n\(key): 9\n"
  #expect(formatError(text)?.key == key)
}

@Test func commentedOutAndSimilarlyNamedKeysDoNotCount() throws {
  let text = "# cpu: 1\ncpu: 2\ncpuType: \"\"\nmemory: 2\ndisk: 100\n"
  let rewritten = try ColimaConfigRewriter.rewrite(text, settings: settings)
  #expect(rewritten == "# cpu: 1\ncpu: 4\ncpuType: \"\"\nmemory: 6\ndisk: 150\n")
}

@Test func keysOnlyBelowColumnZeroAreMissing() {
  let text = "kubernetes:\n  cpu: 2\nmemory: 2\ndisk: 100\n"
  #expect(formatError(text)?.key == "cpu")
}

@Test func indentedTopLevelLookalikeAlongsideRealKeyIsIgnored() throws {
  let text = "cpu: 2\nnested:\n  cpu: 7\nmemory: 2\ndisk: 100\n"
  let rewritten = try ColimaConfigRewriter.rewrite(text, settings: settings)
  #expect(rewritten == "cpu: 4\nnested:\n  cpu: 7\nmemory: 6\ndisk: 150\n")
}

@Test(arguments: [
  "cpu:", "cpu:   ", "cpu: [1, 2]", "cpu: {a: 1}", "cpu: |", "cpu: # only a comment", "cpu: 2 3",
])
func valueThatIsNotAScalarOnTheKeyLineIsAFormatError(line: String) {
  let text = "\(line)\nmemory: 2\ndisk: 100\n"
  #expect(formatError(text)?.key == "cpu")
}

@Test func preservesCRLFLineEndings() throws {
  let text = "cpu: 2\r\n# note\r\nmemory: 2\r\ndisk: 100\r\nvmType: vz\r\n"
  let rewritten = try ColimaConfigRewriter.rewrite(text, settings: settings)
  #expect(rewritten == "cpu: 4\r\n# note\r\nmemory: 6\r\ndisk: 150\r\nvmType: vz\r\n")
}

@Test func preservesMixedLineEndingsAndMissingTrailingNewline() throws {
  let text = "cpu: 2\nmemory: 2\r\ndisk: 100"
  let rewritten = try ColimaConfigRewriter.rewrite(text, settings: settings)
  #expect(rewritten == "cpu: 4\nmemory: 6\r\ndisk: 150")
}

@Test func keepsInlineCommentAndSpacingAfterTheValue() throws {
  let text = "cpu:   2   # cores\nmemory: 2\ndisk: 100\t# gib\n"
  let rewritten = try ColimaConfigRewriter.rewrite(text, settings: settings)
  #expect(rewritten == "cpu:   4   # cores\nmemory: 6\ndisk: 150\t# gib\n")
}

@Test func formatErrorCarriesAReasonForTheUser() {
  let error = formatError("memory: 2\ndisk: 100\n")
  #expect(error?.key == "cpu")
  #expect(error?.reason.isEmpty == false)
}
