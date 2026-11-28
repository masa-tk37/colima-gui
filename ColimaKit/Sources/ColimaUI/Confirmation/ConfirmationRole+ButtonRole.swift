import ColimaCore
import SwiftUI

extension ConfirmationRole {
  var buttonRole: ButtonRole? {
    switch self {
    case .destructive: .destructive
    case .standard: nil
    }
  }
}
