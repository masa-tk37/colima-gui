import Testing

@testable import ColimaCore
@testable import ColimaUI

@Suite(.timeLimit(.minutes(1)))
struct TerminalSettingsPresentationTests {
  private let warp = CustomTerminalApp(path: "/Applications/Warp.app", bundleIdentifier: "dev.warp.Warp", displayName: "Warp")

  @Test func eachChoiceSelectsItsOption() {
    #expect(TerminalSettingsPresentation.option(for: .terminal) == .terminal)
    #expect(TerminalSettingsPresentation.option(for: .ghostty) == .ghostty)
    #expect(TerminalSettingsPresentation.option(for: .custom(warp)) == .other)
  }

  @Test func onlyACustomChoiceHasAnApplicationName() {
    #expect(TerminalSettingsPresentation.customApplicationName(for: .terminal) == nil)
    #expect(TerminalSettingsPresentation.customApplicationName(for: .ghostty) == nil)
    #expect(TerminalSettingsPresentation.customApplicationName(for: .custom(warp)) == "Warp")
  }

  @Test func theMissingNoticeNamesTheCurrentChoice() {
    #expect(TerminalSettingsPresentation.missing(choice: .terminal, availability: .notFound) == .terminal)
    #expect(TerminalSettingsPresentation.missing(choice: .ghostty, availability: .notFound) == .ghostty)
    #expect(TerminalSettingsPresentation.missing(choice: .custom(warp), availability: .notFound) == .custom(name: "Warp"))
  }

  @Test func noMissingNoticeWhenAvailableOrNotYetChecked() {
    for choice in [TerminalChoice.terminal, .ghostty, .custom(warp)] {
      #expect(TerminalSettingsPresentation.missing(choice: choice, availability: .available) == nil)
      #expect(TerminalSettingsPresentation.missing(choice: choice, availability: nil) == nil)
    }
  }

  @Test func startsWithoutARejection() {
    #expect(!TerminalSettingsPresentation().rejectedSelection)
  }

  @Test func aRejectedApplicationShowsTheRejection() {
    var presentation = TerminalSettingsPresentation()
    presentation.apply(.rejectedNotApplication)
    #expect(presentation.rejectedSelection)
  }

  @Test func aSelectedApplicationClearsTheRejection() {
    var presentation = TerminalSettingsPresentation()
    presentation.apply(.rejectedNotApplication)
    presentation.apply(.selected)
    #expect(!presentation.rejectedSelection)
  }

  @Test func clearingRemovesTheRejection() {
    var presentation = TerminalSettingsPresentation()
    presentation.apply(.rejectedNotApplication)
    presentation.clearRejection()
    #expect(!presentation.rejectedSelection)
  }
}
