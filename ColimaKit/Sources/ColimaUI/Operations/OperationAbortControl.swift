import SwiftUI

struct OperationAbortControl: View {
  let abort: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(LocalizedStringResource("Abort", bundle: #bundle), role: .destructive) { abort() }
      Text("Terminates the Colima process. The VM may be left in an intermediate state.", bundle: #bundle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
