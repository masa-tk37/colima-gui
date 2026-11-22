import SwiftUI

/// VM settings are a sidebar screen (`VMSettingsView`), not here.
public struct AppSettingsView: View {
  @AppStorage(OperationLogWindow.opensOnStartKey) private var opensLogOnStart = false

  public init() {}

  public var body: some View {
    Form {
      Toggle(LocalizedStringResource("Open the operation log when a VM operation starts", bundle: #bundle), isOn: $opensLogOnStart)
      Text("colima's output is always available from Window › Operation log.", bundle: #bundle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }
}

#if DEBUG
  #Preview("App settings") {
    AppSettingsView()
  }
#endif
