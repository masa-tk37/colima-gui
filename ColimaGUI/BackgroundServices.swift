import ColimaAdapters
import ColimaCore
import Foundation
import ServiceManagement
import os

/// Runs off the main actor: reading the bundled agent's signature hashes it from disk.
nonisolated enum BackgroundServices {
  private static let loginItemRegisteredKey = "loginItemRegistered"
  private static let agentUpdateRetryInterval: Duration = .seconds(30)

  @concurrent static func register(agent: AgentClient) async {
    registerLoginItemOnce()
    await registerAgent(agent)
  }

  /// The flag is saved only once registration is confirmed, so a user who later disables the item is left alone.
  private static func registerLoginItemOnce() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: loginItemRegisteredKey) else { return }
    let app = SMAppService.mainApp
    if app.status == .notRegistered {
      do {
        try app.register()
      } catch {
        ColimaLog.vm.error(
          "login item registration failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    if app.status == .enabled || app.status == .requiresApproval {
      defaults.set(true, forKey: loginItemRegisteredKey)
    }
  }

  private static func registerAgent(_ agent: AgentClient) async {
    switch AgentRegistration.current {
    case .notRegistered:
      AgentRegistration.registerIfNeeded()
    case .enabled where AgentRegistration.isFromAnotherBuild:
      await replaceAgent(agent)
    case .notFound:
      ColimaLog.vm.error("agent plist not found in the app bundle or its signature does not match")
    case .enabled, .requiresApproval:
      break
    }
  }

  /// Registration runs once per launch, so a postponed or failed update is retried here instead of waiting for a
  /// relaunch.
  private static func replaceAgent(_ agent: AgentClient) async {
    var loggedPostponement = false
    var loggedFailure = false
    while AgentRegistration.current == .enabled, AgentRegistration.isFromAnotherBuild {
      if await AgentRegistration.shouldDeferReplacement(readiness: await agent.prepareForUpdate()) {
        if !loggedPostponement {
          ColimaLog.vm.info("agent update postponed: a VM or machine command is still running")
          loggedPostponement = true
        }
      } else {
        do {
          try await AgentRegistration.reregister()
          ColimaLog.vm.info("agent re-registered for this build")
          return
        } catch {
          if !loggedFailure {
            ColimaLog.vm.error("agent update failed: \(error.localizedDescription, privacy: .public)")
            loggedFailure = true
          }
        }
      }
      do { try await Task.sleep(for: agentUpdateRetryInterval) } catch { return }
    }
  }
}
