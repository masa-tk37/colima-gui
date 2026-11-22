import ColimaCore
import SwiftUI

struct VMStatusSummary: View {
  /// Colima omits a field it cannot determine, and the decoder maps that to an empty string or 0.
  private static let unknownValue = "—"

  let controller: VMController
  let refresh: @MainActor () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      StateHeading(appearance: StateAppearance(displayState: controller.displayState, observation: controller.observation))
      switch controller.observation {
      case .present(let instance):
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
          SpecTile(LocalizedStringResource("CPU", bundle: #bundle), systemImage: "cpu", value: cpus(instance))
          SpecTile(LocalizedStringResource("Memory", bundle: #bundle), systemImage: "memorychip", value: bytes(instance.memoryBytes))
          SpecTile(LocalizedStringResource("Disk", bundle: #bundle), systemImage: "internaldrive", value: bytes(instance.diskBytes))
          SpecTile(LocalizedStringResource("Architecture", bundle: #bundle), systemImage: "square.grid.3x3", value: text(instance.arch))
          SpecTile(LocalizedStringResource("Runtime", bundle: #bundle), systemImage: "shippingbox", value: text(instance.runtime))
        }
      case .absent:
        Text("The VM hasn't been created yet.", bundle: #bundle)
          .foregroundStyle(.secondary)
      case .unknown(let reason):
        Text(verbatim: reason)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if controller.activeOperation == nil {
          Button(LocalizedStringResource("Retry", bundle: #bundle)) { Task { await refresh() } }
        }
      }
    }
  }

  private func cpus(_ instance: VMInstance) -> String {
    instance.cpus > 0 ? String(localized: "\(instance.cpus) cores", bundle: #bundle) : Self.unknownValue
  }

  /// Binary units: the settings are entered in GiB, so decimal GB would not match them.
  private func bytes(_ value: Int64) -> String {
    value > 0 ? value.formatted(.byteCount(style: .memory)) : Self.unknownValue
  }

  private func text(_ value: String) -> String {
    value.isEmpty ? Self.unknownValue : value
  }
}

private struct StateHeading: View {
  let appearance: StateAppearance

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if appearance.isTransitioning {
          ProgressView().controlSize(.regular)
        } else {
          Image(systemName: appearance.systemImage)
            .font(.system(size: 28))
            .foregroundStyle(appearance.tint)
        }
      }
      .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 0) {
        Text("Status", bundle: #bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(appearance.title)
          .font(.title2.weight(.semibold))
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct SpecTile: View {
  let title: LocalizedStringResource
  let systemImage: String
  let value: String

  init(_ title: LocalizedStringResource, systemImage: String, value: String) {
    self.title = title
    self.systemImage = systemImage
    self.value = value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(verbatim: value)
        .font(.title3.weight(.medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
  }
}

struct StateAppearance {
  let title: LocalizedStringResource
  let systemImage: String
  let tint: Color
  let isTransitioning: Bool

  init(displayState: VMDisplayState, observation: VMObservation) {
    switch displayState {
    case .starting:
      self.init(LocalizedStringResource("Starting", bundle: #bundle), "play.circle", .orange, isTransitioning: true)
    case .stopping:
      self.init(LocalizedStringResource("Stopping", bundle: #bundle), "stop.circle", .orange, isTransitioning: true)
    case .running:
      self.init(LocalizedStringResource("Running", bundle: #bundle), "checkmark.circle.fill", .green)
    case .stopped:
      switch observation {
      case .present(let instance) where instance.runState.isBroken:
        self.init(LocalizedStringResource("Broken", bundle: #bundle), "exclamationmark.triangle.fill", .red)
      case .present:
        self.init(LocalizedStringResource("Stopped", bundle: #bundle), "pause.circle", .secondary)
      case .absent:
        self.init(LocalizedStringResource("Not created", bundle: #bundle), "shippingbox", .secondary)
      case .unknown:
        self.init(LocalizedStringResource("Unknown", bundle: #bundle), "questionmark.circle", .secondary)
      }
    }
  }

  private init(
    _ title: LocalizedStringResource, _ systemImage: String, _ tint: Color, isTransitioning: Bool = false
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.isTransitioning = isTransitioning
  }
}
