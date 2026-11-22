import Testing

@testable import ColimaCore

@Test func batchOutcomeKeepsSuccessesAlongsideFailures() {
  let ok = ContainerID(rawValue: "ok")
  let bad = ContainerID(rawValue: "bad")
  let outcome = BatchOutcome<ContainerID>(
    succeeded: [ok],
    failed: [bad: "conflict: container is busy"]
  )
  #expect(outcome.succeeded == [ok])
  #expect(outcome.failed[bad] == "conflict: container is busy")
  #expect(outcome.failed[ok] == nil)
}

@Test func batchOutcomeEquatesByContent() {
  let a = BatchOutcome<String>(succeeded: ["x"], failed: ["y": "boom"])
  #expect(a == BatchOutcome<String>(succeeded: ["x"], failed: ["y": "boom"]))
  #expect(a != BatchOutcome<String>(succeeded: ["x"], failed: ["y": "other"]))
}

@Test func pruneRequestResultCases() {
  #expect(PruneRequestResult.confirmationRequested != .nothingToPrune)
}

@Test func pruneReportCountsUnknownSizeSeparately() {
  let report = PruneReport(
    deletedSizes: [1_000, nil, 2_500, nil, nil],
    failures: ["busy_vol": "volume is in use"]
  )
  #expect(report.deletedCount == 5)
  #expect(report.estimatedReclaimedBytes == 3_500)
  #expect(report.unknownSizeCount == 3)
  #expect(report.failures == ["busy_vol": "volume is in use"])
}

@Test func pruneReportDoesNotTreatUnknownSizeAsZeroDeletedItem() {
  let report = PruneReport(deletedSizes: [nil], failures: [:])
  #expect(report.deletedCount == 1)
  #expect(report.estimatedReclaimedBytes == 0)
  #expect(report.unknownSizeCount == 1)
}

@Test func pruneReportWithOnlyFailuresDeletesNothing() {
  let report = PruneReport(deletedSizes: [], failures: ["a": "x", "b": "y"])
  #expect(report.deletedCount == 0)
  #expect(report.estimatedReclaimedBytes == 0)
  #expect(report.unknownSizeCount == 0)
  #expect(report.failures.count == 2)
}
