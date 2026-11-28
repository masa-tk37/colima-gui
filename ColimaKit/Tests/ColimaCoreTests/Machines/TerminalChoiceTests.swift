import Foundation
import Testing

@testable import ColimaCore

@Suite("TerminalChoice")
struct TerminalChoiceTests {
  private let custom = CustomTerminalApp(
    path: "/Applications/iTerm.app",
    bundleIdentifier: "com.googlecode.iterm2",
    displayName: "iTerm"
  )

  @Test func customAppKeepsItsIdentity() {
    #expect(custom.path == "/Applications/iTerm.app")
    #expect(custom.bundleIdentifier == "com.googlecode.iterm2")
    #expect(custom.displayName == "iTerm")
  }

  @Test(arguments: [0, 1, 2])
  func storedFormRoundTripsEveryChoice(index: Int) throws {
    let choices: [TerminalChoice] = [.terminal, .ghostty, .custom(custom)]
    let choice = choices[index]
    #expect(TerminalChoice(storedData: try choice.storedData) == choice)
  }

  @Test func storedFormIsJSON() throws {
    let object = try JSONSerialization.jsonObject(with: try TerminalChoice.ghostty.storedData)
    #expect(object is [String: Any])
  }

  @Test func customAppsWithDifferentPathsStayDistinct() throws {
    let other = CustomTerminalApp(
      path: "/Users/me/Applications/iTerm.app",
      bundleIdentifier: custom.bundleIdentifier,
      displayName: custom.displayName
    )
    #expect(TerminalChoice.custom(custom) != TerminalChoice.custom(other))
    #expect(TerminalChoice(storedData: try TerminalChoice.custom(other).storedData) == .custom(other))
  }

  @Test func missingValueFallsBackToTerminal() {
    #expect(TerminalChoice(storedData: nil) == .terminal)
  }

  @Test(arguments: [
    "",
    "not json",
    "null",
    "[]",
    "{}",
    "\"ghostty\"",
    #"{"iterm":{}}"#,
    #"{"custom":{"path":"/Applications/X.app"}}"#,
    #"{"custom":{"path":1,"bundleIdentifier":"x","displayName":"X"}}"#,
  ])
  func unreadableValueFallsBackToTerminal(text: String) {
    #expect(TerminalChoice(storedData: Data(text.utf8)) == .terminal)
  }

  @Test func defaultChoiceIsTerminal() {
    #expect(TerminalChoice.default == .terminal)
  }
}
