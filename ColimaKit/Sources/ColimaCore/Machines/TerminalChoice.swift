import Foundation

public enum TerminalChoice: Sendable, Equatable, Codable {
  case terminal
  case ghostty
  case custom(CustomTerminalApp)

  public static let `default`: TerminalChoice = .terminal

  public var storedData: Data {
    get throws { try JSONEncoder().encode(self) }
  }

  /// Falls back to `default` when the value is absent or cannot be decoded, so a stale or hand-edited default never blocks opening a shell.
  public init(storedData: Data?) {
    guard let storedData, let choice = try? JSONDecoder().decode(TerminalChoice.self, from: storedData) else {
      self = .default
      return
    }
    self = choice
  }
}

public struct CustomTerminalApp: Sendable, Equatable, Codable {
  public let path: String
  public let bundleIdentifier: String
  public let displayName: String

  public init(path: String, bundleIdentifier: String, displayName: String) {
    self.path = path
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
  }
}
