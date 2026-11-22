import ColimaCore
import Foundation

extension VMOperationKind {
  var label: String {
    switch self {
    case .start: String(localized: "Start", bundle: #bundle)
    case .stop: String(localized: "Stop", bundle: #bundle)
    case .restart: String(localized: "Restart", bundle: #bundle)
    case .create: String(localized: "Create", bundle: #bundle)
    case .recreate: String(localized: "Recreate", bundle: #bundle)
    }
  }

  var failureTitle: LocalizedStringResource {
    switch self {
    case .start: LocalizedStringResource("Couldn't start the VM", bundle: #bundle)
    case .stop: LocalizedStringResource("Couldn't stop the VM", bundle: #bundle)
    case .restart: LocalizedStringResource("Couldn't restart the VM", bundle: #bundle)
    case .create: LocalizedStringResource("Couldn't create the VM", bundle: #bundle)
    case .recreate: LocalizedStringResource("Couldn't recreate the VM", bundle: #bundle)
    }
  }
}

extension VMOperationStage {
  var label: String {
    switch self {
    case .preflight: String(localized: "Checking prerequisites", bundle: #bundle)
    case .starting: String(localized: "Starting VM", bundle: #bundle)
    case .stopping: String(localized: "Stopping VM", bundle: #bundle)
    case .deleting: String(localized: "Deleting VM", bundle: #bundle)
    case .creating: String(localized: "Creating VM", bundle: #bundle)
    }
  }
}
