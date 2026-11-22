import Foundation
import Testing

@testable import ColimaCore

@Suite("VMCommand wire form")
struct VMCommandCodableTests {
  private func roundTrip(_ command: VMCommand) throws -> VMCommand {
    try JSONDecoder().decode(VMCommand.self, from: JSONEncoder().encode(command))
  }

  private func decode(_ json: String) throws -> VMCommand {
    try JSONDecoder().decode(VMCommand.self, from: Data(json.utf8))
  }

  @Test func everyCommandSurvivesARoundTrip() throws {
    let spec = VMCreateSpec(
      resources: VMResourceSettings(cpus: 4, memoryGiB: 6.5, diskGiB: 120), vmType: .krunkit)
    for command in [VMCommand.start, .stop, .delete, .create(spec)] {
      #expect(try roundTrip(command) == command)
    }
  }

  @Test func aMemorySizeEncodedInExponentNotationSurvivesARoundTrip() throws {
    let spec = VMCreateSpec(
      resources: VMResourceSettings(cpus: 2, memoryGiB: 1e16, diskGiB: 100), vmType: .vz)
    #expect(try roundTrip(.create(spec)) == .create(spec))
  }

  @Test(arguments: [
    #"{"kind":"create","cpus":0,"memoryGiB":8,"diskGiB":100,"vmType":"vz"}"#,
    #"{"kind":"create","cpus":4,"memoryGiB":0.5,"diskGiB":100,"vmType":"vz"}"#,
    #"{"kind":"create","cpus":4,"memoryGiB":8,"diskGiB":0,"vmType":"vz"}"#,
    #"{"kind":"create","cpus":4,"memoryGiB":8,"diskGiB":100,"vmType":"hyperv"}"#,
    #"{"kind":"create","cpus":4,"diskGiB":100,"vmType":"vz"}"#,
    #"{"kind":"shell"}"#,
  ])
  func anInvalidCommandIsRejected(json: String) {
    #expect(throws: DecodingError.self) { try decode(json) }
  }
}
