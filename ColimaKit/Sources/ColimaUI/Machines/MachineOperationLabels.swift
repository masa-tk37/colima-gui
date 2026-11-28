import ColimaCore
import Foundation

extension MachineOperationKind {
  var label: String {
    switch self {
    case .create: String(localized: "Create", bundle: #bundle)
    case .start: String(localized: "Start", bundle: #bundle)
    case .stop: String(localized: "Stop", bundle: #bundle)
    case .delete: String(localized: "Delete", bundle: #bundle)
    case .edit: String(localized: "Save changes", bundle: #bundle)
    }
  }

  var failureTitle: LocalizedStringResource {
    switch self {
    case .create: LocalizedStringResource("Couldn't create the machine", bundle: #bundle)
    case .start: LocalizedStringResource("Couldn't start the machine", bundle: #bundle)
    case .stop: LocalizedStringResource("Couldn't stop the machine", bundle: #bundle)
    case .delete: LocalizedStringResource("Couldn't delete the machine", bundle: #bundle)
    case .edit: LocalizedStringResource("Couldn't save the changes to the machine", bundle: #bundle)
    }
  }
}

extension MachineFailureCause {
  var message: String {
    switch self {
    case .exited(let code): String(localized: "limactl exited with code \(code)", bundle: #bundle)
    case .launchFailed(let reason): reason
    }
  }
}
