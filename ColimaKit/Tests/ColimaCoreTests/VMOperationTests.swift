import Foundation
import Testing

@testable import ColimaCore

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

private func progress(
  _ kind: VMOperationKind = .start,
  _ stage: VMOperationStage = .starting,
  stageStartedAt: Date = t0
) -> VMOperationProgress {
  VMOperationProgress(kind: kind, stage: stage, startedAt: t0, stageStartedAt: stageStartedAt)
}

private func instance(_ state: VMRunState) -> VMInstance {
  VMInstance(
    runState: state, arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30,
    runtime: "docker")
}

@Test(arguments: [VMOperationStage.starting, .stopping, .creating])
func abortIsUnavailableBeforeThreeMinutes(stage: VMOperationStage) {
  let p = progress(.start, stage)
  #expect(!p.isAbortAvailable(at: t0))
  #expect(!p.isAbortAvailable(at: t0.addingTimeInterval(179.9)))
}

@Test(arguments: [VMOperationStage.starting, .stopping, .creating])
func abortIsAvailableFromThreeMinutesOnChildProcessStages(stage: VMOperationStage) {
  let p = progress(.start, stage)
  #expect(p.isAbortAvailable(at: t0.addingTimeInterval(180)))
  #expect(p.isAbortAvailable(at: t0.addingTimeInterval(3_600)))
}

@Test(arguments: [VMOperationStage.deleting, .preflight])
func abortIsNeverAvailableOnDeletingOrPreflight(stage: VMOperationStage) {
  let p = progress(.recreate, stage)
  #expect(!p.isAbortAvailable(at: t0.addingTimeInterval(180)))
  #expect(!p.isAbortAvailable(at: t0.addingTimeInterval(86_400)))
}

@Test func abortWindowIsMeasuredFromTheStageStartNotTheOperationStart() {
  var p = progress(.restart, .stopping)
  let stageStart = t0.addingTimeInterval(200)
  p.advance(to: .starting, at: stageStart)
  #expect(p.startedAt == t0)
  #expect(p.stageStartedAt == stageStart)
  #expect(!p.isAbortAvailable(at: stageStart.addingTimeInterval(179)))
  #expect(p.isAbortAvailable(at: stageStart.addingTimeInterval(180)))
}

@Test func notingOutputRecordsTheLastOutputTime() {
  var p = progress()
  #expect(p.lastOutputAt == nil)
  p.noteOutput(at: t0.addingTimeInterval(5))
  p.noteOutput(at: t0.addingTimeInterval(9))
  #expect(p.lastOutputAt == t0.addingTimeInterval(9))
}

@Test func advancingKeepsTheLastOutputTime() {
  var p = progress(.recreate, .deleting)
  p.noteOutput(at: t0.addingTimeInterval(1))
  p.advance(to: .creating, at: t0.addingTimeInterval(10))
  #expect(p.stage == .creating)
  #expect(p.lastOutputAt == t0.addingTimeInterval(1))
}

@Test func failureKeepsOnlyTheLastFiftyOutputLines() {
  let lines = (0..<80).map { "l\($0)" }
  let failure = VMOperationFailure(
    kind: .create, stage: .creating, cause: .exited(code: 1), outputLines: lines
  )
  #expect(failure.outputTail.count == 50)
  #expect(failure.outputTail.first == "l30")
  #expect(failure.outputTail.last == "l79")
}

@Test func failureCarriesKindStageAndCause() {
  let failure = VMOperationFailure(
    kind: .recreate, stage: .deleting, cause: .stillPresentAfterDelete, outputLines: ["x"]
  )
  #expect(failure.kind == .recreate)
  #expect(failure.stage == .deleting)
  #expect(failure.cause == .stillPresentAfterDelete)
  #expect(failure.outputTail == ["x"])
}

@Test func eachFailureGetsItsOwnIdentityEvenWithIdenticalContent() {
  let first = VMOperationFailure(
    kind: .start, stage: .starting, cause: .exited(code: 1), outputLines: ["x"])
  let second = VMOperationFailure(
    kind: .start, stage: .starting, cause: .exited(code: 1), outputLines: ["x"])
  #expect(first.id != second.id)
  #expect(first == second)
}

@Test func withoutAnOperationTheObservationDecidesTheDisplayState() {
  #expect(
    VMDisplayState(observation: .present(instance(.running)), activeOperation: nil) == .running)
  #expect(
    VMDisplayState(
      observation: .present(instance(.stopped(rawStatus: "Stopped"))), activeOperation: nil)
      == .stopped)
  #expect(
    VMDisplayState(
      observation: .present(instance(.stopped(rawStatus: "Broken"))), activeOperation: nil)
      == .stopped)
  #expect(VMDisplayState(observation: .absent, activeOperation: nil) == .stopped)
  #expect(VMDisplayState(observation: .unknown(reason: "x"), activeOperation: nil) == .stopped)
}

@Test(arguments: [
  (VMOperationKind.start, VMOperationStage.starting, VMDisplayState.starting),
  (.create, .preflight, .starting),
  (.create, .creating, .starting),
  (.stop, .stopping, .stopping),
  (.restart, .stopping, .stopping),
  (.restart, .starting, .starting),
  (.recreate, .preflight, .stopping),
  (.recreate, .deleting, .stopping),
  (.recreate, .creating, .starting),
])
func operationStageTakesPrecedenceOverTheObservation(
  kind: VMOperationKind, stage: VMOperationStage, expected: VMDisplayState
) {
  let active = progress(kind, stage)
  for observation in [
    VMObservation.present(instance(.running)),
    .present(instance(.stopped(rawStatus: "Stopped"))),
    .absent,
    .unknown(reason: "x"),
  ] {
    #expect(VMDisplayState(observation: observation, activeOperation: active) == expected)
  }
}
