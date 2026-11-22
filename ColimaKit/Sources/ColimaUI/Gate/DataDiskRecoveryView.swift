import ColimaCore
import SwiftUI

struct DataDiskRecoveryView: View {
  /// False once the delete-stage failure it would retry is no longer the last one.
  let canRetry: Bool
  let retryResult: RecreateRequestResult?
  let retry: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Label(LocalizedStringResource("A data disk may remain", bundle: #bundle), systemImage: "externaldrive")
          .font(.headline)
        Text(
          canRetry
            ? LocalizedStringResource("Creating the VM may reattach the remaining data disk. To avoid reattaching it, start over from the deletion step.", bundle: #bundle)
            : LocalizedStringResource("Creating the VM may reattach the remaining data disk.", bundle: #bundle)
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if canRetry {
          Button(LocalizedStringResource("Retry recreate from deletion", bundle: #bundle), action: retry)
        }
        if canRetry, let explanation = retryResult?.explanation {
          Label {
            Text(explanation)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }
    }
  }
}

extension RecreateRequestResult {
  var explanation: LocalizedStringResource? {
    switch self {
    case .confirmationRequested:
      nil
    case .rejected(.sameVMType):
      LocalizedStringResource("Can't retry: the target VM type is the same as the current one", bundle: #bundle)
    case .rejected(.missingExecutables(let type, let missing)):
      LocalizedStringResource(
        "Can't retry: the executables required for \(type.rawValue) were not found: \(missing.joined(separator: ", "))", bundle: #bundle)
    case .busy:
      LocalizedStringResource("Can't retry: another operation is running", bundle: #bundle)
    case .nothingToRetry:
      LocalizedStringResource("There is no recreate to retry", bundle: #bundle)
    }
  }
}
