import ColimaProcess
import Foundation

/// The agent sends codes only (it cannot load this package's localized strings); the app words them here.
enum AgentMessages {
  static func refusal(for registration: AgentRegistration) -> String? {
    switch registration {
    case .enabled:
      nil
    case .requiresApproval:
      String(
        localized:
          "The ColimaGUI background helper is turned off. Turn on ColimaGUI in System Settings > General > Login Items & Extensions, then retry.",
        bundle: #bundle)
    case .notRegistered, .notFound:
      String(
        localized:
          "The ColimaGUI background helper could not be registered. Reinstall ColimaGUI, then retry.",
        bundle: #bundle)
    }
  }

  static func rejected(_ reply: AgentStartReply, for target: AgentTarget = .colima) -> String {
    switch reply {
    case .accepted, .undecodableCommand:
      String(localized: "The background helper rejected the command.", bundle: #bundle)
    case .busy:
      busy(for: target)
    case .updating:
      String(
        localized: "The background helper is being updated. Retry in a moment.", bundle: #bundle)
    }
  }

  private static func busy(for target: AgentTarget) -> String {
    switch target {
    case .colima:
      String(
        localized:
          "Another colima command is still running in the background. Wait for it to finish, then retry.",
        bundle: #bundle)
    case .machine:
      String(
        localized:
          "Another operation is still running on this machine in the background. Wait for it to finish, then retry.",
        bundle: #bundle)
    }
  }

  static var helperStopped: String {
    String(
      localized:
        "The background helper stopped. The VM may still be changing state; check its status before retrying.",
      bundle: #bundle)
  }

  static var resultUnknown: String {
    String(
      localized:
        "The background helper did not confirm the command in time. It may or may not have run; check the VM status before retrying.",
      bundle: #bundle)
  }

  static var versionMismatch: String {
    String(
      localized:
        "The background helper belongs to a different version of ColimaGUI. Quit and reopen ColimaGUI, then retry.",
      bundle: #bundle)
  }
}
