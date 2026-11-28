import Foundation
import Synchronization

@testable import ColimaCore

final class FakeTerminalLauncher: TerminalLauncher {
  enum Call: Equatable {
    case availability(TerminalChoice)
    case application(URL)
    case openShell(MachineName, TerminalChoice)
  }

  struct Config: Sendable {
    var availabilityByChoice: [(choice: TerminalChoice, availability: TerminalAvailability)] = []
    var defaultAvailability = TerminalAvailability.available
    var applications: [URL: CustomTerminalApp] = [:]
    /// Consumed one per call; the last entry repeats.
    var openShell: [Result<Void, ShellLaunchError>] = [.success(())]
    var beforeAvailabilityReturns: (@Sendable () async -> Void)?
    var beforeOpenShellReturns: (@Sendable () async -> Void)?
  }

  private struct State {
    var config = Config()
    var calls: [Call] = []
    var openShellCount = 0
  }

  private let state = Mutex(State())

  func configure(_ body: (inout Config) -> Void) {
    state.withLock { body(&$0.config) }
  }

  var calls: [Call] { state.withLock { $0.calls } }

  func availability(of choice: TerminalChoice) async -> TerminalAvailability {
    let (result, hook) = state.withLock { state in
      state.calls.append(.availability(choice))
      return (
        state.config.availabilityByChoice.last { $0.choice == choice }?.availability
          ?? state.config.defaultAvailability,
        state.config.beforeAvailabilityReturns
      )
    }
    await hook?()
    return result
  }

  func application(at url: URL) async -> CustomTerminalApp? {
    state.withLock { state in
      state.calls.append(.application(url))
      return state.config.applications[url]
    }
  }

  func openShell(for name: MachineName, in choice: TerminalChoice) async -> Result<Void, ShellLaunchError> {
    let (result, hook) = state.withLock { state in
      state.calls.append(.openShell(name, choice))
      let results = state.config.openShell
      defer { state.openShellCount += 1 }
      return (results[min(state.openShellCount, results.count - 1)], state.config.beforeOpenShellReturns)
    }
    await hook?()
    return result
  }
}
