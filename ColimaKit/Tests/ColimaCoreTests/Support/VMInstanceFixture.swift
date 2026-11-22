@testable import ColimaCore

func instance(running: Bool) -> VMInstance {
  VMInstance(
    runState: running ? .running : .stopped(rawStatus: "Stopped"),
    arch: "aarch64", cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30, runtime: "docker"
  )
}
