import Foundation
import Observation

public enum CustomSelectionOutcome: Sendable, Equatable {
  case selected
  case rejectedNotApplication
}

public struct ShellLaunchFailure: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let machine: MachineName
  public let error: ShellLaunchError

  public init(id: UUID = UUID(), machine: MachineName, error: ShellLaunchError) {
    self.id = id
    self.machine = machine
    self.error = error
  }
}

@MainActor @Observable
public final class TerminalModel {
  static let defaultsKey = "terminalChoice"

  public internal(set) var choice: TerminalChoice
  /// `nil` until the first check completes.
  public internal(set) var availability: TerminalAvailability?
  public internal(set) var lastLaunchFailure: ShellLaunchFailure?

  @ObservationIgnored private let launcher: any TerminalLauncher
  @ObservationIgnored private let defaults: UserDefaults
  /// Bumped on every choice change so a slow check for an earlier choice cannot overwrite a newer result.
  @ObservationIgnored private var availabilityGeneration = 0

  public init(launcher: any TerminalLauncher, defaults: UserDefaults) {
    self.launcher = launcher
    self.defaults = defaults
    choice = TerminalChoice(storedData: defaults.data(forKey: Self.defaultsKey))
  }

  public func select(_ choice: TerminalChoice) async {
    self.choice = choice
    availabilityGeneration += 1
    persist(choice)
    await refreshAvailability()
  }

  public func selectCustomApplication(at url: URL) async -> CustomSelectionOutcome {
    guard let app = await launcher.application(at: url) else { return .rejectedNotApplication }
    await select(.custom(app))
    return .selected
  }

  public func refreshAvailability() async {
    let generation = availabilityGeneration
    let checked = choice
    let result = await launcher.availability(of: checked)
    guard generation == availabilityGeneration, checked == choice else { return }
    availability = result
  }

  public func openShell(for name: MachineName) async {
    switch await launcher.openShell(for: name, in: choice) {
    case .success:
      lastLaunchFailure = nil
    case .failure(let error):
      lastLaunchFailure = ShellLaunchFailure(machine: name, error: error)
    }
  }

  public func dismissLaunchFailure() {
    lastLaunchFailure = nil
  }

  private func persist(_ choice: TerminalChoice) {
    do {
      defaults.set(try choice.storedData, forKey: Self.defaultsKey)
    } catch {
      ColimaLog.machine.error(
        "terminal choice not saved: \(error.localizedDescription, privacy: .public)")
    }
  }
}
