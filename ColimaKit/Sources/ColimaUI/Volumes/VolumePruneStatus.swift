import ColimaCore
import SwiftUI

struct VolumePruneStatus: View {
  let store: VolumeStore
  let controller: VMController
  let pruneRequestResult: PruneRequestResult?

  private var showsNothingToPrune: Bool {
    pruneRequestResult == .nothingToPrune && store.pruneRequestError == nil
      && controller.isDockerReady && !store.isPruning && store.lastPruneReport == nil
  }

  var body: some View {
    PruneStatusStrip(
      isPruning: store.isPruning,
      runningText: LocalizedStringResource("Deleting unused volumes…", bundle: #bundle),
      requestError: store.pruneRequestError,
      outcome: store.lastPruneReport.map { PruneReportCard(report: $0) },
      showsNothingToPrune: showsNothingToPrune,
      nothingToPruneDetail: LocalizedStringResource("There are no unused volumes.", bundle: #bundle)
    )
  }
}

private struct PruneReportCard: View {
  let report: PruneReport

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            "Deleted \(report.deletedCount) volumes. Estimated space reclaimed: \(report.estimatedReclaimedBytes, format: .byteCount(style: .file)).",
            bundle: #bundle
          )
          if report.unknownSizeCount > 0 {
            Text("\(report.unknownSizeCount) volumes of unknown size are not included in the estimate.", bundle: #bundle)
              .foregroundStyle(.secondary)
          }
        }
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      if !report.failures.isEmpty {
        PruneFailureList(
          failures: report.failures.sorted { $0.key < $1.key }.map {
            (name: $0.key, message: $0.value)
          })
      }
    }
  }
}
