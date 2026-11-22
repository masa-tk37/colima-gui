import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func fixtureBytes(_ name: String) throws -> [UInt8] {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  return [UInt8](try Data(contentsOf: url))
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func row(
  name: String = "default",
  status: String = "Running",
  extra: String = ""
) -> String {
  #"{"name":"\#(name)","status":"\#(status)","arch":"aarch64","cpus":4,"memory":4294967296,"disk":53687091200,"runtime":"docker"\#(extra)}"#
}

@Test func capturedRunningFixtureYieldsPresentInstance() throws {
  let observation = try ColimaListDecoder.decode(try fixtureBytes("colima-list-running.json"))

  #expect(
    observation
      == .present(
        VMInstance(
          runState: .running,
          arch: "aarch64",
          cpus: 10,
          memoryBytes: 8_589_934_592,
          diskBytes: 107_374_182_400,
          runtime: "docker"
        )))
}

@Test func stoppedRowKeepsRawStatus() throws {
  let observation = try ColimaListDecoder.decode(bytes(row(status: "Stopped") + "\n"))

  guard case .present(let instance) = observation else {
    Issue.record("expected .present, got \(observation)")
    return
  }
  #expect(instance.runState == .stopped(rawStatus: "Stopped"))
  #expect(instance.cpus == 4)
  #expect(instance.memoryBytes == 4_294_967_296)
  #expect(instance.diskBytes == 53_687_091_200)
}

@Test func brokenStatusIsNotRunningAndKeepsTheRawString() throws {
  let observation = try ColimaListDecoder.decode(bytes(row(status: "Broken")))

  guard case .present(let instance) = observation else {
    Issue.record("expected .present, got \(observation)")
    return
  }
  #expect(instance.runState == .stopped(rawStatus: "Broken"))
  #expect(!instance.runState.isRunning)
}

@Test func emptyOutputIsAbsent() throws {
  #expect(try ColimaListDecoder.decode([]) == .absent)
  #expect(try ColimaListDecoder.decode(bytes("\n")) == .absent)
  #expect(try ColimaListDecoder.decode(bytes("  \n\r\n\n")) == .absent)
}

@Test func outputWithoutDefaultRowIsAbsent() throws {
  let output = row(name: "work") + "\n" + row(name: "other", status: "Stopped") + "\n"
  #expect(try ColimaListDecoder.decode(bytes(output)) == .absent)
}

@Test func defaultRowIsPickedAmongOtherProfiles() throws {
  let output =
    row(name: "work", status: "Stopped") + "\n" + row() + "\n" + row(name: "other") + "\n"

  guard case .present(let instance) = try ColimaListDecoder.decode(bytes(output)) else {
    Issue.record("expected .present")
    return
  }
  #expect(instance.runState == .running)
}

@Test func profileNameMatchIsExact() throws {
  let output = row(name: "Default") + "\n" + row(name: "default2") + "\n"
  #expect(try ColimaListDecoder.decode(bytes(output)) == .absent)
}

@Test func unknownKeysAreIgnored() throws {
  let extra =
    #","address":"192.168.64.2","vmType":"vz","mountType":"virtiofs","nested":{"a":[1,2]}"#
  let observation = try ColimaListDecoder.decode(bytes(row(extra: extra)))

  guard case .present(let instance) = observation else {
    Issue.record("expected .present, got \(observation)")
    return
  }
  #expect(instance.runtime == "docker")
}

@Test func blankLinesAndCRLFBetweenRowsAreTolerated() throws {
  let output = "\n" + row(name: "work") + "\r\n\r\n" + row() + "\r\n"
  guard case .present = try ColimaListDecoder.decode(bytes(output)) else {
    Issue.record("expected .present")
    return
  }
}

@Test func rowWithoutTrailingNewlineIsDecoded() throws {
  guard case .present = try ColimaListDecoder.decode(bytes(row())) else {
    Issue.record("expected .present")
    return
  }
}

@Test(arguments: [
  "not json",
  "[1,2,3]",
  "{",
  #"{"status":"Running"}"#,
  #"{"name":42}"#,
])
func malformedLineThrowsUndecodable(_ line: String) {
  #expect {
    try ColimaListDecoder.decode(bytes(line + "\n"))
  } throws: { error in
    guard case ColimaCLIError.undecodable = error else { return false }
    return true
  }
}

@Test func malformedLineFailsEvenWhenDefaultRowIsPresent() {
  let output = row() + "\n" + "garbage\n"
  #expect(throws: ColimaCLIError.self) {
    try ColimaListDecoder.decode(bytes(output))
  }
}

@Test(arguments: [
  #"{"name":"default","status":"Running","arch":"aarch64","cpus":"4","memory":1,"disk":1,"runtime":"docker"}"#,
  #"{"name":"default","arch":"aarch64","cpus":4,"memory":1,"disk":1,"runtime":"docker"}"#,
  #"{"name":"default","status":"Running","arch":"aarch64","cpus":4,"memory":1,"disk":1,"runtime":7}"#,
  #"{"status":"Stopped","arch":"aarch64","cpus":4,"memory":1,"disk":1,"runtime":"docker"}"#,
])
func defaultRowWithMissingIdentityOrMistypedFieldsThrows(_ line: String) {
  #expect(throws: ColimaCLIError.self) {
    try ColimaListDecoder.decode(bytes(line))
  }
}

@Test func stoppedRowWithoutRuntimeIsPresentWithEmptyRuntime() throws {
  let line =
    #"{"name":"default","status":"Stopped","arch":"aarch64","cpus":4,"memory":4294967296,"disk":53687091200}"#
  let observation = try ColimaListDecoder.decode(bytes(line))

  guard case .present(let instance) = observation else {
    Issue.record("expected .present, got \(observation)")
    return
  }
  #expect(instance.runState == .stopped(rawStatus: "Stopped"))
  #expect(instance.runtime == "")
  #expect(instance.arch == "aarch64")
  #expect(instance.cpus == 4)
}

@Test func rowWithOnlyNameAndStatusIsPresentWithEmptyValues() throws {
  let observation = try ColimaListDecoder.decode(bytes(#"{"name":"default","status":"Broken"}"#))

  #expect(
    observation
      == .present(
        VMInstance(
          runState: .stopped(rawStatus: "Broken"),
          arch: "",
          cpus: 0,
          memoryBytes: 0,
          diskBytes: 0,
          runtime: ""
        )))
}

@Test func nullOptionalFieldsDecodeLikeAbsentOnes() throws {
  let line =
    #"{"name":"default","status":"Stopped","arch":null,"cpus":null,"memory":null,"disk":null,"runtime":null}"#
  guard case .present(let instance) = try ColimaListDecoder.decode(bytes(line)) else {
    Issue.record("expected .present")
    return
  }
  #expect(instance.runtime == "")
  #expect(instance.cpus == 0)
}

@Test func invalidUTF8Throws() {
  #expect(throws: ColimaCLIError.self) {
    try ColimaListDecoder.decode([0xFF, 0xFE, 0x0A])
  }
}

@Test func undecodableDetailNamesTheLineNumber() {
  let output = row() + "\n" + "garbage\n"
  do {
    _ = try ColimaListDecoder.decode(bytes(output))
    Issue.record("expected a throw")
  } catch {
    guard case .undecodable(let detail) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(detail.contains("line 2"))
  }
}
