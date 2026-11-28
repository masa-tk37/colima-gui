import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private func fixtureBytes(_ name: String) throws -> [UInt8] {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  return [UInt8](try Data(contentsOf: url))
}

private func bytes(_ lines: String...) -> [UInt8] { Array(lines.joined(separator: "\n").utf8) }

private func name(_ instanceName: String) throws -> MachineName {
  try #require(MachineName(instanceName: instanceName))
}

private func machine(_ instanceName: String, in listing: LimaListing) throws -> MachineInstance {
  let wanted = try name(instanceName)
  return try #require(listing.machines.first { $0.name == wanted })
}

private func key(_ unownedInstanceName: String) throws -> MachineKey {
  try #require(MachineKey(unownedInstanceName: unownedInstanceName))
}

private func ownedRow(
  _ instanceName: String = "cg-a", status: String = "Running", marker: String = "ubuntu-24.04",
  extra: String = ""
) -> String {
  #"{"name":"\#(instanceName)","status":"\#(status)","cpus":2,"memory":2147483648,"disk":53687091200,"config":{"env":{"COLIMAGUI_TEMPLATE":"\#(marker)"},"mounts":[]}\#(extra)}"#
}

@Test func fixtureYieldsEveryOwnedMachineInOutputOrder() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))

  #expect(
    listing.machines.map(\.name.instanceName)
      == ["cg-dev", "cg-db", "cg-lost", "cg-nocfg", "cg-weird", "cg-boot"])
}

@Test func runningRowCarriesResourcesMountsAndTemplate() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))

  #expect(
    try machine("cg-dev", in: listing)
      == MachineInstance(
        name: try name("cg-dev"), runState: .running, cpus: 4, memoryBytes: 4_294_967_296,
        diskBytes: 107_374_182_400,
        mounts: [
          MachineMount(path: "/Users/example/work", writable: true),
          MachineMount(path: "/Users/example/ref", writable: false),
        ],
        templateID: "ubuntu-24.04"))
}

@Test func stoppedRowIsStoppedWithItsTemplate() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))
  let db = try machine("cg-db", in: listing)

  #expect(db.runState == .stopped)
  #expect(db.templateID == "debian-13")
  #expect(db.mounts == [MachineMount(path: "/Users/example", writable: false)])
}

@Test func brokenStatusKeepsLimaErrors() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))
  let lost = try machine("cg-lost", in: listing)

  #expect(lost.runState == .broken(errors: ["unexpected driver PID", "stale ha.sock"]))
  #expect(lost.templateID == "alpine")
}

@Test func rowWithoutConfigIsBrokenWhateverItsStatus() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))
  let noConfig = try machine("cg-nocfg", in: listing)

  #expect(
    noConfig
      == .broken(
        name: try name("cg-nocfg"),
        errors: ["failed to load lima.yaml: yaml: line 3: could not find expected ':'"]))
}

@Test func rowWithoutConfigAndWithoutErrorsStillExplainsItself() throws {
  let listing = LimaListDecoder.decode(bytes(#"{"name":"cg-a","status":"Running"}"#))

  guard case .broken(let errors) = try machine("cg-a", in: listing).runState else {
    Issue.record("expected .broken")
    return
  }
  #expect(errors.count == 1)
  #expect(!errors[0].isEmpty)
}

@Test func rowThatCannotBeDecodedBecomesBrokenAndKeepsItsMarker() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))
  let weird = try machine("cg-weird", in: listing)

  guard case .broken(let errors) = weird.runState else {
    Issue.record("expected .broken, got \(weird.runState)")
    return
  }
  #expect(errors.count == 1)
  #expect(errors[0].contains("cpus"))
  #expect(weird.cpus == 0)
  #expect(weird.memoryBytes == 0)
  #expect(weird.diskBytes == 0)
  #expect(weird.mounts.isEmpty)
  #expect(weird.templateID == "fedora-42")
}

@Test func undecodableRowDoesNotCostTheOtherMachines() throws {
  let listing = LimaListDecoder.decode(
    bytes(ownedRow("cg-a"), #"{"name":"cg-b","status":"Running","cpus":"x","config":{"env":{"COLIMAGUI_TEMPLATE":"t"}}}"#, ownedRow("cg-c", status: "Stopped")))

  #expect(try machine("cg-a", in: listing).runState == .running)
  #expect(try machine("cg-c", in: listing).runState == .stopped)
  guard case .broken = try machine("cg-b", in: listing).runState else {
    Issue.record("cg-b should be broken")
    return
  }
}

@Test func unmodelledStatusIsKeptRaw() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))

  #expect(try machine("cg-boot", in: listing).runState == .other(rawStatus: "Installing"))
}

@Test(arguments: ["Uninitialized", ""])
func emptyAndUninitializedStatusAreOther(status: String) throws {
  let listing = LimaListDecoder.decode(bytes(ownedRow(status: status)))

  #expect(try machine("cg-a", in: listing).runState == .other(rawStatus: status))
}

@Test func missingResourceFieldsReadAsZero() throws {
  let listing = LimaListDecoder.decode(
    bytes(#"{"name":"cg-a","status":"Stopped","config":{"env":{"COLIMAGUI_TEMPLATE":"t"}}}"#))
  let instance = try machine("cg-a", in: listing)

  #expect(instance.runState == .stopped)
  #expect(instance.cpus == 0)
  #expect(instance.memoryBytes == 0)
  #expect(instance.diskBytes == 0)
  #expect(instance.mounts.isEmpty)
}

@Test func mountWithoutWritableIsReadOnly() throws {
  let listing = LimaListDecoder.decode(
    bytes(
      #"{"name":"cg-a","status":"Stopped","config":{"env":{"COLIMAGUI_TEMPLATE":"t"},"mounts":[{"location":"/a","mountPoint":"/a"}]}}"#
    ))

  #expect(try machine("cg-a", in: listing).mounts == [MachineMount(path: "/a", writable: false)])
}

@Test func unmarkedPrefixedNamesFeedTheConflictSetOnly() throws {
  let listing = LimaListDecoder.decode(try fixtureBytes("limactl-list-instances.ndjson"))

  #expect(listing.unownedMachineKeys == [try key("cg-manual"), try key("cg-upper")])
  #expect(!listing.machines.map(\.name.instanceName).contains("cg-Manual"))
}

@Test func prefixInOtherCaseIsNotOwnedEvenWithTheMarker() throws {
  let listing = LimaListDecoder.decode(bytes(ownedRow("CG-Dev")))

  #expect(listing.machines.isEmpty)
  #expect(listing.unownedMachineKeys == [try key("cg-dev")])
}

@Test func emptyMarkerDoesNotOwn() throws {
  let listing = LimaListDecoder.decode(bytes(ownedRow("cg-a", marker: "")))

  #expect(listing.machines.isEmpty)
  #expect(listing.unownedMachineKeys == [try key("cg-a")])
}

@Test func nonStringMarkerDoesNotOwnAndDoesNotDropTheRow() throws {
  let listing = LimaListDecoder.decode(
    bytes(#"{"name":"cg-a","status":"Running","config":{"env":{"COLIMAGUI_TEMPLATE":7}}}"#))

  #expect(listing.machines.isEmpty)
  #expect(listing.unownedMachineKeys == [try key("cg-a")])
}

@Test func prefixedNameBreakingTheNameRuleIsOnlyAConflict() throws {
  let listing = LimaListDecoder.decode(bytes(ownedRow("cg-bad name"), ownedRow("cg-")))

  #expect(listing.machines.isEmpty)
  #expect(listing.unownedMachineKeys == [try key("cg-bad name"), try key("cg-")])
}

@Test func unprefixedRowsAreIgnoredWhateverTheirContent() throws {
  let listing = LimaListDecoder.decode(
    bytes(ownedRow("colima"), ownedRow("default"), #"{"name":"colima","status":"Running","cpus":"bad"}"#))

  #expect(listing == LimaListing(machines: [], unownedMachineKeys: []))
}

@Test func rowsWithoutAReadableNameAreDropped() throws {
  let listing = LimaListDecoder.decode(
    bytes(
      #"{"status":"Running"}"#, #"{"name":12,"status":"Running"}"#, #"{"name":null}"#, "not json",
      "[1,2]", ownedRow("cg-a")))

  #expect(listing.machines.map(\.name.instanceName) == ["cg-a"])
  #expect(listing.unownedMachineKeys.isEmpty)
}

@Test func foreignRowsCannotBreakTheListEvenWhenTheirFieldsAreMalformed() throws {
  let listing = LimaListDecoder.decode(
    bytes(
      #"{"name":"other","status":7,"config":"nope"}"#, #"{"name":"cg-x","config":[1],"cpus":"bad"}"#,
      ownedRow("cg-a")))

  #expect(listing.machines.map(\.name.instanceName) == ["cg-a"])
  #expect(listing.unownedMachineKeys == [try key("cg-x")])
}

@Test func limaListEmptyOutputYieldsAnEmptyListing() {
  #expect(LimaListDecoder.decode([]) == LimaListing(machines: [], unownedMachineKeys: []))
  #expect(LimaListDecoder.decode(bytes("", "  ", "\r")) == LimaListing(machines: [], unownedMachineKeys: []))
}

@Test func limaListIgnoresUnknownKeys() throws {
  let listing = LimaListDecoder.decode(
    bytes(ownedRow(extra: #","future":{"a":[1,2,{"b":null}]},"protected":true"#)))

  #expect(try machine("cg-a", in: listing).runState == .running)
}

@Test func windowsLineEndingsAndBlankLinesAreTolerated() throws {
  let output = Array((ownedRow("cg-a") + "\r\n\r\n" + ownedRow("cg-b") + "\r\n").utf8)
  let listing = LimaListDecoder.decode(output)

  #expect(listing.machines.map(\.name.instanceName) == ["cg-a", "cg-b"])
}

@Test func configNullCountsAsMissing() throws {
  let listing = LimaListDecoder.decode(bytes(#"{"name":"cg-a","status":"Running","config":null}"#))

  let instance = try machine("cg-a", in: listing)
  guard case .broken = instance.runState else {
    Issue.record("expected .broken")
    return
  }
  #expect(instance.templateID == nil)
}

@Test func aMountPointDifferentFromTheLocationIsKept() throws {
  let row =
    #"{"name":"cg-a","status":"Stopped","config":{"env":{"COLIMAGUI_TEMPLATE":"t"},"mounts":[{"location":"/a","mountPoint":"/guest/a","writable":true}]}}"#
  let listing = LimaListDecoder.decode(Array(row.utf8))
  #expect(try machine("cg-a", in: listing).mounts == [MachineMount(path: "/a", writable: true, mountPoint: "/guest/a")])
}
