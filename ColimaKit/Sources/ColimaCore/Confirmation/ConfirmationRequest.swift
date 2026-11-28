import Foundation

/// An irreversible operation, or one that needs the user's judgment, fixed at the moment the user is asked.
/// Prune intents carry the candidate list shown in the confirmation, so approval deletes exactly those items and
/// nothing that appeared later.
public enum DestructiveIntent: Sendable, Equatable {
  case stopVM
  case restartVM
  case recreateVM(RecreatePlan)
  case deleteContainer(ContainerID)
  case deleteImage(ImageReference)
  case deleteVolume(name: String)
  case pruneVolumes(names: [String])
  case deleteNetwork(DeletableNetworkID)
  case pruneNetworks(ids: [DeletableNetworkID])
  case disconnect(container: ContainerID, network: NetworkID)
  /// `wasRunning` is the state the user was shown; approval is refused when the machine no longer matches it.
  case deleteMachine(MachineName, wasRunning: Bool)
  case startMachine(MachineName, warning: MemoryWarning)
}

public enum ConfirmationRole: Sendable, Equatable {
  case destructive
  case standard
}

public enum ConfirmationOrigin: Sendable, Equatable {
  case window
  case menuBar
}

public enum ConfirmationOutcome: Sendable, Equatable {
  case started
  /// The request was consumed and nothing was executed.
  case rejectedBusy(reason: String)
  case notPending

  enum RejectedAction {
    case delete
    case disconnect
  }

  static func dockerNotReady(_ action: RejectedAction) -> ConfirmationOutcome {
    switch action {
    case .delete:
      .rejectedBusy(
        reason: String(
          localized: "Docker is unavailable, so the deletion was not performed.", bundle: #bundle))
    case .disconnect:
      .rejectedBusy(
        reason: String(
          localized: "Docker is unavailable, so the disconnection was not performed.",
          bundle: #bundle))
    }
  }

  static var anotherDeletionInProgress: ConfirmationOutcome {
    .rejectedBusy(
      reason: String(localized: "Another deletion is in progress, so the deletion was not performed.", bundle: #bundle))
  }

  static func containerBusy(_ action: RejectedAction) -> ConfirmationOutcome {
    switch action {
    case .delete:
      .rejectedBusy(
        reason: String(
          localized: "This container is running another operation, so the deletion was not performed.",
          bundle: #bundle))
    case .disconnect:
      .rejectedBusy(
        reason: String(
          localized: "This container is running another operation, so the disconnection was not performed.",
          bundle: #bundle))
    }
  }
}

public struct ConfirmationItemGroup: Sendable, Equatable {
  public let title: String?
  public let items: [String]

  public init(title: String?, items: [String]) {
    self.title = title
    self.items = items
  }
}

public struct ConfirmationRequest: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let intent: DestructiveIntent
  public let origin: ConfirmationOrigin
  public let title: String
  public let message: String
  /// Volume prune uses two groups, anonymous and named.
  public let itemGroups: [ConfirmationItemGroup]
  public let confirmLabel: String
  public let confirmRole: ConfirmationRole

  public init(
    id: UUID = UUID(),
    intent: DestructiveIntent,
    origin: ConfirmationOrigin,
    title: String,
    message: String,
    itemGroups: [ConfirmationItemGroup],
    confirmLabel: String,
    confirmRole: ConfirmationRole = .destructive
  ) {
    self.id = id
    self.intent = intent
    self.origin = origin
    self.title = title
    self.message = message
    self.itemGroups = itemGroups
    self.confirmLabel = confirmLabel
    self.confirmRole = confirmRole
  }

  public init(
    intent: DestructiveIntent, title: String, message: String, item: String, confirmLabel: String,
    confirmRole: ConfirmationRole = .destructive
  ) {
    self.init(
      intent: intent, origin: .window, title: title, message: message,
      itemGroups: [ConfirmationItemGroup(title: nil, items: [item])], confirmLabel: confirmLabel,
      confirmRole: confirmRole)
  }

  public func isShown(on surface: ConfirmationOrigin) -> Bool {
    origin == surface
  }
}
