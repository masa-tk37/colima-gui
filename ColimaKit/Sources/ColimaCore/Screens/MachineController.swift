import Foundation
import Observation

@MainActor @Observable
public final class MachineController {
  public internal(set) var toolchain: LimaToolchain?
  /// `nil` until the first successful read; a failed read leaves the last good one in place.
  public internal(set) var listing: LimaListing?
  /// The latest read failure with Lima's output as it came; cleared by the next successful read.
  public internal(set) var listError: LimaCLIError?
  /// One slot per machine. Holds only operations an earlier app session started until this session runs its own.
  public internal(set) var operations: [MachineKey: MachineOperationProgress] = [:]
  /// The latest operation's output per machine; the next operation on the machine replaces it.
  public internal(set) var records: [MachineKey: MachineOperationRecord] = [:]
  /// The latest failure per machine, kept until the user dismisses it or the next operation on the machine starts.
  public internal(set) var failures: [MachineKey: MachineOperationFailure] = [:]
  public internal(set) var notice: MachineNotice?
  public internal(set) var pendingConfirmation: ConfirmationRequest?
  /// Names of this session's creates, which `rows()` shows before Lima lists the machine.
  var creatingNames: [MachineKey: MachineName] = [:]
  /// The handle of each run this session started; it is what stopping a create needs.
  var activeRuns: [MachineKey: VMCommandRun] = [:]
  @ObservationIgnored var cancelReplies: [MachineKey: Task<Bool, Never>] = [:]

  @ObservationIgnored let cli: any LimaCLI
  /// Read-only: the default VM's state feeds the memory check, and nothing here starts an operation on it.
  @ObservationIgnored let vmController: VMController?
  @ObservationIgnored let host: HostResources
  @ObservationIgnored let directoryExists: @Sendable (String) -> Bool
  @ObservationIgnored let homeDirectory: String
  /// Advanced when an operation starts or ends: a read begun before the change describes the old state.
  @ObservationIgnored var operationGeneration = 0
  @ObservationIgnored var operationTasks: [MachineKey: Task<Void, Never>] = [:]
  @ObservationIgnored private let poller = Poller(interval: PollingCadence.foreground.interval)
  @ObservationIgnored private var lastStartedRead = 0
  @ObservationIgnored private var lastAppliedRead = 0
  @ObservationIgnored var earlierQueryPending = true
  /// Earlier-session creates the agent accepted a stop for, until the run leaves `activeOperations()`.
  @ObservationIgnored var acceptedEarlierSessionCancels: [UUID: MachineName] = [:]
  /// Names behind the `earlierSession` entries of `operations`, which are keyed by the case-folded `MachineKey`.
  @ObservationIgnored private var earlierSessionNames: [MachineKey: MachineName] = [:]

  public init(
    cli: any LimaCLI,
    vmController: VMController? = nil,
    host: HostResources = .current,
    homeDirectory: String = NSHomeDirectory(),
    directoryExists: @escaping @Sendable (String) -> Bool = MachineController.directoryExistsOnDisk
  ) {
    self.cli = cli
    self.vmController = vmController
    self.host = host
    self.directoryExists = directoryExists
    self.homeDirectory = homeDirectory
  }

  public static let directoryExistsOnDisk: @Sendable (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  public var machines: [MachineInstance]? { listing?.machines }

  public var canCreate: Bool { isLimactlFound }

  var isLimactlFound: Bool {
    if case .found? = toolchain { true } else { false }
  }

  public func setCadence(_ cadence: PollingCadence) {
    poller.setInterval(cadence.interval)
  }

  /// The machines screen owns the task, so nothing runs while the screen is not shown.
  public func monitor() async {
    await monitor(clock: ContinuousClock())
  }

  func monitor<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    await detectToolchain()
    earlierQueryPending = true
    await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [self] in
      await pollOnce()
    }
  }

  private func pollOnce() async {
    await refreshNow()
    guard isLimactlFound, earlierQueryPending || hasEarlierSessionOperations else { return }
    await refreshEarlierSessionOperations()
  }

  /// A missing limactl is looked up again on every call, so an install is noticed without relaunching.
  public func refreshNow() async {
    await read()
  }

  @discardableResult
  func read() async -> Bool {
    if !isLimactlFound { await detectToolchain() }
    guard isLimactlFound else { return true }
    lastStartedRead += 1
    let read = lastStartedRead
    let generation = operationGeneration

    let result: Result<LimaListing, LimaCLIError>
    do {
      result = .success(try await cli.listInstances())
    } catch {
      result = .failure(error)
    }

    let landed = applyListResult(result, read: read, generation: generation)
    if case .failure(.limactlMissing) = result { await detectToolchain() }
    return landed
  }

  public func availableTemplates() async -> Result<[MachineTemplate], LimaCLIError> {
    if !isLimactlFound { await detectToolchain() }
    guard isLimactlFound else { return .failure(.limactlMissing) }
    do {
      return .success(try await cli.listTemplates())
    } catch {
      if error == .limactlMissing { await detectToolchain() }
      return .failure(error)
    }
  }

  public func rows() -> [MachineRow] {
    let listed = (listing?.machines ?? []).map { instance in
      let key = instance.name.key
      return MachineRow(
        name: instance.name,
        display: MachineDisplayState(runState: instance.runState, operation: operations[key]?.kind),
        distribution: instance.templateID.map { MachineTemplate(id: $0)?.displayName ?? $0 },
        instance: instance,
        cancelRequested: operations[key]?.cancelRequested ?? false)
    }
    let listedKeys = Set(listed.map(\.id))
    let unlisted = earlierSessionNames.merging(creatingNames) { _, thisSession in thisSession }
      .filter { key, _ in operations[key]?.kind == .create && !listedKeys.contains(key) }
      .values
      .sorted { $0.rawValue < $1.rawValue }
      .map { name in
        MachineRow(
          name: name, display: .creating, distribution: nil, instance: nil,
          cancelRequested: operations[name.key]?.cancelRequested ?? false)
      }
    return listed + unlisted
  }

  private var hasEarlierSessionOperations: Bool {
    !acceptedEarlierSessionCancels.isEmpty
      || operations.values.contains { if case .earlierSession = $0.origin { true } else { false } }
  }

  private func detectToolchain() async {
    toolchain = await cli.preflight()
  }

  /// The one place a read result lands; a read that began before an operation changed state, or before a
  /// read already reflected, is dropped. Returns false only for the former, which a caller may repeat.
  private func applyListResult(
    _ result: Result<LimaListing, LimaCLIError>, read: Int, generation: Int
  ) -> Bool {
    guard generation == operationGeneration else { return false }
    guard read > lastAppliedRead else { return true }
    switch result {
    case .success(let fresh):
      if listing != fresh { listing = fresh }
      if listError != nil { listError = nil }
    case .failure(.cancelled):
      return true
    case .failure(let error):
      if listError != error { listError = error }
    }
    lastAppliedRead = read
    return true
  }

  private func refreshEarlierSessionOperations() async {
    earlierQueryPending = false
    let generation = operationGeneration
    let active = await cli.activeOperations()
    guard generation == operationGeneration else {
      earlierQueryPending = true
      return
    }
    applyEarlierSessionOperations(active ?? [])
    if let active { await resolveEarlierSessionCancels(active: active) }
  }

  /// `nil` (agent unreachable) arrives here as no operations. A machine this session holds a slot for keeps it: the agent also reports this session's own runs.
  private func applyEarlierSessionOperations(_ active: [ActiveMachineOperation]) {
    let thisSession = operations.filter { if case .thisSession = $0.value.origin { true } else { false } }
    var earlier: [MachineKey: MachineOperationProgress] = [:]
    var names: [MachineKey: MachineName] = [:]
    for operation in active {
      let key = operation.name.key
      guard earlier[key] == nil, thisSession[key] == nil else { continue }
      var progress = MachineOperationProgress(kind: operation.kind, origin: .earlierSession(runID: operation.runID))
      let requested = operations[key].map { $0.origin == progress.origin && $0.cancelRequested } ?? false
      progress.cancelRequested = requested || acceptedEarlierSessionCancels[operation.runID] != nil
      earlier[key] = progress
      names[key] = operation.name
    }
    let merged = thisSession.merging(earlier) { _, new in new }
    if operations != merged { operations = merged }
    earlierSessionNames = names
  }
}

public struct MachineRow: Sendable, Equatable, Identifiable {
  public let name: MachineName
  public let display: MachineDisplayState
  /// The template's display name, the raw id when it is outside the allow-list, `nil` when unknown.
  public let distribution: String?
  public let instance: MachineInstance?
  public let cancelRequested: Bool

  public var id: MachineKey { name.key }
}

extension MachineDisplayState {
  init(runState: MachineRunState, operation: MachineOperationKind?) {
    switch operation {
    case .create?: self = .creating
    case .start?: self = .starting
    case .stop?: self = .stopping
    case .delete?: self = .deleting
    case .edit?: self = .saving
    case nil:
      switch runState {
      case .running: self = .running
      case .stopped: self = .stopped
      case .broken(let errors): self = .broken(errors: errors)
      case .other(let rawStatus): self = .other(rawStatus: rawStatus)
      }
    }
  }
}
