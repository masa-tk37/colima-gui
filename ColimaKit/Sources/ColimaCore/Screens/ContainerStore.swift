import Foundation
import Observation

public enum DeleteAvailability: Sendable, Equatable {
  case confirmationRequested
  case mustStopFirst
  /// The container's slot is taken, or Docker is not ready.
  case busy
}

public enum ContainerOperation: Sendable, Equatable {
  case action(ContainerAction)
  case delete
}

public struct ContainerOperationFailure: Sendable, Equatable {
  public let operation: ContainerOperation
  public let message: String
}

@MainActor @Observable
public final class ContainerStore {
  static let pollInterval: Duration = .seconds(3)
  static let projectConcurrency = 4

  public var containers: ResourceSnapshot<[ContainerSummary]> { listing.snapshot }
  public private(set) var operationFailures: [ContainerID: ContainerOperationFailure] = [:]
  public private(set) var projectOutcomes: [String: BatchOutcome<ContainerID>] = [:]
  public private(set) var pendingConfirmation: ConfirmationRequest?

  @ObservationIgnored private let engine: any DockerEngine
  @ObservationIgnored private let controller: VMController
  @ObservationIgnored private let slots: ContainerOperationSlots
  @ObservationIgnored private let listing: ListRefresher<[ContainerSummary]>
  @ObservationIgnored private let poller = Poller(interval: ContainerStore.pollInterval)
  @ObservationIgnored private let operations = OperationTracker()

  public init(engine: any DockerEngine, controller: VMController, slots: ContainerOperationSlots) {
    self.engine = engine
    self.controller = controller
    self.slots = slots
    listing = ListRefresher()
  }

  public var groups: ContainerGroups {
    ComposeGrouping.group(containers.value ?? [])
  }

  // MARK: List

  public func monitor() async {
    await monitor(clock: ContinuousClock())
  }

  func monitor<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [self] in await refresh() }
  }

  /// Also what the network store calls after it changes which containers are connected.
  public func refresh() async {
    guard controller.isDockerReady else { return }
    let engine = engine
    await listing.refresh { () async throws(DockerError) -> [ContainerSummary] in
      try await engine.listContainers()
    }
  }

  // MARK: Single container

  @discardableResult
  public func perform(_ action: ContainerAction, on id: ContainerID) -> Bool {
    guard controller.isDockerReady, slots.reserve(id) else { return false }
    operationFailures[id] = nil
    operations.track { [self] in
      do throws(DockerError) {
        try await engine.perform(action, on: id)
      } catch {
        recordFailure(.action(action), for: id, error: error)
      }
      slots.release(id)
      await refresh()
    }
    return true
  }

  // MARK: Delete

  @discardableResult
  public func requestDelete(_ id: ContainerID) -> DeleteAvailability {
    guard controller.isDockerReady, !slots.isBusy(id) else { return .busy }
    let listed = containers.value?.first { $0.id == id }
    if listed?.state.isRunning == true { return .mustStopFirst }
    let name = listed?.name ?? id.rawValue
    pendingConfirmation = ConfirmationRequest(
      intent: .deleteContainer(id),
      title: String(localized: "Delete the container “\(name)”?", bundle: #bundle),
      message: String(localized: "Deleting a container discards changes made to files inside it and cannot be undone. Volumes are not deleted.", bundle: #bundle),
      item: name,
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    return .confirmationRequested
  }

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id,
      case .deleteContainer(let containerID) = request.intent
    else { return .notPending }
    pendingConfirmation = nil
    guard controller.isDockerReady else {
      ColimaLog.docker.info("container deletion discarded: Docker is not ready")
      return .dockerNotReady(.delete)
    }
    guard slots.reserve(containerID) else {
      ColimaLog.docker.info("container deletion discarded: another operation holds the container")
      return .containerBusy(.delete)
    }
    operationFailures[containerID] = nil
    operations.track { [self] in
      await delete(containerID)
      slots.release(containerID)
      await refresh()
    }
    return .started
  }

  /// Reached only from `confirm(id:)`.
  private func delete(_ id: ContainerID) async {
    do throws(DockerError) {
      let detail = try await engine.inspectContainer(id: id)
      guard !detail.isRunning else {
        operationFailures[id] = ContainerOperationFailure(
          operation: .delete,
          message: String(localized: "The container was not deleted because it is running. Stop it first.", bundle: #bundle)
        )
        return
      }
      try await engine.removeContainer(id: id)
    } catch {
      recordFailure(.delete, for: id, error: error)
    }
  }

  // MARK: Compose projects

  @discardableResult
  public func performProject(_ action: ContainerAction, on project: String) -> Bool {
    guard controller.isDockerReady,
      let members = groups.projects.first(where: { $0.name == project })?.containerIDs
    else { return false }
    projectOutcomes[project] = nil

    var skipped: [ContainerID: String] = [:]
    var reserved: [ContainerID] = []
    for member in members {
      if slots.reserve(member) {
        reserved.append(member)
        operationFailures[member] = nil
      } else {
        skipped[member] = String(localized: "This container is busy with another operation, so the action was not performed.", bundle: #bundle)
      }
    }

    operations.track { [self] in
      let results = await runBatch(action, on: reserved)
      var failed = skipped
      for (id, error) in results {
        if let error { failed[id] = error.displayMessage }
      }
      projectOutcomes[project] = BatchOutcome(
        succeeded: members.filter { failed[$0] == nil },
        failed: failed
      )
      await refresh()
    }
    return true
  }

  private func runBatch(_ action: ContainerAction, on ids: [ContainerID]) async -> [ContainerID:
    DockerError?]
  {
    let engine = engine
    var results: [ContainerID: DockerError?] = [:]
    await withTaskGroup(of: (ContainerID, DockerError?).self) { group in
      var next = ids.makeIterator()
      func addNext() {
        guard let id = next.next() else { return }
        group.addTask {
          do throws(DockerError) {
            try await engine.perform(action, on: id)
            return (id, nil)
          } catch {
            return (id, error)
          }
        }
      }
      for _ in 0..<Self.projectConcurrency { addNext() }
      while let (id, error) = await group.next() {
        results[id] = .some(error)
        slots.release(id)
        addNext()
      }
    }
    return results
  }

  // MARK: Support

  private func recordFailure(
    _ operation: ContainerOperation, for id: ContainerID, error: DockerError
  ) {
    operationFailures[id] = ContainerOperationFailure(
      operation: operation, message: error.displayMessage)
  }

  func awaitOperations() async {
    await operations.awaitAll()
  }
}
