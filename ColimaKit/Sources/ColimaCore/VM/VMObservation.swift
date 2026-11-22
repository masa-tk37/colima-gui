public enum VMRunState: Sendable, Equatable {
  case running
  case stopped(rawStatus: String)

  public init(colimaStatus: String) {
    self = colimaStatus == "Running" ? .running : .stopped(rawStatus: colimaStatus)
  }

  public var isRunning: Bool { self == .running }
}

public struct VMInstance: Sendable, Equatable {
  public let runState: VMRunState
  public let arch: String
  public let cpus: Int
  public let memoryBytes: Int64
  public let diskBytes: Int64
  public let runtime: String

  public init(
    runState: VMRunState,
    arch: String,
    cpus: Int,
    memoryBytes: Int64,
    diskBytes: Int64,
    runtime: String
  ) {
    self.runState = runState
    self.arch = arch
    self.cpus = cpus
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.runtime = runtime
  }
}

public enum VMObservation: Sendable, Equatable {
  case unknown(reason: String)
  case absent
  case present(VMInstance)
}
