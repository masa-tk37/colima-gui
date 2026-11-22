import ColimaCore
import SwiftUI

/// A disconnect raises `store.pendingConfirmation`; `NetworkListView` presents it.
struct NetworkDetailView: View {
  let store: NetworkStore
  let controller: VMController
  let summary: NetworkSummary
  @State private var refusedContainers: Set<ContainerID> = []

  var body: some View {
    Form {
      Section(LocalizedStringResource("Overview", bundle: #bundle)) {
        LabeledContent(LocalizedStringResource("Name", bundle: #bundle)) { Text(verbatim: summary.name).textSelection(.enabled) }
        LabeledContent(LocalizedStringResource("Driver", bundle: #bundle)) { Text(verbatim: summary.driver).textSelection(.enabled) }
        LabeledContent(LocalizedStringResource("Scope", bundle: #bundle)) { Text(verbatim: summary.scope).textSelection(.enabled) }
        if summary.ipam.isEmpty {
          LabeledContent(LocalizedStringResource("Subnet", bundle: #bundle)) { noValue }
          LabeledContent(LocalizedStringResource("Gateway", bundle: #bundle)) { noValue }
        } else {
          ForEach(Array(summary.ipam.enumerated()), id: \.offset) { _, config in
            LabeledContent(LocalizedStringResource("Subnet", bundle: #bundle)) { value(config.subnet) }
            LabeledContent(LocalizedStringResource("Gateway", bundle: #bundle)) { value(config.gateway) }
          }
        }
        if !store.canDelete(summary) {
          Label(LocalizedStringResource("Built-in networks can't be deleted.", bundle: #bundle), systemImage: "lock")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Section(LocalizedStringResource("Connected containers", bundle: #bundle)) {
        containers
      }
    }
    .formStyle(.grouped)
    .navigationTitle(summary.name)
  }

  @ViewBuilder
  private var containers: some View {
    if let detail = store.detail.value {
      if let error = store.detail.error {
        Label {
          Text("Couldn't refresh: \(error.displayMessage)", bundle: #bundle).textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
      }
      if detail.containers.isEmpty {
        Text("No connected containers", bundle: #bundle)
          .foregroundStyle(.secondary)
      } else {
        ForEach(detail.containers) { container in
          row(container)
        }
      }
    } else if let error = store.detail.error {
      Label {
        Text("Couldn't load connected containers: \(error.displayMessage)", bundle: #bundle).textSelection(.enabled)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    } else {
      ProgressView(LocalizedStringResource("Loading…", bundle: #bundle)).controlSize(.small)
    }
  }

  private func row(_ container: NetworkContainer) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Label {
          Text(verbatim: container.name)
            .fontWeight(.medium)
            .textSelection(.enabled)
        } icon: {
          Image(systemName: "shippingbox").foregroundStyle(.secondary)
        }
        Spacer()
        Button(LocalizedStringResource("Disconnect", bundle: #bundle), systemImage: "network.slash") { disconnect(container) }
          .controlSize(.small)
          .disabled(!controller.isDockerReady)
          .help(LocalizedStringResource("Disconnect “\(container.name)” from this network", bundle: #bundle))
      }
      address("IPv4", container.ipv4Address)
      address("IPv6", container.ipv6Address)
      if refusedContainers.contains(container.id) {
        Text("Can't disconnect: this container is running another operation.", bundle: #bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let message = store.connectionFailures[
        NetworkMembership(container: container.id, network: summary.id)]
      {
        Label {
          Text("Couldn't disconnect: \(message)", bundle: #bundle).textSelection(.enabled)
        } icon: {
          Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
        .font(.caption)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
  }

  private func disconnect(_ container: NetworkContainer) {
    let accepted = store.requestDisconnect(container: container.id, from: summary.id)
    if accepted {
      refusedContainers.remove(container.id)
    } else {
      refusedContainers.insert(container.id)
    }
  }

  /// The engine reports addresses with their prefix length (`172.20.0.2/16`), shown as given.
  private func address(_ label: String, _ value: String?) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: label)
        .foregroundStyle(.secondary)
        .frame(width: 34, alignment: .leading)
      if let value {
        Text(verbatim: value)
          .monospaced()
          .textSelection(.enabled)
      } else {
        Text(verbatim: "—")
          .foregroundStyle(.secondary)
          .accessibilityLabel(LocalizedStringResource("None", bundle: #bundle))
      }
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func value(_ text: String?) -> some View {
    if let text {
      Text(verbatim: text).monospaced().textSelection(.enabled)
    } else {
      noValue
    }
  }

  private var noValue: some View {
    Text(verbatim: "—")
      .foregroundStyle(.secondary)
      .accessibilityLabel(LocalizedStringResource("None", bundle: #bundle))
  }
}
