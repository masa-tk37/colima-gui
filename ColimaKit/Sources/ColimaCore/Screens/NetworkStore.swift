import Foundation
import Observation

public enum NetworkCreateResult: Sendable, Equatable {
  case created(NetworkID)
  case invalid(NetworkCreateFailure)
  /// The engine refused or could not be reached; the message is also kept in `createFailure`.
  case failed(String)
  case unavailable
  case busy
}

@MainActor @Observable
public final class NetworkStore {
  static let pollInterval: Duration = .seconds(3)

  public var networks: ResourceSnapshot<[NetworkSummary]> { listing.snapshot }
  public private(set) var selectedID: NetworkID?
  public var detail: ResourceSnapshot<NetworkDetail> { detailListing.snapshot }
  public private(set) var isCreating = false
  public private(set) var createFieldErrors: [NetworkFieldError] = []
  public private(set) var createFailure: String?
  public internal(set) var removalFailures: [NetworkID: String] = [:]
  public internal(set) var removing: Set<NetworkID> = []
  public internal(set) var pendingConfirmation: ConfirmationRequest?
  public internal(set) var isPruning = false
  public internal(set) var lastPruneOutcome: BatchOutcome<NetworkID>?
  public internal(set) var pruneRequestError: String?
  public internal(set) var connectionFailures: [NetworkMembership: String] = [:]

  @ObservationIgnored let engine: any DockerEngine
  @ObservationIgnored let controller: VMController
  @ObservationIgnored let slots: ContainerOperationSlots
  @ObservationIgnored let containerListDidChange: @MainActor @Sendable () async -> Void
  @ObservationIgnored let listing: ListRefresher<[NetworkSummary]>
  @ObservationIgnored let operations = OperationTracker()
  @ObservationIgnored private let poller = Poller(interval: NetworkStore.pollInterval)
  /// Replaced on every selection change (and so tracked), so a response for a previous selection lands in a
  /// refresher nobody reads.
  private var detailListing: ListRefresher<NetworkDetail>

  public init(
    engine: any DockerEngine,
    controller: VMController,
    slots: ContainerOperationSlots,
    containerListDidChange: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.engine = engine
    self.controller = controller
    self.slots = slots
    self.containerListDidChange = containerListDidChange
    listing = ListRefresher()
    detailListing = ListRefresher()
  }

  // MARK: List and detail

  public func monitor() async {
    await monitor(clock: ContinuousClock())
  }

  func monitor<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [self] in await refresh() }
  }

  public func refresh() async {
    guard controller.isDockerReady else { return }
    let engine = engine
    await listing.refresh { () async throws(DockerError) -> [NetworkSummary] in
      try await engine.listNetworks(danglingOnly: false)
    }
    if let rows = networks.value, let id = selectedID, !rows.contains(where: { $0.id == id }) {
      select(nil)
    }
    await refreshDetail()
  }

  func refreshDetail() async {
    guard controller.isDockerReady, let id = selectedID else { return }
    let engine = engine
    await detailListing.refresh { () async throws(DockerError) -> NetworkDetail in
      try await engine.inspectNetwork(id: id)
    }
  }

  public func select(_ id: NetworkID?) {
    guard id != selectedID else { return }
    selectedID = id
    detailListing = ListRefresher()
    guard id != nil else { return }
    operations.track { [self] in await refreshDetail() }
  }

  // MARK: Create

  /// The engine call outlives the calling task, so closing the form's sheet never abandons a create half way.
  public func createNetwork(_ form: NetworkCreateForm) async -> NetworkCreateResult {
    guard controller.isDockerReady else { return .unavailable }
    guard !isCreating else { return .busy }
    createFieldErrors = []
    createFailure = nil

    let existingNames = networks.value?.map(\.name) ?? []
    switch form.validate(existingNames: existingNames) {
    case .failure(let failure):
      createFieldErrors = failure.fields
      return .invalid(failure)
    case .success(let request):
      isCreating = true
      return await Task { await create(request) }.value
    }
  }

  private func create(_ request: ValidatedNetworkCreate) async -> NetworkCreateResult {
    defer { isCreating = false }
    let result: NetworkCreateResult
    do throws(DockerError) {
      result = .created(try await engine.createNetwork(request))
    } catch {
      createFailure = error.displayMessage
      result = .failed(error.displayMessage)
    }
    await refresh()
    return result
  }

  // MARK: Delete

  public func canDelete(_ summary: NetworkSummary) -> Bool {
    summary.deletableID != nil
  }

  @discardableResult
  public func requestDelete(_ summary: NetworkSummary) -> Bool {
    guard let deletable = summary.deletableID, controller.isDockerReady,
      !removing.contains(summary.id)
    else { return false }
    pendingConfirmation = ConfirmationRequest(
      intent: .deleteNetwork(deletable),
      title: String(localized: "Delete the network “\(summary.name)”?", bundle: #bundle),
      message: String(localized: "The network is deleted. A network with connected containers cannot be deleted.", bundle: #bundle),
      item: summary.name,
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    return true
  }

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id else { return .notPending }
    switch request.intent {
    case .deleteNetwork(let deletable):
      pendingConfirmation = nil
      return startDelete(deletable)
    case .pruneNetworks(let ids):
      pendingConfirmation = nil
      return startPrune(ids)
    case .disconnect(let container, let network):
      pendingConfirmation = nil
      return startDisconnect(container: container, network: network)
    default:
      return .notPending
    }
  }

  private func startDelete(_ deletable: DeletableNetworkID) -> ConfirmationOutcome {
    guard controller.isDockerReady else {
      ColimaLog.docker.info("network deletion discarded: Docker is not ready")
      return .dockerNotReady(.delete)
    }
    guard !removing.contains(deletable.id) else {
      ColimaLog.docker.info("network deletion discarded: the network is already being removed")
      return .rejectedBusy(
        reason: String(localized: "This network is already being deleted, so the deletion was not performed.", bundle: #bundle))
    }

    removing.insert(deletable.id)
    removalFailures[deletable.id] = nil
    operations.track { [self] in
      await remove(deletable)
      await refresh()
    }
    return .started
  }

  /// Reached only from `confirm(id:)`.
  private func remove(_ deletable: DeletableNetworkID) async {
    defer { removing.remove(deletable.id) }
    do throws(DockerError) {
      try await engine.removeNetwork(deletable)
      if selectedID == deletable.id { select(nil) }
    } catch {
      removalFailures[deletable.id] = error.displayMessage
    }
  }

  // MARK: Support

  func awaitOperations() async {
    await operations.awaitAll()
  }
}
