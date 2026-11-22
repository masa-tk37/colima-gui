#if DEBUG
  import ColimaCore
  import Foundation
  import Synchronization

  final class PreviewClock: Sendable {
    private let offset = Mutex<TimeInterval>(0)

    func shift(secondsAgo seconds: TimeInterval) {
      offset.withLock { $0 = seconds }
    }

    func now() -> Date {
      Date().addingTimeInterval(-offset.withLock { $0 })
    }
  }

  enum PreviewVMData {
    static func instance(running: Bool) -> VMInstance {
      instance(runState: running ? .running : .stopped(rawStatus: "Stopped"))
    }

    static func instance(rawStatus: String) -> VMInstance {
      instance(runState: VMRunState(colimaStatus: rawStatus))
    }

    private static func instance(runState: VMRunState) -> VMInstance {
      VMInstance(
        runState: runState, arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30,
        runtime: "docker")
    }

    static let startOutput = [
      "level=info msg=\"starting colima\"",
      "level=info msg=\"starting ...\" context=vm",
      "level=info msg=\"waiting for the VM to be ready\" context=vm",
    ]
    static let stopOutput = [
      "level=info msg=\"stopping colima\"",
      "level=info msg=\"stopping ...\" context=docker",
    ]
    static let createOutput = [
      "level=info msg=\"starting colima\"",
      "level=info msg=\"downloading disk image\" context=vm",
      "level=info msg=\"provisioning ...\" context=docker",
    ]
    static let startFailureOutput = [
      "level=info msg=\"starting colima\"",
      "level=info msg=\"starting ...\" context=vm",
      "level=fatal msg=\"error starting vm: error at 'starting': exit status 1\"",
    ]
    static let createFailureOutput = [
      "level=info msg=\"starting colima\"",
      "level=info msg=\"downloading disk image\" context=vm",
      "level=fatal msg=\"error creating vm: download failed: network is unreachable\"",
    ]
    static let deleteFailureOutput = [
      "level=info msg=\"deleting colima\"",
      "level=fatal msg=\"error deleting vm: instance directory is in use\"",
    ]
  }
#endif
