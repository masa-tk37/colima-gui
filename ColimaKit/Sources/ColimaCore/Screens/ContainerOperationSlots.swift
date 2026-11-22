import Observation

/// One operation slot per container ID. The container and network screens share one instance so an
/// operation started from either side keeps the other from touching the same container.
///
/// Reserve before the first `await` of an operation: on the main actor that makes the check and the
/// reservation one step, so two requests cannot both pass.
@MainActor @Observable
public final class ContainerOperationSlots {
  public private(set) var busyIDs: Set<ContainerID> = []

  public init() {}

  public func isBusy(_ id: ContainerID) -> Bool {
    busyIDs.contains(id)
  }

  public func reserve(_ id: ContainerID) -> Bool {
    busyIDs.insert(id).inserted
  }

  public func release(_ id: ContainerID) {
    busyIDs.remove(id)
  }
}
