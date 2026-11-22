import ColimaCore
import SwiftUI

struct AttachedNetworksSection: View {
  let networkNames: [String]

  var body: some View {
    Section {
      if networkNames.isEmpty {
        Text("No connected networks", bundle: #bundle)
          .foregroundStyle(.secondary)
      } else {
        ForEach(networkNames, id: \.self) { name in
          Label {
            Text(verbatim: name).textSelection(.enabled)
          } icon: {
            Image(systemName: "network").foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("Connected networks", bundle: #bundle)
    } footer: {
      Text("Disconnect from the Networks screen.", bundle: #bundle)
    }
  }
}

/// Reads `networks.networks` and leaves keeping it fresh to the screen that hosts the form.
struct ContainerNetworkConnectSection: View {
  private static let unconnectableNames: Set<String> = ["host", "none"]

  let container: ContainerSummary
  let networks: NetworkStore
  let slots: ContainerOperationSlots
  @State private var selection: NetworkID?
  @State private var isRefused: Bool

  init(
    container: ContainerSummary,
    networks: NetworkStore,
    slots: ContainerOperationSlots,
    initialSelection: NetworkID? = nil,
    isRefused: Bool = false
  ) {
    self.container = container
    self.networks = networks
    self.slots = slots
    _selection = State(initialValue: initialSelection)
    _isRefused = State(initialValue: isRefused)
  }

  var body: some View {
    let snapshot = networks.networks
    Section {
      if let all = snapshot.value {
        // The engine refuses to connect a container to `host` or `none` alongside other networks.
        targetControls(
          candidates: all.filter {
            !container.networkNames.contains($0.name) && !Self.unconnectableNames.contains($0.name)
          })
      } else if let error = snapshot.error {
        Label {
          Text("Couldn't load networks: \(error.displayMessage)", bundle: #bundle)
            .textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      } else {
        ProgressView(LocalizedStringResource("Loading networks…", bundle: #bundle)).controlSize(.small)
      }
      failures(names: snapshot.value ?? [])
    } header: {
      Text("Connect to network", bundle: #bundle)
    }
  }

  @ViewBuilder
  private func targetControls(candidates: [NetworkSummary]) -> some View {
    if candidates.isEmpty {
      Text("No networks available to connect", bundle: #bundle)
        .foregroundStyle(.secondary)
    } else {
      let target = candidates.first { $0.id == selection }?.id
      let isOperating = slots.isBusy(container.id)
      HStack {
        Picker(LocalizedStringResource("Network", bundle: #bundle), selection: targetBinding(current: target)) {
          Text("Choose…", bundle: #bundle).tag(NetworkID?.none)
          ForEach(candidates) { network in
            Text(verbatim: network.name).tag(NetworkID?.some(network.id))
          }
        }
        Button(LocalizedStringResource("Connect", bundle: #bundle)) { connect(to: target) }
          .disabled(target == nil || isOperating)
      }
      if isOperating {
        Label {
          Text("This container is busy", bundle: #bundle)
        } icon: {
          ProgressView().controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      if isRefused {
        Label(LocalizedStringResource("Couldn't start connecting. Docker is unavailable, or this container is busy with another operation.", bundle: #bundle),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }
    }
  }

  private func targetBinding(current: NetworkID?) -> Binding<NetworkID?> {
    Binding(
      get: { current },
      set: {
        selection = $0
        isRefused = false
      })
  }

  private func connect(to target: NetworkID?) {
    guard let target else { return }
    isRefused = !networks.connect(container: container.id, to: target)
  }

  @ViewBuilder
  private func failures(names: [NetworkSummary]) -> some View {
    let mine = networks.connectionFailures.filter { $0.key.container == container.id }
    ForEach(mine.keys.sorted { $0.network.rawValue < $1.network.rawValue }, id: \.self) { pair in
      let name = names.first { $0.id == pair.network }?.name ?? pair.network.rawValue
      Label {
        Text("Couldn't change the connection to network “\(name)”: \(mine[pair] ?? "")", bundle: #bundle)
          .textSelection(.enabled)
      } icon: {
        Image(systemName: "xmark.octagon.fill")
      }
      .font(.callout)
      .foregroundStyle(.red)
    }
  }
}
