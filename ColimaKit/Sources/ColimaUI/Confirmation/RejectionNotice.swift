import SwiftUI

struct RejectionNotice: View {
  let reason: String
  let close: () -> Void

  var body: some View {
    GroupBox {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(reason)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        Spacer(minLength: 0)
        Button(action: close) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(LocalizedStringResource("Close", bundle: #bundle))
        .help(LocalizedStringResource("Close", bundle: #bundle))
      }
    }
  }
}
