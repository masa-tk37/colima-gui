import Foundation
import Testing

@testable import ColimaCore

@Suite("MachineObservation values")
struct MachineObservationTests {
  private func name(_ text: String) -> MachineName {
    guard case .success(let name) = MachineName.parse(text, limaHomeUTF8Count: 21) else {
      fatalError("invalid test name \(text)")
    }
    return name
  }

  @Test func instanceCarriesTheListedFields() {
    let mount = MachineMount(path: "/Users/me/src", writable: true)
    let instance = MachineInstance(
      name: name("dev"), runState: .running, cpus: 4, memoryBytes: 4 << 30, diskBytes: 100 << 30,
      mounts: [mount], templateID: "ubuntu")
    #expect(instance.name == name("dev"))
    #expect(instance.runState == .running)
    #expect(instance.cpus == 4)
    #expect(instance.memoryBytes == 4_294_967_296)
    #expect(instance.diskBytes == 107_374_182_400)
    #expect(instance.mounts == [mount])
    #expect(instance.templateID == "ubuntu")
  }

  @Test func brokenInstanceHasZeroSizesNoMountsAndTheDecodeErrors() {
    let instance = MachineInstance.broken(name: name("dev"), errors: ["bad row"])
    #expect(instance.runState == .broken(errors: ["bad row"]))
    #expect(instance.cpus == 0)
    #expect(instance.memoryBytes == 0)
    #expect(instance.diskBytes == 0)
    #expect(instance.mounts.isEmpty)
    #expect(instance.templateID == nil)
  }

  @Test func runStatesDistinguishUnrecognizedStatuses() {
    #expect(MachineRunState.other(rawStatus: "Broken") != .other(rawStatus: "Stopped"))
    #expect(MachineRunState.running != .stopped)
  }

  @Test func listingKeepsOwnedMachinesAndTheUnownedKeys() throws {
    let unowned = try #require(MachineKey(unownedInstanceName: "CG-other"))
    let listing = LimaListing(machines: [], unownedMachineKeys: [unowned])
    #expect(listing.machines.isEmpty)
    #expect(listing.unownedMachineKeys == [unowned])
  }

  @Test func displayStatesIncludeTheInProgressAndAbnormalCases() {
    let states: [MachineDisplayState] = [
      .creating, .starting, .stopping, .deleting, .saving, .running, .stopped,
      .broken(errors: ["x"]), .other(rawStatus: "Paused"),
    ]
    #expect(states.count == 9)
    #expect(MachineDisplayState.broken(errors: ["x"]) == .broken(errors: ["x"]))
  }
}
