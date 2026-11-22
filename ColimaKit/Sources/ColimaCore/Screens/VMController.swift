import Foundation
import Observation

public enum PollingCadence: Sendable, Equatable {
  case foreground
  case background

  public var interval: Duration {
    switch self {
    case .foreground: .seconds(3)
    case .background: .seconds(15)
    }
  }
}

public enum DockerAvailability: Sendable, Equatable {
  case ready
  case colimaMissing(searched: [String])
  case vmAbsent
  case vmStopped
  case vmBusy(VMDisplayState)
  /// `reason` is `nil` until the toolchain has been looked up at all.
  case vmUnknown(reason: String?)
}

@MainActor @Observable
public final class VMController {
  public internal(set) var toolchain: ToolchainStatus?
  public internal(set) var observation: VMObservation = .unknown(reason: String(localized: "Not observed yet", bundle: #bundle))
  /// Non-`nil` is the operation slot: a second VM operation is refused while it is set.
  public internal(set) var activeOperation: VMOperationProgress?
  public internal(set) var lastFailure: VMOperationFailure?
  /// The running or most recently finished operation's output. Replaced only when an operation is accepted, so its
  /// identity marks each new operation.
  public internal(set) var latestRecord: VMOperationRecord?
  public internal(set) var pendingConfirmation: ConfirmationRequest?
  /// A recreate failed in its delete stage: the VM may be gone while its data disk remains and could be reattached
  /// by the next create. Outlives `lastFailure`, which the next operation clears.
  public internal(set) var dataDiskMayRemain = false

  @ObservationIgnored let cli: any ColimaCLI
  @ObservationIgnored let files: any ColimaFileStore
  @ObservationIgnored private let poller = Poller(interval: PollingCadence.foreground.interval)
  @ObservationIgnored private var observationGeneration = 0
  @ObservationIgnored private var lastStartedRead = 0
  @ObservationIgnored private var lastAppliedRead = 0
  @ObservationIgnored let now: @Sendable () -> Date
  @ObservationIgnored var currentRun: VMCommandRun?
  /// The controller's own `terminate` call: after `terminate` the exit code is a signal's, so it cannot tell an abort apart.
  @ObservationIgnored var abortRequest: Task<Bool, Never>?
  /// Outlives a refused `terminate`: the child may exit before the signal lands, and the operation still must not advance.
  @ObservationIgnored var stageAbortAsked = false
  @ObservationIgnored var operationTask: Task<Void, Never>?
  /// Memory only: the spec of the last create whose command actually ran.
  @ObservationIgnored var lastCreatedSpec: VMCreateSpec?
  @ObservationIgnored var lastRecreatePlan: RecreatePlan?

  public convenience init(cli: any ColimaCLI, files: any ColimaFileStore) {
    self.init(cli: cli, files: files, now: { Date() })
  }

  init(cli: any ColimaCLI, files: any ColimaFileStore, now: @escaping @Sendable () -> Date) {
    self.cli = cli
    self.files = files
    self.now = now
  }

  public var displayState: VMDisplayState {
    VMDisplayState(observation: observation, activeOperation: activeOperation)
  }

  public var dockerAvailability: DockerAvailability {
    if activeOperation != nil { return .vmBusy(displayState) }
    guard let toolchain else { return .vmUnknown(reason: nil) }
    if case .missing(let searched) = toolchain.colima { return .colimaMissing(searched: searched) }
    switch observation {
    case .unknown(let reason): return .vmUnknown(reason: reason)
    case .absent: return .vmAbsent
    case .present(let instance): return instance.runState.isRunning ? .ready : .vmStopped
    }
  }

  public var isDockerReady: Bool { dockerAvailability == .ready }

  var isColimaFound: Bool {
    if case .found? = toolchain?.colima { true } else { false }
  }

  public func setCadence(_ cadence: PollingCadence) {
    poller.setInterval(cadence.interval)
  }

  /// The app's assembly owns the task so the menu bar keeps updating with no window open.
  public func monitor() async {
    await monitor(clock: ContinuousClock())
  }

  func monitor<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    await detectToolchain()
    await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [self] in
      await refreshNow()
    }
  }

  public func refreshState() async {
    if toolchain == nil {
      await redetectToolchain()
    } else {
      await refreshNow()
    }
  }

  /// A lookup via `redetectToolchain()` is the only way out of the missing-Colima state.
  public func refreshNow() async {
    guard isColimaFound else { return }
    let generation = observationGeneration
    lastStartedRead += 1
    let read = lastStartedRead

    let result: Result<VMObservation, ColimaCLIError>
    do {
      result = .success(try await cli.listDefault())
    } catch {
      result = .failure(error)
    }

    guard generation == observationGeneration, read > lastAppliedRead else { return }
    switch result {
    case .success(let fresh):
      observation = fresh
      // While the delete failure is still the latest failure, a present VM is the one that failed to delete.
      if case .present = fresh, lastFailure?.stage != .deleting { dataDiskMayRemain = false }
    case .failure(.cancelled):
      return
    case .failure(let error):
      observation = .unknown(reason: error.observationReason)
    }
    lastAppliedRead = read
    if case .failure(.colimaMissing) = result { await detectToolchain() }
  }

  public func redetectToolchain() async {
    await detectToolchain()
    await refreshNow()
  }

  /// Called when an operation starts or ends: reads still in flight began before the change and must not land.
  func advanceObservationGeneration() {
    observationGeneration += 1
  }

  func detectToolchain() async {
    let status = await cli.preflight()
    toolchain = status
    guard case .missing = status.colima else { return }
    advanceObservationGeneration()
    observation = .unknown(reason: ColimaCLIError.colimaMissing.observationReason)
  }
}

extension ColimaCLIError {
  fileprivate var observationReason: String {
    switch self {
    case .colimaMissing: String(localized: "colima was not found", bundle: #bundle)
    case .launchFailed(let reason): reason
    case .nonZeroExit(let code, let output):
      output.last ?? String(localized: "colima list failed with exit code \(code)", bundle: #bundle)
    case .undecodable(let detail): detail
    case .timedOut: String(localized: "colima list did not finish in time", bundle: #bundle)
    case .cancelled: String(localized: "colima list was cancelled", bundle: #bundle)
    }
  }
}

#if DEBUG
  extension VMController {
    /// Lets a preview shift the controller's clock so an operation appears to have run for minutes without waiting.
    package convenience init(
      cli: any ColimaCLI, files: any ColimaFileStore, previewNow: @escaping @Sendable () -> Date
    ) {
      self.init(cli: cli, files: files, now: previewNow)
    }
  }
#endif
