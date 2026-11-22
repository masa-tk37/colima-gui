import ColimaCore
import SwiftUI

struct NetworkPruneStatus: View {
  let store: NetworkStore
  let controller: VMController
  let pruneRequestResult: PruneRequestResult?

  private var showsNothingToPrune: Bool {
    pruneRequestResult == .nothingToPrune && store.pruneRequestError == nil
      && controller.isDockerReady && !store.isPruning && store.lastPruneOutcome == nil
  }

  var body: some View {
    PruneStatusStrip(
      isPruning: store.isPruning,
      runningText: LocalizedStringResource("Deleting unused networks…", bundle: #bundle),
      requestError: store.pruneRequestError,
      outcome: store.lastPruneOutcome.map {
        PruneOutcomeCard(outcome: $0, networks: store.networks.value ?? [])
      },
      showsNothingToPrune: showsNothingToPrune,
      nothingToPruneDetail: LocalizedStringResource("There are no networks without a running container.", bundle: #bundle)
    )
  }
}

private struct PruneOutcomeCard: View {
  let outcome: BatchOutcome<NetworkID>
  let networks: [NetworkSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Deleted \(outcome.succeeded.count) networks.", bundle: #bundle)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      if !outcome.failed.isEmpty {
        PruneFailureList(
          failures: outcome.failed.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { (name: name(of: $0.key), message: $0.value) })
      }
    }
  }

  private func name(of id: NetworkID) -> String {
    networks.first { $0.id == id }?.name ?? id.rawValue
  }
}
