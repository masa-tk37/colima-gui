import Foundation
import Observation

@MainActor @Observable
public final class ImageStore {
  public var images: ResourceSnapshot<[ImageRow]> { listing.snapshot }
  public private(set) var removalFailures: [ImageReference: String] = [:]
  public private(set) var removing: Set<ImageReference> = []
  public private(set) var pendingConfirmation: ConfirmationRequest?
  /// Containers per image ID, stopped ones included; `nil` when the container list could not be read.
  public private(set) var containerCounts: [String: Int]?

  @ObservationIgnored private let engine: any DockerEngine
  @ObservationIgnored private let controller: VMController
  @ObservationIgnored private let listing: ListRefresher<[ImageRow]>
  @ObservationIgnored private let operations = OperationTracker()

  public init(engine: any DockerEngine, controller: VMController) {
    self.engine = engine
    self.controller = controller
    listing = ListRefresher()
  }

  // MARK: List

  public func refresh() async {
    guard controller.isDockerReady else { return }
    let engine = engine
    await listing.refresh { () async throws(DockerError) -> [ImageRow] in
      try await engine.listImages().flatMap(\.rows)
    }
    await refreshUsage()
  }

  public func containerCount(for row: ImageRow) -> Int? {
    containerCounts.map { $0[row.imageID] ?? 0 }
  }

  /// Separate from the image list so a failed container list never hides the images.
  private func refreshUsage() async {
    do {
      let containers = try await engine.listContainers()
      containerCounts = Dictionary(
        containers.filter { !$0.imageID.isEmpty }.map { ($0.imageID, 1) }, uniquingKeysWith: +)
    } catch {
      containerCounts = nil
    }
  }

  // MARK: Remove

  @discardableResult
  public func requestDelete(_ row: ImageRow) -> Bool {
    let reference = row.reference
    guard controller.isDockerReady, !removing.contains(reference) else { return false }
    let message: String =
      switch reference {
      case .tag:
        String(localized: "This tag is deleted. If no other tags remain, the image itself is deleted too and this cannot be undone. An image in use by a container cannot be deleted.", bundle: #bundle)
      case .imageID:
        String(localized: "The image itself is deleted and this cannot be undone. An image in use by a container cannot be deleted.", bundle: #bundle)
      }
    pendingConfirmation = ConfirmationRequest(
      intent: .deleteImage(reference),
      title: String(localized: "Delete the image “\(reference.value)”?", bundle: #bundle),
      message: message,
      item: reference.value,
      confirmLabel: String(localized: "Delete", bundle: #bundle)
    )
    return true
  }

  public func dismissConfirmation() {
    pendingConfirmation = nil
  }

  @discardableResult
  public func confirm(id: ConfirmationRequest.ID) -> ConfirmationOutcome {
    guard let request = pendingConfirmation, request.id == id,
      case .deleteImage(let reference) = request.intent
    else { return .notPending }
    pendingConfirmation = nil
    guard controller.isDockerReady else {
      ColimaLog.docker.info("image removal discarded: Docker is not ready")
      return .dockerNotReady(.delete)
    }
    removalFailures[reference] = nil
    removing.insert(reference)
    operations.track { [self] in
      await remove(reference)
      removing.remove(reference)
      await refresh()
    }
    return .started
  }

  /// Reached only from `confirm(id:)`.
  private func remove(_ reference: ImageReference) async {
    do throws(DockerError) {
      try await engine.removeImage(reference)
    } catch {
      removalFailures[reference] = error.displayMessage
    }
  }

  // MARK: Support

  func awaitOperations() async {
    await operations.awaitAll()
  }
}
