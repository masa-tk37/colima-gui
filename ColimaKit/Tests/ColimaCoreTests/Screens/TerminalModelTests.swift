import Foundation
import Testing

@testable import ColimaCore

private let ghosttyApp = CustomTerminalApp(
  path: "/Applications/Ghostty.app", bundleIdentifier: "com.mitchellh.ghostty", displayName: "Ghostty")
private let customApp = CustomTerminalApp(
  path: "/Applications/Kitty.app", bundleIdentifier: "net.kovidgoyal.kitty", displayName: "kitty")

private func machineName(_ text: String = "dev") throws -> MachineName {
  try MachineName.parse(text, limaHomeUTF8Count: 20).get()
}

@MainActor
private struct Harness {
  let launcher = FakeTerminalLauncher()
  let defaults: UserDefaults
  private let suite = "TerminalModelTests-\(UUID().uuidString)"

  init(stored: Data? = nil) {
    defaults = UserDefaults(suiteName: suite)!
    if let stored { defaults.set(stored, forKey: TerminalModel.defaultsKey) }
  }

  func makeModel() -> TerminalModel {
    TerminalModel(launcher: launcher, defaults: defaults)
  }

  func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  var openShellCalls: [FakeTerminalLauncher.Call] {
    launcher.calls.filter { if case .openShell = $0 { true } else { false } }
  }
}

@MainActor
@Suite struct TerminalModelTests {
  @Test func defaultsToTerminalWhenNothingIsStored() {
    let harness = Harness()
    defer { harness.tearDown() }
    #expect(harness.makeModel().choice == .terminal)
    #expect(harness.defaults.data(forKey: "terminalChoice") == nil)
  }

  @Test func defaultsToTerminalWhenStoredValueIsUnreadable() {
    let harness = Harness(stored: Data("not json".utf8))
    defer { harness.tearDown() }
    #expect(harness.makeModel().choice == .terminal)
  }

  @Test func restoresAStoredChoiceInANewModel() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    await harness.makeModel().select(.custom(customApp))
    #expect(harness.makeModel().choice == .custom(customApp))
    await harness.makeModel().select(.ghostty)
    #expect(harness.makeModel().choice == .ghostty)
  }

  @Test func selectSavesUnderTheTerminalChoiceKey() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    await harness.makeModel().select(.ghostty)
    let stored = try #require(harness.defaults.data(forKey: "terminalChoice"))
    #expect(TerminalChoice(storedData: stored) == .ghostty)
  }

  @Test func selectFetchesAvailabilityOfTheNewChoice() async {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure {
      $0.availabilityByChoice = [(choice: .ghostty, availability: .notFound)]
    }
    let model = harness.makeModel()
    #expect(model.availability == nil)
    await model.select(.ghostty)
    #expect(model.availability == .notFound)
    await model.select(.terminal)
    #expect(model.availability == .available)
  }

  @Test func refreshAvailabilityRechecksTheSelectedApp() async {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure {
      $0.availabilityByChoice = [(choice: .terminal, availability: .notFound)]
    }
    let model = harness.makeModel()
    await model.refreshAvailability()
    #expect(model.availability == .notFound)
    harness.launcher.configure {
      $0.availabilityByChoice = [(choice: .terminal, availability: .available)]
    }
    await model.refreshAvailability()
    #expect(model.availability == .available)
    #expect(harness.launcher.calls == [.availability(.terminal), .availability(.terminal)])
  }

  @Test func availabilityOfAnOlderChoiceDoesNotOverwriteANewerOne() async {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure {
      $0.availabilityByChoice = [
        (choice: .terminal, availability: .notFound), (choice: .ghostty, availability: .available),
      ]
    }
    let model = harness.makeModel()
    let (gate, release) = AsyncStream<Void>.makeStream()
    harness.launcher.configure {
      $0.beforeAvailabilityReturns = { for await _ in gate { break } }
    }
    let stale = Task { await model.refreshAvailability() }
    let deadline = ContinuousClock.now + .seconds(10)
    while harness.launcher.calls.isEmpty {
      guard ContinuousClock.now < deadline else {
        Issue.record("the launcher was never asked for availability")
        break
      }
      await Task.yield()
    }
    harness.launcher.configure { $0.beforeAvailabilityReturns = nil }
    await model.select(.ghostty)
    release.yield()
    await stale.value
    #expect(model.choice == .ghostty)
    #expect(model.availability == .available)
  }

  @Test func customApplicationIsSelectedWhenTheLauncherRecognizesIt() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    let url = URL(filePath: customApp.path)
    harness.launcher.configure { $0.applications = [url: customApp] }
    let model = harness.makeModel()
    let outcome = await model.selectCustomApplication(at: url)
    #expect(outcome == .selected)
    #expect(model.choice == .custom(customApp))
    #expect(harness.launcher.calls.contains(.application(url)))
    let stored = try #require(harness.defaults.data(forKey: "terminalChoice"))
    #expect(TerminalChoice(storedData: stored) == .custom(customApp))
  }

  @Test func nonApplicationIsRejectedAndTheChoiceStaysUnchanged() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    let model = harness.makeModel()
    await model.select(.ghostty)
    let before = harness.defaults.data(forKey: "terminalChoice")
    let outcome = await model.selectCustomApplication(at: URL(filePath: "/Users/me/notes.txt"))
    #expect(outcome == .rejectedNotApplication)
    #expect(model.choice == .ghostty)
    #expect(harness.defaults.data(forKey: "terminalChoice") == before)
  }

  @Test func missingSelectedAppIsReportedAsNotFound() async {
    let harness = Harness(stored: try? TerminalChoice.custom(ghosttyApp).storedData)
    defer { harness.tearDown() }
    harness.launcher.configure {
      $0.availabilityByChoice = [(choice: .custom(ghosttyApp), availability: .notFound)]
    }
    let model = harness.makeModel()
    #expect(model.choice == .custom(ghosttyApp))
    await model.refreshAvailability()
    #expect(model.availability == .notFound)
  }

  @Test func openShellPassesTheMachineAndTheCurrentChoice() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    let model = harness.makeModel()
    await model.select(.ghostty)
    let name = try machineName()
    await model.openShell(for: name)
    #expect(harness.openShellCalls == [.openShell(name, .ghostty)])
    #expect(model.lastLaunchFailure == nil)
  }

  @Test(arguments: [
    ShellLaunchError.applicationNotFound,
    .automationDenied,
    .failed(detail: "open: exit 1"),
  ])
  func eachLaunchFailureKindIsKeptUntilDismissed(error: ShellLaunchError) async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure { $0.openShell = [.failure(error)] }
    let model = harness.makeModel()
    let name = try machineName("web")
    await model.openShell(for: name)
    let failure = try #require(model.lastLaunchFailure)
    #expect(failure.machine == name)
    #expect(failure.error == error)
    model.dismissLaunchFailure()
    #expect(model.lastLaunchFailure == nil)
  }

  @Test func aLaterSuccessfulLaunchClearsAnEarlierFailure() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure {
      $0.openShell = [.failure(.automationDenied), .success(())]
    }
    let model = harness.makeModel()
    let name = try machineName()
    await model.openShell(for: name)
    #expect(model.lastLaunchFailure?.error == .automationDenied)
    await model.openShell(for: name)
    #expect(model.lastLaunchFailure == nil)
  }

  @Test func eachFailureGetsItsOwnIdentity() async throws {
    let harness = Harness()
    defer { harness.tearDown() }
    harness.launcher.configure { $0.openShell = [.failure(.automationDenied)] }
    let model = harness.makeModel()
    let name = try machineName()
    await model.openShell(for: name)
    let first = try #require(model.lastLaunchFailure)
    await model.openShell(for: name)
    let second = try #require(model.lastLaunchFailure)
    #expect(first.id != second.id)
  }
}
