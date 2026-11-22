import Testing

@testable import ColimaCore

@Test func parsesMemoryFromCapturedMeminfo() throws {
  let snapshot = try UsageFixture.procSnapshot("proc-sample-1")
  #expect(snapshot.memoryTotalBytes == 8_112_328 * 1024)
  #expect(snapshot.memoryUsedBytes == (8_112_328 - 7_538_788) * 1024)
}

@Test func cpuUsageBetweenCapturedSamplesExcludesIdleAndIOWait() throws {
  let first = try UsageFixture.procSnapshot("proc-sample-1")
  let second = try UsageFixture.procSnapshot("proc-sample-2")
  // busy delta = 481 (user+nice+system+irq+softirq+steal), idle+iowait delta = 3815.
  let percent = try #require(second.cpuPercent(since: first))
  #expect(abs(percent - 481.0 / 4296.0 * 100) < 1e-9)
}

@Test func firstSampleHasNoCPUUsage() throws {
  let first = try UsageFixture.procSnapshot("proc-sample-1")
  #expect(first.cpuPercent(since: nil) == nil)
}

@Test func decreasingCounterIsAGap() throws {
  let first = try UsageFixture.procSnapshot("proc-sample-1")
  let second = try UsageFixture.procSnapshot("proc-sample-2")
  #expect(first.cpuPercent(since: second) == nil)
}

@Test func unchangedCountersAreAGapNotADivisionByZero() throws {
  let first = try UsageFixture.procSnapshot("proc-sample-1")
  #expect(first.cpuPercent(since: first) == nil)
}

@Test func fullyBusyIntervalIsOneHundredPercent() throws {
  let a = try ProcSnapshot.parse(statText("cpu  10 0 10 100 0 0 0 0 0 0") + memText)
  let b = try ProcSnapshot.parse(statText("cpu  20 0 20 100 0 0 0 0 0 0") + memText)
  #expect(b.cpuPercent(since: a) == 100)
}

@Test func fullyIdleIntervalIsZeroPercent() throws {
  let a = try ProcSnapshot.parse(statText("cpu  10 0 10 100 5 0 0 0 0 0") + memText)
  let b = try ProcSnapshot.parse(statText("cpu  10 0 10 150 10 0 0 0 0 0") + memText)
  #expect(b.cpuPercent(since: a) == 0)
}

@Test func stealIrqAndSoftirqCountAsBusy() throws {
  let a = try ProcSnapshot.parse(statText("cpu  0 0 0 100 0 0 0 0 0 0") + memText)
  let b = try ProcSnapshot.parse(statText("cpu  0 0 0 100 0 10 10 20 0 0") + memText)
  #expect(b.cpuPercent(since: a) == 100)
}

@Test func guestCountersAreNotAddedTwice() throws {
  // guest and guest_nice (9th and 10th fields) are already inside user and nice.
  let a = try ProcSnapshot.parse(statText("cpu  0 0 0 100 0 0 0 0 0 0") + memText)
  let b = try ProcSnapshot.parse(statText("cpu  10 0 0 190 0 0 0 0 10 0") + memText)
  #expect(b.cpuPercent(since: a) == 10)
}

@Test func perCoreLinesAreNotTheAggregate() throws {
  let text = "cpu0 1 1 1 1 1 1 1 1\ncpu  5 0 5 90 0 0 0 0\n" + memText
  let a = try ProcSnapshot.parse(text)
  let b = try ProcSnapshot.parse("cpu  10 0 10 180 0 0 0 0\n" + memText)
  #expect(b.cpuPercent(since: a) == 10)
}

@Test func missingAggregateCPULineIsRejected() {
  #expect(throws: ProcParseError.missingCPULine) {
    try ProcSnapshot.parse("cpu0 1 1 1 1 1 1 1 1\n" + memText)
  }
}

@Test func tooFewOrNonNumericCPUFieldsAreRejected() {
  #expect(throws: ProcParseError.malformedCPULine) {
    try ProcSnapshot.parse("cpu  1 2 3\n" + memText)
  }
  #expect(throws: ProcParseError.malformedCPULine) {
    try ProcSnapshot.parse("cpu  1 2 x 4 5 6 7 8\n" + memText)
  }
}

@Test func missingMemoryFieldsAreRejected() {
  #expect(throws: ProcParseError.missingMemoryField("MemAvailable")) {
    try ProcSnapshot.parse(statText("cpu  1 1 1 1 1 1 1 1") + "MemTotal: 100 kB\n")
  }
  #expect(throws: ProcParseError.missingMemoryField("MemTotal")) {
    try ProcSnapshot.parse(statText("cpu  1 1 1 1 1 1 1 1") + "MemAvailable: 100 kB\n")
  }
}

@Test func malformedOrInconsistentMemoryFieldsAreRejected() {
  #expect(throws: ProcParseError.malformedMemoryField("MemTotal")) {
    try ProcSnapshot.parse(
      statText("cpu  1 1 1 1 1 1 1 1") + "MemTotal: abc kB\nMemAvailable: 1 kB\n")
  }
  #expect(throws: ProcParseError.malformedMemoryField("MemTotal")) {
    try ProcSnapshot.parse(
      statText("cpu  1 1 1 1 1 1 1 1") + "MemTotal: 100 MB\nMemAvailable: 1 kB\n")
  }
  #expect(throws: ProcParseError.malformedMemoryField("MemAvailable")) {
    try ProcSnapshot.parse(
      statText("cpu  1 1 1 1 1 1 1 1") + "MemTotal: 100 kB\nMemAvailable: 101 kB\n")
  }
}

@Test func emptyInputIsRejected() {
  #expect(throws: ProcParseError.missingCPULine) { try ProcSnapshot.parse("") }
}

private let memText = "MemTotal:        1000 kB\nMemAvailable:     400 kB\n"

private func statText(_ cpuLine: String) -> String { cpuLine + "\n" }
