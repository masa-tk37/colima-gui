import Testing

@testable import ColimaCore

struct EngineGuidanceTests {
  private func instance(_ state: VMRunState) -> VMInstance {
    VMInstance(
      runState: state, arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30,
      runtime: "docker")
  }

  @Test func runningVMSuggestsRestartingIt() {
    let guidance = EngineGuidance(observation: .present(instance(.running)))
    #expect(guidance == .restartVM)
    #expect(guidance.message.contains("Restart the VM"))
  }

  @Test(arguments: ["Stopped", "Broken", ""])
  func stoppedVMSuggestsStartingIt(rawStatus: String) {
    let guidance = EngineGuidance(observation: .present(instance(.stopped(rawStatus: rawStatus))))
    #expect(guidance == .startVM)
    #expect(guidance.message.contains("Start the VM"))
    #expect(!guidance.message.contains("Restart"))
  }

  @Test func absentOrUnknownVMOnlyAsksToRetry() {
    for observation in [VMObservation.absent, .unknown(reason: "timeout")] {
      let guidance = EngineGuidance(observation: observation)
      #expect(guidance == .retryOnly)
      #expect(!guidance.message.contains("Start"))
    }
  }

  @Test func everyGuidanceStatesThatTheEngineIsUnreachable() {
    for guidance in [EngineGuidance.restartVM, .startVM, .retryOnly] {
      #expect(guidance.message.contains("Could not connect"))
    }
  }
}
