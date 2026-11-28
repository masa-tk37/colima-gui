import Foundation
import Testing

@testable import ColimaCore

@Suite("MachineOperation values")
struct MachineOperationTests {
  private func name(_ text: String) -> MachineName {
    guard case .success(let name) = MachineName.parse(text, limaHomeUTF8Count: 21) else {
      fatalError("invalid test name \(text)")
    }
    return name
  }

  @Test func operationKindsAreTheFiveMachineCommands() {
    #expect(MachineOperationKind.create.rawValue == "create")
    #expect(MachineOperationKind.start.rawValue == "start")
    #expect(MachineOperationKind.stop.rawValue == "stop")
    #expect(MachineOperationKind.delete.rawValue == "delete")
    #expect(MachineOperationKind.edit.rawValue == "edit")
  }

  @Test func progressStartsWithoutACancelRequestAndRecordsOne() {
    var progress = MachineOperationProgress(kind: .create, origin: .thisSession(startedAt: Date(timeIntervalSince1970: 1)))
    #expect(!progress.cancelRequested)
    progress.cancelRequested = true
    #expect(progress.cancelRequested)
    #expect(progress.kind == .create)
  }

  @Test func progressFromAnEarlierSessionKeepsItsRunID() {
    let runID = UUID()
    let progress = MachineOperationProgress(kind: .start, origin: .earlierSession(runID: runID))
    #expect(progress.origin == .earlierSession(runID: runID))
  }

  @Test func failureKeepsOnlyTheLast50OutputLinesUnchanged() {
    let lines = (0..<80).map { "line \($0)" }
    let failure = MachineOperationFailure(
      name: name("dev"), kind: .create, cause: .exited(code: 1), outputLines: lines)
    #expect(failure.outputTail.count == 50)
    #expect(failure.outputTail.first == "line 30")
    #expect(failure.outputTail.last == "line 79")
  }

  @Test func failureKeepsAShortOutputWhole() {
    let failure = MachineOperationFailure(
      name: name("dev"), kind: .stop, cause: .launchFailed(reason: "no agent"), outputLines: ["a", "b"])
    #expect(failure.outputTail == ["a", "b"])
  }

  @Test func failuresDifferInIdentityButCompareByContent() {
    let first = MachineOperationFailure(name: name("dev"), kind: .delete, cause: .exited(code: 2), outputLines: ["x"])
    let second = MachineOperationFailure(name: name("dev"), kind: .delete, cause: .exited(code: 2), outputLines: ["x"])
    #expect(first.id != second.id)
    #expect(first == second)
    let other = MachineOperationFailure(name: name("dev"), kind: .delete, cause: .exited(code: 3), outputLines: ["x"])
    #expect(first != other)
  }

  @Test func noticesCarryTheMachineName() {
    #expect(MachineNotice.editSaved(name("dev")) != MachineNotice.createCancelled(name("dev")))
    #expect(MachineNotice.createCancelled(name("dev")) == MachineNotice.createCancelled(name("dev")))
  }
}

@MainActor
@Suite("MachineOperationRecord")
struct MachineOperationRecordTests {
  private let start = Date(timeIntervalSince1970: 100)

  @Test func startsEmptyWithoutAnOutcome() {
    let record = MachineOperationRecord(kind: .create, startedAt: start)
    #expect(record.kind == .create)
    #expect(record.startedAt == start)
    #expect(record.lines.isEmpty)
    #expect(record.outcome == nil)
    #expect(record.endedAt == nil)
  }

  @Test func appendNumbersLinesFromZero() {
    let record = MachineOperationRecord(kind: .start, startedAt: start)
    record.append("a")
    record.append("b")
    #expect(record.lines.map(\.number) == [0, 1])
    #expect(record.texts == ["a", "b"])
  }

  @Test func dropsOldestLinesAtTheLimitAndKeepsLineNumbers() {
    let record = MachineOperationRecord(kind: .create, startedAt: start)
    let total = MachineOperationRecord.lineLimit + 5
    for index in 0..<total { record.append("line \(index)") }
    #expect(MachineOperationRecord.lineLimit == 2_000)
    #expect(record.lines.count == MachineOperationRecord.lineLimit)
    #expect(record.lines.first?.number == 5)
    #expect(record.lines.first?.text == "line 5")
    #expect(record.lines.last?.number == total - 1)
    #expect(record.lines.map(\.id) == Array(5..<total))
  }

  @Test func endRecordsTheOutcomeAndTime() {
    let record = MachineOperationRecord(kind: .create, startedAt: start)
    let end = Date(timeIntervalSince1970: 160)
    record.end(.cancelled, at: end)
    #expect(record.outcome == .cancelled)
    #expect(record.endedAt == end)
  }

  @Test func recordsHaveDistinctIdentities() {
    let first = MachineOperationRecord(kind: .stop, startedAt: start)
    let second = MachineOperationRecord(kind: .stop, startedAt: start)
    #expect(first.id != second.id)
  }
}
