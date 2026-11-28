import Foundation
import Testing

@testable import ColimaCore

@Suite("MachineCommand wire form")
struct MachineCommandCodableTests {
  private let name = MachineName(instanceName: "cg-dev")!
  private let mounts = [
    MachineMount(path: "/Users/masahiro", writable: true),
    MachineMount(path: #"/Volumes/a,b/"c""#, writable: false),
  ]

  private var commands: [MachineCommand] {
    [
      .create(
        MachineCreateSpec(
          name: name, template: MachineTemplate(id: "ubuntu-24.04")!,
          resources: MachineResources(cpus: 2, memoryGiB: 4.5, diskGiB: 100), mounts: mounts)),
      .start(name), .stop(name), .delete(name),
      .edit(name, MachineEditSpec(resources: MachineResources(cpus: 4, memoryGiB: 8, diskGiB: 120), mounts: mounts)),
    ]
  }

  private func decode(_ json: String) throws -> MachineCommand {
    try JSONDecoder().decode(MachineCommand.self, from: Data(json.utf8))
  }

  @Test func everyCommandSurvivesARoundTrip() throws {
    for command in commands {
      let data = try JSONEncoder().encode(command)
      #expect(try JSONDecoder().decode(MachineCommand.self, from: data) == command)
    }
  }

  @Test func theWireCarriesTheDisplayNameWithoutThePrefix() throws {
    for command in commands {
      let json = try #require(String(data: JSONEncoder().encode(command), encoding: .utf8))
      #expect(json.contains(#""name":"dev""#) || json.contains(#""name" : "dev""#))
      #expect(!json.contains("cg-"))
    }
  }

  @Test func aDecodedCommandBuildsPrefixedArguments() throws {
    let decoded = try decode(#"{"kind":"start","name":"dev"}"#)
    #expect(decoded.arguments == ["start", "--tty=false", "cg-dev"])
  }

  @Test func aNameLongerThanTheCreateLimitStillDecodes() throws {
    let long = String(repeating: "a", count: 70)
    #expect(try decode(#"{"kind":"stop","name":"\#(long)"}"#).name.rawValue == long)
  }

  @Test(arguments: [
    #"{"kind":"start","name":""}"#,
    #"{"kind":"start","name":"a b"}"#,
    #"{"kind":"start","name":"-dev"}"#,
    #"{"kind":"start","name":"dev.yaml"}"#,
    #"{"kind":"start","name":"../x"}"#,
    #"{"kind":"start","name":"default"}"#,
    #"{"kind":"delete","name":"Colima"}"#,
    #"{"kind":"start"}"#,
    #"{"kind":"shell","name":"dev"}"#,
  ])
  func anInvalidNameOrKindIsRejected(json: String) {
    #expect(throws: DecodingError.self) { try decode(json) }
  }

  private func create(
    template: String = "ubuntu", cpus: String = "2", memory: String = "4", disk: String = "100",
    mounts: String = #"[{"path":"/Users/masahiro","writable":true}]"#
  ) -> String {
    #"{"kind":"create","name":"dev","template":"\#(template)","cpus":\#(cpus),"memoryGiB":\#(memory),"diskGiB":\#(disk),"mounts":\#(mounts)}"#
  }

  private func edit(
    cpus: String = "2", memory: String = "4", disk: String = "100",
    mounts: String = #"[{"path":"/Users/masahiro","writable":true}]"#
  ) -> String {
    #"{"kind":"edit","name":"dev","cpus":\#(cpus),"memoryGiB":\#(memory),"diskGiB":\#(disk),"mounts":\#(mounts)}"#
  }

  @Test func theWellFormedFixturesDecode() throws {
    _ = try decode(create())
    _ = try decode(edit())
  }

  @Test(arguments: ["alpine-iso", "ubuntu-lts", "default", "experimental/foo", "docker", "", "template:ubuntu", "Ubuntu"])
  func aTemplateOutsideTheAllowListIsRejected(template: String) {
    #expect(throws: DecodingError.self) { try decode(create(template: template)) }
  }

  @Test(arguments: [("0", "4", "100"), ("-1", "4", "100"), ("2", "0", "100"), ("2", "0.5", "100"), ("2", "4", "0")])
  func resourcesBelowOneAreRejected(cpus: String, memory: String, disk: String) {
    #expect(throws: DecodingError.self) { try decode(create(cpus: cpus, memory: memory, disk: disk)) }
    #expect(throws: DecodingError.self) { try decode(edit(cpus: cpus, memory: memory, disk: disk)) }
  }

  @Test func nonFiniteMemoryIsRejected() {
    let json = create(memory: #""nan""#)
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    #expect(throws: DecodingError.self) { try decoder.decode(MachineCommand.self, from: Data(json.utf8)) }
  }

  @Test(arguments: [
    #"[{"path":"relative/dir","writable":true}]"#,
    #"[{"path":"","writable":true}]"#,
    #"[{"path":"/Users/{{.Home}}","writable":true}]"#,
    #"[{"path":"~/x","writable":true}]"#,
    #"[{"path":"/ok","writable":true},{"path":"bad","writable":false}]"#,
    #"[{"path":"/ok","writable":true,"mountPoint":"/x/{{.Home}}"}]"#,
    #"[{"path":"/ok","writable":true,"mountPoint":"relative"}]"#,
  ])
  func aBadMountIsRejected(mounts: String) {
    #expect(throws: DecodingError.self) { try decode(create(mounts: mounts)) }
    #expect(throws: DecodingError.self) { try decode(edit(mounts: mounts)) }
  }

  @Test func aMissingFieldIsRejected() {
    #expect(throws: DecodingError.self) { try decode(#"{"kind":"create","name":"dev","template":"ubuntu"}"#) }
    #expect(throws: DecodingError.self) { try decode(#"{"kind":"edit","name":"dev","cpus":2}"#) }
  }
}
