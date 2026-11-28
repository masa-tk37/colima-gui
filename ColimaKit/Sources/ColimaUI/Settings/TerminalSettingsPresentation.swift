import ColimaCore

struct TerminalSettingsPresentation: Equatable {
  enum Option: Hashable, CaseIterable {
    case terminal
    case ghostty
    case other
  }

  enum Missing: Equatable {
    case terminal
    case ghostty
    case custom(name: String)
  }

  private(set) var rejectedSelection = false

  static func option(for choice: TerminalChoice) -> Option {
    switch choice {
    case .terminal: .terminal
    case .ghostty: .ghostty
    case .custom: .other
    }
  }

  static func customApplicationName(for choice: TerminalChoice) -> String? {
    guard case .custom(let app) = choice else { return nil }
    return app.displayName
  }

  static func missing(choice: TerminalChoice, availability: TerminalAvailability?) -> Missing? {
    guard availability == .notFound else { return nil }
    switch choice {
    case .terminal: return .terminal
    case .ghostty: return .ghostty
    case .custom(let app): return .custom(name: app.displayName)
    }
  }

  mutating func apply(_ outcome: CustomSelectionOutcome) {
    rejectedSelection = outcome == .rejectedNotApplication
  }

  mutating func clearRejection() {
    rejectedSelection = false
  }
}
