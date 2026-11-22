import ColimaCore
import SwiftUI

/// The failure stays on the controller until the next operation begins, so a screen hides it with `onDismiss` and its
/// own record of `failure.id`, never by clearing the controller.
public struct OperationFailureView: View {
  private let failure: VMOperationFailure
  private let onDismiss: (@MainActor () -> Void)?

  public init(failure: VMOperationFailure, onDismiss: (@MainActor () -> Void)? = nil) {
    self.failure = failure
    self.onDismiss = onDismiss
  }

  public var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Label {
            Text(failure.kind.failureTitle)
              .font(.headline)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          if let onDismiss {
            Spacer()
            Button(LocalizedStringResource("Dismiss failure", bundle: #bundle), systemImage: "xmark", action: onDismiss)
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help(LocalizedStringResource("Dismiss failure", bundle: #bundle))
          }
        }
        LabeledContent(LocalizedStringResource("Stage", bundle: #bundle), value: failure.stage.label)
        LabeledContent(LocalizedStringResource("Cause", bundle: #bundle)) {
          Text(failure.cause.message)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !failure.outputTail.isEmpty {
          FailureOutput(lines: failure.outputTail)
        }
        ShowOperationLogButton()
      }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct FailureOutput: View {
  let lines: [String]

  var body: some View {
    GroupBox(LocalizedStringResource("End of output", bundle: #bundle)) {
      ScrollView {
        Text(lines.joined(separator: "\n"))
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
    }
  }
}

extension VMFailureCause {
  var message: String {
    switch self {
    case .exited(let code):
      String(localized: "colima exited with code \(code)", bundle: #bundle)
    case .launchFailed(let reason):
      reason
    case .missingExecutables(let type, let missing):
      String(
        localized: "Required executables for \(type.rawValue) were not found: \(missing.joined(separator: ", "))",
        bundle: #bundle)
    case .stillPresentAfterDelete:
      String(localized: "The VM still exists after deletion", bundle: #bundle)
    case .deleteNotConfirmed:
      String(
        localized: "Deletion finished, but the VM could not be confirmed as gone", bundle: #bundle)
    case .stopNotConfirmed:
      String(
        localized: "Stop finished, but the VM could not be confirmed as stopped", bundle: #bundle)
    case .aborted:
      String(
        localized: "The operation was aborted. The VM may be left in an intermediate state.",
        bundle: #bundle)
    }
  }
}
