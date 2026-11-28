import SwiftUI

struct MachineNoticeBannerView: View {
  let banner: MachineNoticeBanner
  let dismiss: () -> Void

  var body: some View {
    GroupBox {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(verbatim: banner.message).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
        Spacer(minLength: 0)
        DismissButton(action: dismiss)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .accessibilityElement(children: .contain)
  }
}

struct ShellFailureBannerView: View {
  let banner: ShellFailureBanner
  let dismiss: () -> Void
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label {
            Text(verbatim: banner.title).font(.headline)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Spacer(minLength: 0)
          DismissButton(action: dismiss)
        }
        Text(verbatim: banner.message).fixedSize(horizontal: false, vertical: true)
        if let detail = banner.detail {
          Text(verbatim: detail)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if banner.offersSettings {
          Button(LocalizedStringResource("Open Settings", bundle: #bundle)) { openSettings() }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .accessibilityElement(children: .contain)
  }
}

private struct DismissButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(LocalizedStringResource("Close", bundle: #bundle))
    .help(LocalizedStringResource("Close", bundle: #bundle))
  }
}
