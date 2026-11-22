import ColimaCore
import ColimaProcess
import Foundation
import ServiceManagement

public enum AgentRegistration: Sendable, Equatable {
  case enabled
  /// The user turned the agent off in System Settings > General > Login Items & Extensions.
  case requiresApproval
  case notRegistered
  /// The plist is missing from the bundle or the signature does not match it.
  case notFound

  private static let registeredFingerprintKey = "registeredAgentFingerprint"

  private static var service: SMAppService { SMAppService.agent(plistName: AgentXPC.plistName) }

  public static var current: AgentRegistration { AgentRegistration(service.status) }

  /// launchd keeps running the binary it registered, so an agent registered by another build must be re-registered.
  public static var isFromAnotherBuild: Bool {
    UserDefaults.standard.string(forKey: registeredFingerprintKey) != bundledAgentFingerprint()
  }

  /// Re-registering after `.requiresApproval` would override the user's choice in System Settings.
  @discardableResult
  public static func registerIfNeeded() -> AgentRegistration {
    let status = current
    guard status == .notRegistered else { return status }
    do {
      try service.register()
      recordRegisteredBuild()
    } catch {
      ColimaLog.process.error(
        "agent registration failed: \(error.localizedDescription, privacy: .public)")
    }
    return current
  }

  /// Ends the running agent, so call it only once that agent is idle or cannot be reached.
  public static func reregister() async throws {
    try await service.unregister()
    try service.register()
    recordRegisteredBuild()
  }

  public static func colimaCommandIsRunning() async -> Bool {
    await AgentMain.colimaCommandIsRunning()
  }

  public init(_ status: SMAppService.Status) {
    switch status {
    case .enabled: self = .enabled
    case .requiresApproval: self = .requiresApproval
    case .notRegistered: self = .notRegistered
    case .notFound: self = .notFound
    @unknown default: self = .notFound
    }
  }

  private static func bundledAgentFingerprint() -> String? {
    Bundle.main.url(forAuxiliaryExecutable: "ColimaGUIAgent").flatMap(CodeSignature.cdhash(of:))
  }

  private static func recordRegisteredBuild() {
    UserDefaults.standard.set(bundledAgentFingerprint(), forKey: registeredFingerprintKey)
  }
}
