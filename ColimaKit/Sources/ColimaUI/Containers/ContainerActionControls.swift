import SwiftUI

/// The system's bordered circle sizes itself to the symbol and leaves almost no margin.
struct CircleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize

  func makeBody(configuration: Configuration) -> some View {
    let isSmall = controlSize == .small || controlSize == .mini
    let tint: Color = configuration.role == .destructive ? .red : .primary
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: isSmall ? 9 : 11, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: isSmall ? 22 : 28, height: isSmall ? 22 : 28)
      .background(.fill.tertiary, in: .circle)
      .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
      .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
      .contentShape(.circle)
  }
}

struct CircleActionButton: View {
  let title: LocalizedStringResource
  let systemImage: String
  var role: ButtonRole?
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(title, systemImage: systemImage, role: role, action: action)
      .buttonStyle(CircleButtonStyle())
      .disabled(!isEnabled)
      .help(title)
  }
}
