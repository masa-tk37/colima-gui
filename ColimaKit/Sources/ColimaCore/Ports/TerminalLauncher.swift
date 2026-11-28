import Foundation

public enum TerminalAvailability: Sendable, Equatable {
  case available
  case notFound
}

public enum ShellLaunchError: Error, Equatable {
  case applicationNotFound
  case automationDenied
  case failed(detail: String)
}

public protocol TerminalLauncher: Sendable {
  func availability(of choice: TerminalChoice) async -> TerminalAvailability
  /// `nil` when the URL is not an application bundle.
  func application(at url: URL) async -> CustomTerminalApp?
  func openShell(for name: MachineName, in choice: TerminalChoice) async -> Result<Void, ShellLaunchError>
}
