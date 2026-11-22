import Foundation

public struct NetworkMembership: Sendable, Hashable {
  public let container: ContainerID
  public let network: NetworkID

  public init(container: ContainerID, network: NetworkID) {
    self.container = container
    self.network = network
  }
}

extension NetworkStore {
  // MARK: Prune

  public func requestPrune() async -> PruneRequestResult {
    guard controller.isDockerReady, !isPruning else { return .nothingToPrune }
    lastPruneOutcome = nil
    pruneRequestError = nil

    let unused: [NetworkSummary]
    do throws(DockerError) {
      unused = try await engine.listNetworks(danglingOnly: true)
    } catch {
      if error != .cancelled { pruneRequestError = error.displayMessage }
      return .nothingToPrune
    }
    // The built-in networks have no `deletableID`, so they can never become candidates.
    let candidates = unused.compactMap { summary in
      summary.deletableID.map { (name: summary.name, id: $0) }
    }
    guard !candidates.isEmpty else { return .nothingToPrune }

    guard controller.isDockerReady, !isPruning else { return .nothingToPrune }

    pendingConfirmation = ConfirmationRequest(
      intent: .pruneNetworks(ids: candidates.map(\.id)),
      origin: .window,
      title: String(localized: "Delete \(candidates.count) unused networks?", bundle: #bundle),
      message: String(localized: "Networks that no running container is connected to are deleted. Networks referenced only by stopped containers are deleted too, and those containers may fail to start next time.", bundle: #bundle),
      itemGroups: [ConfirmationItemGroup(title: nil, items: candidates.map(\.name))],
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    return .confirmationRequested
  }

  /// Reached only from `confirm(id:)`.
  func startPrune(_ ids: [DeletableNetworkID]) -> ConfirmationOutcome {
    guard controller.isDockerReady else {
      ColimaLog.docker.info("network prune discarded: Docker is not ready")
      return .dockerNotReady(.delete)
    }
    guard !isPruning, removing.isDisjoint(with: ids.map(\.id)) else {
      ColimaLog.docker.info("network prune discarded: another deletion is running")
      return .anotherDeletionInProgress
    }

    removing.formUnion(ids.map(\.id))
    isPruning = true
    lastPruneOutcome = nil
    operations.track { [self] in
      await prune(ids)
      isPruning = false
      await refresh()
    }
    return .started
  }

  /// Deletes exactly `ids`, one at a time and without force, so a network that gained a running container after
  /// the confirmation fails at the engine and is reported on its own.
  private func prune(_ ids: [DeletableNetworkID]) async {
    var succeeded: [NetworkID] = []
    var failed: [NetworkID: String] = [:]
    for deletable in ids {
      do throws(DockerError) {
        try await engine.removeNetwork(deletable)
        succeeded.append(deletable.id)
        if selectedID == deletable.id { select(nil) }
      } catch {
        failed[deletable.id] = error.displayMessage
      }
      removing.remove(deletable.id)
    }
    lastPruneOutcome = BatchOutcome(succeeded: succeeded, failed: failed)
  }

  // MARK: Connect and disconnect

  @discardableResult
  public func connect(container: ContainerID, to network: NetworkID) -> Bool {
    guard controller.isDockerReady, slots.reserve(container) else { return false }
    trackMembershipChange(container: container, network: network) {
      [engine] () throws(DockerError) in
      try await engine.connect(container: container, to: network)
    }
    return true
  }

  @discardableResult
  public func requestDisconnect(container: ContainerID, from network: NetworkID) -> Bool {
    guard controller.isDockerReady, !slots.isBusy(container) else { return false }
    let containerName =
      detail.value?.containers.first { $0.id == container }?.name ?? container.rawValue
    let networkName =
      networks.value?.first { $0.id == network }?.name
      ?? detail.value.flatMap { $0.id == network ? $0.name : nil }
      ?? network.rawValue
    pendingConfirmation = ConfirmationRequest(
      intent: .disconnect(container: container, network: network),
      title: String(localized: "Disconnect the container “\(containerName)” from the network “\(networkName)”?", bundle: #bundle),
      message: String(localized: "After disconnecting, the container can no longer communicate with other containers on this network.", bundle: #bundle),
      item: containerName,
      confirmLabel: String(localized: "Disconnect", bundle: #bundle)
    )
    return true
  }

  /// Reached only from `confirm(id:)`.
  func startDisconnect(container: ContainerID, network: NetworkID) -> ConfirmationOutcome {
    guard controller.isDockerReady else {
      ColimaLog.docker.info("network disconnect discarded: Docker is not ready")
      return .dockerNotReady(.disconnect)
    }
    guard slots.reserve(container) else {
      ColimaLog.docker.info("network disconnect discarded: another operation holds the container")
      return .containerBusy(.disconnect)
    }
    trackMembershipChange(container: container, network: network) {
      [engine] () throws(DockerError) in
      try await engine.disconnect(container: container, from: network)
    }
    return .started
  }

  /// Expects the container's slot to be held and releases it. The refresh runs on failure too: a lost connection may still have changed the membership.
  private func trackMembershipChange(
    container: ContainerID,
    network: NetworkID,
    _ change: @escaping @MainActor () async throws(DockerError) -> Void
  ) {
    let membership = NetworkMembership(container: container, network: network)
    connectionFailures[membership] = nil
    operations.track { [self] in
      do throws(DockerError) {
        try await change()
      } catch {
        connectionFailures[membership] = error.displayMessage
      }
      slots.release(container)
      await refresh()
      await containerListDidChange()
    }
  }
}
