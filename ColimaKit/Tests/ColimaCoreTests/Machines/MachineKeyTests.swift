import Testing

@testable import ColimaCore

@Suite("MachineKey")
struct MachineKeyTests {
  private func name(_ text: String) -> MachineName {
    guard case .success(let name) = MachineName.parse(text, limaHomeUTF8Count: 21) else {
      fatalError("invalid test name \(text)")
    }
    return name
  }

  @Test func keyIsTheLowercasedDisplayNameWithoutThePrefix() {
    #expect(name("Dev").key.rawValue == "dev")
  }

  @Test func displayNamesDifferingOnlyInCaseShareAKey() {
    #expect(name("Dev").key == name("dEV").key)
    #expect(name("Dev") != name("dEV"))
  }

  @Test(arguments: ["CG-dev", "cg-DEV", "cg-dev", "Cg-Dev"])
  func unownedInstanceNameMatchesTheDisplayNameKeyInAnyCase(instanceName: String) {
    #expect(MachineKey(unownedInstanceName: instanceName) == name("Dev").key)
  }

  @Test(arguments: ["dev", "default", "colima", "cg", "xcg-dev", "c-g-dev", ""])
  func unownedInstanceNameWithoutThePrefixHasNoKey(instanceName: String) {
    #expect(MachineKey(unownedInstanceName: instanceName) == nil)
  }

  @Test func prefixedInstanceNameOfTheReservedNamesIsNotTheReservedKeyItself() throws {
    let key = try #require(MachineKey(unownedInstanceName: "CG-Default"))

    #expect(MachineName.reservedKeys.contains(key))
    #expect(MachineKey(unownedInstanceName: "default") == nil)
  }

  @Test func keysWorkAsSetMembers() throws {
    let set: Set<MachineKey> = [name("dev").key, name("Web").key]

    #expect(set.contains(try #require(MachineKey(unownedInstanceName: "CG-WEB"))))
    #expect(!set.contains(name("other").key))
  }
}
