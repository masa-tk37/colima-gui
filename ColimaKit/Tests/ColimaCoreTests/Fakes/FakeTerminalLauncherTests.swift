import Foundation
import Synchronization
import Testing

@testable import ColimaCore

private let dev = MachineName(instanceName: "cg-dev")!
private let iterm = CustomTerminalApp(path: "/Applications/iTerm.app", bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm")

private func failure(_ result: Result<Void, ShellLaunchError>) -> ShellLaunchError? {
  if case .failure(let error) = result { return error }
  return nil
}

@Test func terminalLauncherRecordsCallsInInvocationOrder() async {
  let launcher = FakeTerminalLauncher()
  let url = URL(filePath: "/Applications/iTerm.app")
  _ = await launcher.availability(of: .ghostty)
  _ = await launcher.application(at: url)
  _ = await launcher.openShell(for: dev, in: .terminal)

  #expect(launcher.calls == [.availability(.ghostty), .application(url), .openShell(dev, .terminal)])
}

@Test func terminalLauncherAvailabilityDefaultsToAvailableAndIsConfigurablePerChoice() async {
  let launcher = FakeTerminalLauncher()
  #expect(await launcher.availability(of: .terminal) == .available)

  launcher.configure {
    $0.availabilityByChoice = [(.ghostty, .notFound), (.custom(iterm), .notFound)]
  }
  #expect(await launcher.availability(of: .ghostty) == .notFound)
  #expect(await launcher.availability(of: .custom(iterm)) == .notFound)
  #expect(await launcher.availability(of: .terminal) == .available)

  launcher.configure { $0.defaultAvailability = .notFound }
  #expect(await launcher.availability(of: .terminal) == .notFound)
}

@Test func terminalLauncherAcceptsOnlyConfiguredApplicationBundles() async {
  let launcher = FakeTerminalLauncher()
  let app = URL(filePath: "/Applications/iTerm.app")
  launcher.configure { $0.applications = [app: iterm] }

  #expect(await launcher.application(at: app) == iterm)
  #expect(await launcher.application(at: URL(filePath: "/Users/me/notes.txt")) == nil)
}

@Test func terminalLauncherOpenShellSucceedsByDefault() async {
  let launcher = FakeTerminalLauncher()
  #expect(failure(await launcher.openShell(for: dev, in: .ghostty)) == nil)
}

@Test func terminalLauncherOpenShellReturnsEachFailureKindThenRepeatsTheLast() async {
  let launcher = FakeTerminalLauncher()
  launcher.configure {
    $0.openShell = [
      .failure(.applicationNotFound), .failure(.automationDenied), .failure(.failed(detail: "boom")),
    ]
  }

  #expect(failure(await launcher.openShell(for: dev, in: .terminal)) == .applicationNotFound)
  #expect(failure(await launcher.openShell(for: dev, in: .terminal)) == .automationDenied)
  #expect(failure(await launcher.openShell(for: dev, in: .terminal)) == .failed(detail: "boom"))
  #expect(failure(await launcher.openShell(for: dev, in: .terminal)) == .failed(detail: "boom"))
}

@Test func terminalLauncherHooksRunBeforeEachCallReturns() async {
  let launcher = FakeTerminalLauncher()
  let hits = Mutex<[String]>([])
  launcher.configure {
    $0.beforeAvailabilityReturns = { hits.withLock { $0.append("availability") } }
    $0.beforeOpenShellReturns = { hits.withLock { $0.append("openShell") } }
  }

  _ = await launcher.availability(of: .terminal)
  _ = await launcher.openShell(for: dev, in: .terminal)

  #expect(hits.withLock { $0 } == ["availability", "openShell"])
}
