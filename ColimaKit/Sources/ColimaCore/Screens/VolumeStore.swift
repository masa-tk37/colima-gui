import Foundation
import Observation

@MainActor @Observable
public final class VolumeStore {
  public var volumes: ResourceSnapshot<[VolumeRow]> { listing.snapshot }
  public private(set) var removalFailures: [String: String] = [:]
  public private(set) var removing: Set<String> = []
  public private(set) var isPruning = false
  public private(set) var pendingConfirmation: ConfirmationRequest?
  public private(set) var lastPruneReport: PruneReport?
  public private(set) var pruneRequestError: String?

  @ObservationIgnored private let engine: any DockerEngine
  @ObservationIgnored private let controller: VMController
  @ObservationIgnored private let listing: ListRefresher<[VolumeRow]>
  @ObservationIgnored private let operations = OperationTracker()
  @ObservationIgnored private var pruneSizes: (requestID: UUID, sizes: [String: VolumeSize])?

  public init(engine: any DockerEngine, controller: VMController) {
    self.engine = engine
    self.controller = controller
    listing = ListRefresher()
  }

  // MARK: List

  public func refresh() async {
    guard controller.isDockerReady else { return }
    let engine = engine
    await listing.refresh { () async throws(DockerError) -> [VolumeRow] in
      let all = try await engine.listVolumes(danglingOnly: false)
      let unused = Set(try await engine.listVolumes(danglingOnly: true).map(\.name))
      return all.map { VolumeRow(volume: $0, isInUse: !unused.contains($0.name)) }
    }
  }

  // MARK: Remove

  @discardableResult
  public func requestDelete(_ row: VolumeRow) -> Bool {
    let name = row.volume.name
    guard controller.isDockerReady, !isPruning, !removing.contains(name) else { return false }
    pendingConfirmation = ConfirmationRequest(
      intent: .deleteVolume(name: name),
      title: String(localized: "Delete the volume “\(name)”?", bundle: #bundle),
      message: String(localized: "Data in the volume is lost and cannot be recovered. A volume in use by a container cannot be deleted.", bundle: #bundle),
      item: name,
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    return true
  }

  // MARK: Prune

  public func requestPrune() async -> PruneRequestResult {
    guard controller.isDockerReady, !isPruning else { return .nothingToPrune }
    lastPruneReport = nil
    pruneRequestError = nil

    let candidates: [VolumeSummary]
    do throws(DockerError) {
      candidates = try await engine.listVolumes(danglingOnly: true)
    } catch {
      if error != .cancelled { pruneRequestError = error.displayMessage }
      return .nothingToPrune
    }
    guard !candidates.isEmpty else { return .nothingToPrune }

    // The estimate is a courtesy: without it the prune stays possible and every candidate counts as unknown.
    let sizes: [String: VolumeSize]
    do throws(DockerError) {
      sizes = try await engine.volumeSizes()
    } catch {
      if error == .cancelled { return .nothingToPrune }
      ColimaLog.docker.info("volume sizes unavailable for the prune estimate")
      sizes = [:]
    }

    guard controller.isDockerReady, !isPruning else { return .nothingToPrune }

    let anonymous = candidates.filter(\.isAnonymous).map(\.name)
    let named = candidates.filter { !$0.isAnonymous }.map(\.name)
    let groups = [
      ConfirmationItemGroup(title: String(localized: "Anonymous volumes", bundle: #bundle), items: anonymous),
      ConfirmationItemGroup(title: String(localized: "Named volumes", bundle: #bundle), items: named),
    ].filter { !$0.items.isEmpty }
    let names = anonymous + named

    let request = ConfirmationRequest(
      intent: .pruneVolumes(names: names),
      origin: .window,
      title: String(localized: "Delete \(names.count) unused volumes?", bundle: #bundle),
      message: Self.pruneMessage(names: names, sizes: sizes),
      itemGroups: groups,
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    pruneSizes = (request.id, sizes)
    pendingConfirmation = request
    return .confirmationRequested
  }

  private static func pruneMessage(names: [String], sizes: [String: VolumeSize]) -> String {
    let known = names.compactMap { sizes[$0]?.bytes }
    let unknownCount = names.count - known.count
    let size = ByteCountFormatter.string(fromByteCount: known.reduce(0, +), countStyle: .file)
    // `docker volume prune` deletes only anonymous volumes by default since API 1.42, so the difference is stated.
    let estimate =
      unknownCount > 0
      ? String(localized: "\(size) (excluding volumes of unknown size: \(unknownCount))", bundle: #bundle)
      : size
    return String(localized: "Named volumes are deleted too. (`docker volume prune` deletes only anonymous volumes by default, but this app includes named volumes.) Data in the volumes is lost and cannot be recovered. The estimated recoverable space is \(estimate).", bundle: #bundle)
  }

  // MARK: Confirm

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id else { return .notPending }
    let names: [String]
    switch request.intent {
    case .deleteVolume(let name): names = [name]
    case .pruneVolumes(let candidates): names = candidates
    default: return .notPending
    }
    pendingConfirmation = nil
    let sizes = pruneSizes?.requestID == id ? pruneSizes?.sizes ?? [:] : [:]
    pruneSizes = nil

    guard controller.isDockerReady else {
      ColimaLog.docker.info("volume deletion discarded: Docker is not ready")
      return .dockerNotReady(.delete)
    }
    guard !isPruning, removing.isDisjoint(with: names) else {
      ColimaLog.docker.info("volume deletion discarded: another deletion is running")
      return .anotherDeletionInProgress
    }

    removing.formUnion(names)
    if case .pruneVolumes = request.intent {
      isPruning = true
      lastPruneReport = nil
      operations.track { [self] in
        await prune(names, sizes: sizes)
        isPruning = false
        await refresh()
      }
    } else {
      removalFailures[names[0]] = nil
      operations.track { [self] in
        await remove(names[0])
        await refresh()
      }
    }
    return .started
  }

  /// Reached only from `confirm(id:)`.
  private func remove(_ name: String) async {
    defer { removing.remove(name) }
    do throws(DockerError) {
      try await engine.removeVolume(name: name)
    } catch {
      removalFailures[name] = error.displayMessage
    }
  }

  /// Reached only from `confirm(id:)`. Deletes exactly `names`, one at a time and without force, so a volume
  /// that became in-use after the confirmation fails at the engine and is reported on its own.
  private func prune(_ names: [String], sizes: [String: VolumeSize]) async {
    var deletedSizes: [Int64?] = []
    var failures: [String: String] = [:]
    for name in names {
      do throws(DockerError) {
        try await engine.removeVolume(name: name)
        deletedSizes.append(sizes[name]?.bytes)
      } catch {
        failures[name] = error.displayMessage
      }
      removing.remove(name)
    }
    lastPruneReport = PruneReport(deletedSizes: deletedSizes, failures: failures)
  }

  // MARK: Support

  func awaitOperations() async {
    await operations.awaitAll()
  }
}
