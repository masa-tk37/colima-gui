import Testing

@testable import ColimaCore

@Suite("MachineName")
struct MachineNameTests {
  private let limaHome = 21

  private func parsed(_ text: String, limaHome: Int = 21) -> MachineName? {
    guard case .success(let name) = MachineName.parse(text, limaHomeUTF8Count: limaHome) else { return nil }
    return name
  }

  private func problem(_ text: String, limaHome: Int = 21) -> MachineNameProblem? {
    guard case .failure(let problem) = MachineName.parse(text, limaHomeUTF8Count: limaHome) else { return nil }
    return problem
  }

  @Test func instanceNameAddsThePrefixAndKeepsTheDisplayName() throws {
    let name = try #require(parsed("Dev"))

    #expect(name.rawValue == "Dev")
    #expect(name.instanceName == "cg-Dev")
    #expect(MachineName.instancePrefix == "cg-")
  }

  @Test(arguments: ["dev", "Dev1", "a", "web-1", "a.b", "a_b", "a-b.c_d", "9lives", "x.yml.bak"])
  func acceptsNamesThatFollowLimasIdentifierRule(text: String) {
    #expect(parsed(text) != nil)
  }

  @Test func emptyTextIsEmpty() {
    #expect(problem("") == .empty)
  }

  @Test(arguments: [
    " ", " dev", "dev ", "de v", "-dev", "dev-", ".dev", "dev.", "a--b", "a..b", "a.-b", "a_", "dev/x",
    "dev:1", "日本語", "dév", "a\nb", "dev.yml", "dev.yaml", "x.yml", "..",
  ])
  func rejectsCharactersOutsideTheRule(text: String) {
    #expect(problem(text) == .invalidCharacters)
  }

  @Test func displayNameOfExactlyTheLimitIsAccepted() {
    let limit = MachineName.maxLength(limaHomeUTF8Count: 21)

    #expect(limit == 52)
    #expect(parsed(String(repeating: "a", count: limit)) != nil)
  }

  @Test func oneCharacterOverTheLimitIsTooLong() {
    #expect(problem(String(repeating: "a", count: 53)) == .tooLong(maxLength: 52))
  }

  @Test func limitFollowsTheSocketPathBudget() {
    #expect(MachineName.maxLength(limaHomeUTF8Count: 21) == 52)
    #expect(MachineName.maxLength(limaHomeUTF8Count: 30) == 43)
    #expect(MachineName.maxLength(limaHomeUTF8Count: 0) == 73)
    #expect(MachineName.maxLength(limaHomeUTF8Count: 200) == 0)
  }

  @Test func invalidCharactersAreReportedBeforeLength() {
    #expect(problem(String(repeating: "a", count: 60) + "!") == .invalidCharacters)
  }

  @Test func instanceNameInitializerStripsTheExactCasePrefix() throws {
    let name = try #require(MachineName(instanceName: "cg-Dev"))

    #expect(name.rawValue == "Dev")
    #expect(name.instanceName == "cg-Dev")
  }

  @Test(arguments: ["dev", "default", "colima", "CG-dev", "Cg-dev", "cg_dev", "cg", "cg-", "xcg-dev", ""])
  func instanceNameInitializerRejectsNamesWithoutTheExactPrefix(text: String) {
    #expect(MachineName(instanceName: text) == nil)
  }

  @Test(arguments: ["cg--dev", "cg-dev-", "cg-a b", "cg-dev.yml", "cg-.dev"])
  func instanceNameInitializerRejectsARemainderThatBreaksTheCharacterRule(text: String) {
    #expect(MachineName(instanceName: text) == nil)
  }

  @Test func instanceNameInitializerDoesNotApplyTheLengthLimit() throws {
    let remainder = String(repeating: "a", count: 70)
    let name = try #require(MachineName(instanceName: "cg-" + remainder))

    #expect(name.rawValue == remainder)
  }

  @Test func parseAndInstanceNameRoundTrip() throws {
    let name = try #require(parsed("Web-1"))

    #expect(MachineName(instanceName: name.instanceName) == name)
  }

  @Test func reservedKeysAreDefaultAndColima() {
    #expect(MachineName.reservedKeys.count == 2)
    #expect(MachineName.reservedKeys.contains(parsed("default")!.key))
    #expect(MachineName.reservedKeys.contains(parsed("Default")!.key))
    #expect(MachineName.reservedKeys.contains(parsed("COLIMA")!.key))
    #expect(!MachineName.reservedKeys.contains(parsed("dev")!.key))
  }

  @Test func parseLeavesReservedNamesToTheValidator() {
    #expect(parsed("default") != nil)
    #expect(parsed("colima") != nil)
  }
}
