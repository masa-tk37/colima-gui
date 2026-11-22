import Testing

@testable import ColimaCore

@Test func runningStatusMapsToRunning() {
  #expect(VMRunState(colimaStatus: "Running") == .running)
}

@Test(arguments: ["Stopped", "Broken", "Starting", "running", ""])
func nonRunningStatusKeepsOriginalString(raw: String) {
  #expect(VMRunState(colimaStatus: raw) == .stopped(rawStatus: raw))
}

@Test func brokenStatusIsRetrievableForDisplay() {
  let state = VMRunState(colimaStatus: "Broken")
  guard case .stopped(let raw) = state else {
    Issue.record("expected stopped, got \(state)")
    return
  }
  #expect(raw == "Broken")
  #expect(state.isRunning == false)
  #expect(VMRunState.running.isRunning)
}

@Test func presentObservationCarriesInstanceFields() {
  let instance = VMInstance(
    runState: .running,
    arch: "aarch64",
    cpus: 10,
    memoryBytes: 8_589_934_592,
    diskBytes: 107_374_182_400,
    runtime: "docker"
  )
  let observation = VMObservation.present(instance)
  #expect(observation == .present(instance))
  #expect(observation != .absent)
  #expect(instance.cpus == 10)
  #expect(instance.memoryBytes == 8_589_934_592)
  #expect(instance.diskBytes == 107_374_182_400)
}

@Test func unknownAndAbsentAreDistinct() {
  #expect(VMObservation.unknown(reason: "timed out") != .absent)
  #expect(VMObservation.unknown(reason: "a") != .unknown(reason: "b"))
}
