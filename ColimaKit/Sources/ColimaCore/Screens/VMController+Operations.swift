import Foundation

enum LifecycleOperation: Equatable {
  case start, stop, restart
  case create(VMCreateSpec)
  case recreate(RecreatePlan)

  var kind: VMOperationKind {
    switch self {
    case .start: .start
    case .stop: .stop
    case .restart: .restart
    case .create: .create
    case .recreate: .recreate
    }
  }

  fileprivate var busyRejectionReason: String {
    switch self {
    case .stop:
      String(localized: "Another VM operation is running, so the stop was not performed.", bundle: #bundle)
    case .restart:
      String(localized: "Another VM operation is running, so the restart was not performed.", bundle: #bundle)
    case .recreate:
      String(localized: "Another VM operation is running, so the recreation was not performed.", bundle: #bundle)
    case .start, .create:
      String(localized: "Another VM operation is running, so the operation was not performed.", bundle: #bundle)
    }
  }

  var initialStage: VMOperationStage {
    switch self {
    case .start: .starting
    case .stop, .restart: .stopping
    case .create, .recreate: .preflight
    }
  }
}

typealias StageFailure = (stage: VMOperationStage, cause: VMFailureCause)

extension VMController {
  // MARK: Requests

  /// Only the menu bar may be the origin of a non-window request, and only for a stop.
  public func requestStop(from origin: ConfirmationOrigin) {
    guard canRequestStopOrRestart else { return }
    pendingConfirmation = ConfirmationRequest(
      intent: .stopVM,
      origin: origin,
      title: String(localized: "Stop the VM?", bundle: #bundle),
      message: String(localized: "Stopping the VM also stops all running containers.", bundle: #bundle),
      itemGroups: [],
      confirmLabel: String(localized: "Stop", bundle: #bundle)
    )
  }

  public func requestRestart() {
    guard canRequestStopOrRestart else { return }
    pendingConfirmation = ConfirmationRequest(
      intent: .restartVM,
      origin: .window,
      title: String(localized: "Restart the VM?", bundle: #bundle),
      message: String(localized: "The VM is stopped and then started again. All running containers are stopped first.", bundle: #bundle),
      itemGroups: [],
      confirmLabel: String(localized: "Restart", bundle: #bundle)
    )
  }

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id else { return .notPending }
    let operation: LifecycleOperation
    switch request.intent {
    case .stopVM: operation = .stop
    case .restartVM: operation = .restart
    case .recreateVM(let plan): operation = .recreate(plan)
    default: return .notPending
    }
    pendingConfirmation = nil
    guard activeOperation == nil else {
      ColimaLog.vm.info("confirmation discarded: another operation is running")
      return .rejectedBusy(reason: operation.busyRejectionReason)
    }
    if case .recreate(let plan) = operation { lastRecreatePlan = plan }
    begin(operation)
    return .started
  }

  // MARK: Start

  public var canStart: Bool {
    guard activeOperation == nil, isColimaFound else { return false }
    switch observation {
    case .present(let instance): return !instance.runState.isRunning
    case .absent: return true
    case .unknown: return false
    }
  }

  public func start() {
    guard canStart else { return }
    if case .absent = observation {
      create(creationDefaults())
    } else {
      begin(.start)
    }
  }

  // MARK: Abort

  /// The operation task is already waiting on `.exited`; it records the abort and stops there instead of moving to the next stage.
  public func abortOperation() {
    guard let operation = activeOperation, operation.isAbortAvailable(at: now()),
      let run = currentRun, abortRequest == nil
    else { return }
    ColimaLog.vm.info(
      "operation abort requested: kind=\(String(describing: operation.kind), privacy: .public)")
    let request = Task { await run.terminate() }
    abortRequest = request
    stageAbortAsked = true
    Task {
      if await !request.value, abortRequest == request { abortRequest = nil }
    }
  }

  // MARK: Running

  public var canRequestStopOrRestart: Bool {
    guard activeOperation == nil, isColimaFound, case .present(let instance) = observation else {
      return false
    }
    return instance.runState.isRunning
  }

  func begin(_ operation: LifecycleOperation) {
    let kind = operation.kind
    let started = now()
    activeOperation = VMOperationProgress(
      kind: kind, stage: operation.initialStage, startedAt: started, stageStartedAt: started)
    latestRecord = VMOperationRecord(kind: kind, startedAt: started)
    lastFailure = nil
    abortRequest = nil
    stageAbortAsked = false
    advanceObservationGeneration()
    ColimaLog.vm.info("operation started: kind=\(String(describing: kind), privacy: .public)")
    operationTask = Task { await run(operation) }
  }

  private func run(_ operation: LifecycleOperation) async {
    let cause = await perform(operation)
    await finish(kind: operation.kind, cause: cause)
  }

  private func perform(_ operation: LifecycleOperation) async -> StageFailure? {
    switch operation {
    case .start:
      return await runStage(.starting, command: .start)
    case .stop:
      return await runStage(.stopping, command: .stop)
    case .restart:
      if let failure = await runStage(.stopping, command: .stop) { return failure }
      await refreshNow()
      guard case .present(let instance) = observation, !instance.runState.isRunning else {
        return (.stopping, .stopNotConfirmed)
      }
      return await runStage(.starting, command: .start)
    case .create(let spec):
      return await performCreate(spec)
    case .recreate(let plan):
      return await performRecreate(plan)
    }
  }

  func runStage(_ stage: VMOperationStage, command: VMCommand) async -> StageFailure? {
    activeOperation?.advance(to: stage, at: now())
    let run = await cli.run(command)
    currentRun = run
    defer { currentRun = nil }

    var terminal: ProcessEvent?
    for await event in run.events {
      switch event {
      case .output(let line):
        activeOperation?.noteOutput(at: now())
        latestRecord?.append(line)
      case .exited, .launchFailed: terminal = event
      }
    }

    let abortAccepted = await abortRequest?.value ?? false
    let abortAsked = stageAbortAsked
    abortRequest = nil
    stageAbortAsked = false
    if abortAccepted { return (stage, .aborted) }
    switch terminal {
    case .exited(code: 0)?: return abortAsked ? (stage, .aborted) : nil
    case .exited(let code)?: return (stage, .exited(code: code))
    case .launchFailed(let reason)?: return (stage, .launchFailed(reason: reason))
    case .output?, nil: return (stage, .launchFailed(reason: String(localized: "colima output ended unexpectedly", bundle: #bundle)))
    }
  }

  /// The slot stays held through the final read, so the screen never shows the state from before the operation.
  func finish(kind: VMOperationKind, cause: StageFailure?) async {
    let failure = cause.map {
      VMOperationFailure(
        kind: kind, stage: $0.stage, cause: $0.cause,
        outputLines: latestRecord?.texts ?? [])
    }
    advanceObservationGeneration()
    await refreshNow()
    lastFailure = failure
    if failure?.stage == .deleting {
      dataDiskMayRemain = true
    } else if failure == nil, kind == .create || kind == .recreate {
      dataDiskMayRemain = false
    }
    latestRecord?.end(failure.map(VMOperationOutcome.failed) ?? .succeeded, at: now())
    activeOperation = nil
    abortRequest = nil
    stageAbortAsked = false
    if let failure {
      ColimaLog.vm.error(
        "operation failed: kind=\(String(describing: kind), privacy: .public) stage=\(String(describing: failure.stage), privacy: .public) outputLines=\(failure.outputTail.count)"
      )
    } else {
      ColimaLog.vm.info("operation finished: kind=\(String(describing: kind), privacy: .public)")
    }
  }
}
