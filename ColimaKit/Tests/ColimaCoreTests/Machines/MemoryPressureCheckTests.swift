import Testing

@testable import ColimaCore

@Suite("MemoryPressureCheck")
struct MemoryPressureCheckTests {
  private static let gib: Int64 = 1 << 30
  private static let physical: Int64 = 16 * gib

  private func instance(running: Bool, memoryGiB: Int64) -> VMInstance {
    VMInstance(
      runState: running ? .running : .stopped(rawStatus: "Stopped"), arch: "aarch64", cpus: 2,
      memoryBytes: memoryGiB * Self.gib, diskBytes: 60 * Self.gib, runtime: "docker")
  }

  private func spec(memoryGiB: Double) -> VMCreateSpec {
    VMCreateSpec(
      resources: VMResourceSettings(cpus: 2, memoryGiB: memoryGiB, diskGiB: 60), vmType: .vz)
  }

  @Test func thresholdIsThreeQuartersOfPhysicalMemory() {
    #expect(MemoryPressureCheck.thresholdBytes(physicalBytes: Self.physical) == 12_884_901_888)
  }

  @Test func thresholdRoundsDown() {
    #expect(MemoryPressureCheck.thresholdBytes(physicalBytes: 10) == 7)
    #expect(MemoryPressureCheck.thresholdBytes(physicalBytes: 11) == 8)
  }

  @Test func totalExactlyAtTheThresholdDoesNotWarn() {
    let warning = MemoryPressureCheck.evaluate(
      defaultVMBytes: 8 * Self.gib, otherMachineBytes: [], targetBytes: 4 * Self.gib,
      physicalBytes: Self.physical)
    #expect(warning == nil)
  }

  @Test func oneByteOverTheThresholdWarnsWithTheThreeFigures() {
    let warning = MemoryPressureCheck.evaluate(
      defaultVMBytes: 8 * Self.gib, otherMachineBytes: [], targetBytes: 4 * Self.gib + 1,
      physicalBytes: Self.physical)
    #expect(
      warning
        == MemoryWarning(
          totalBytes: 12_884_901_889, physicalBytes: Self.physical, thresholdBytes: 12_884_901_888)
    )
  }

  @Test func aSecondFourGiBMachineWarns() {
    let warning = MemoryPressureCheck.evaluate(
      defaultVMBytes: 8 * Self.gib, otherMachineBytes: [4 * Self.gib], targetBytes: 4 * Self.gib,
      physicalBytes: Self.physical)
    #expect(warning?.totalBytes == 16 * Self.gib)
    #expect(warning?.physicalBytes == Self.physical)
    #expect(warning?.thresholdBytes == 12_884_901_888)
  }

  @Test func absentDefaultVMAddsNothingToTheTotal() {
    let warning = MemoryPressureCheck.evaluate(
      defaultVMBytes: nil, otherMachineBytes: [4 * Self.gib], targetBytes: 4 * Self.gib,
      physicalBytes: Self.physical)
    #expect(warning == nil)
  }

  @Test func runningDefaultVMWithNoOperationCounts() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: nil, observation: .present(instance(running: true, memoryGiB: 8)),
      createSpec: nil)
    #expect(bytes == 8 * Self.gib)
  }

  @Test(arguments: [
    VMObservation.absent, .unknown(reason: "x"),
    .present(VMInstance(
      runState: .stopped(rawStatus: "Stopped"), arch: "aarch64", cpus: 2, memoryBytes: 8 << 30,
      diskBytes: 60 << 30, runtime: "docker")),
  ])
  func stoppedAbsentOrUnknownDefaultVMWithNoOperationIsNotCounted(observation: VMObservation) {
    #expect(
      MemoryPressureCheck.defaultVMBytes(
        operationKind: nil, observation: observation, createSpec: nil) == nil)
  }

  @Test func startCountsAPresentVMEvenWhileStopped() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: .start, observation: .present(instance(running: false, memoryGiB: 8)),
      createSpec: nil)
    #expect(bytes == 8 * Self.gib)
  }

  @Test func restartCountsAPresentVMWhileItsStopStageObservesStopped() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: .restart, observation: .present(instance(running: false, memoryGiB: 8)),
      createSpec: nil)
    #expect(bytes == 8 * Self.gib)
  }

  @Test(arguments: [VMOperationKind.start, .restart])
  func startAndRestartAddNothingWhenTheVMIsNotPresent(kind: VMOperationKind) {
    #expect(
      MemoryPressureCheck.defaultVMBytes(
        operationKind: kind, observation: .absent, createSpec: nil) == nil)
    #expect(
      MemoryPressureCheck.defaultVMBytes(
        operationKind: kind, observation: .unknown(reason: "x"), createSpec: nil) == nil)
  }

  @Test func stopCountsARunningVMUntilStopIsObserved() {
    let running = MemoryPressureCheck.defaultVMBytes(
      operationKind: .stop, observation: .present(instance(running: true, memoryGiB: 8)),
      createSpec: nil)
    let stopped = MemoryPressureCheck.defaultVMBytes(
      operationKind: .stop, observation: .present(instance(running: false, memoryGiB: 8)),
      createSpec: nil)
    #expect(running == 8 * Self.gib)
    #expect(stopped == nil)
  }

  @Test func createCountsTheSpecMemoryWhileObservationIsAbsent() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: .create, observation: .absent, createSpec: spec(memoryGiB: 6))
    #expect(bytes == 6 * Self.gib)
  }

  @Test func recreateCountsTheNewSpecNotTheOldObservedValue() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: .recreate, observation: .present(instance(running: true, memoryGiB: 8)),
      createSpec: spec(memoryGiB: 2))
    #expect(bytes == 2 * Self.gib)
  }

  @Test func fractionalSpecMemoryConvertsToBytes() {
    let bytes = MemoryPressureCheck.defaultVMBytes(
      operationKind: .create, observation: .absent, createSpec: spec(memoryGiB: 1.5))
    #expect(bytes == 3 * (Self.gib / 2))
  }

  @Test(arguments: [VMOperationKind.create, .recreate])
  func createOrRecreateWithoutASpecAddsNothing(kind: VMOperationKind) {
    #expect(
      MemoryPressureCheck.defaultVMBytes(
        operationKind: kind, observation: .present(instance(running: true, memoryGiB: 8)),
        createSpec: nil) == nil)
  }
}
