import Foundation

public enum EngineGuidance: Sendable, Equatable {
  case restartVM
  case startVM
  case retryOnly

  public init(observation: VMObservation) {
    switch observation {
    case .present(let instance):
      self = instance.runState.isRunning ? .restartVM : .startVM
    case .absent, .unknown:
      self = .retryOnly
    }
  }

  public var message: String {
    switch self {
    case .restartVM:
      String(localized: "Could not connect to the Docker engine. The VM is running. Restart the VM.", bundle: #bundle)
    case .startVM:
      String(localized: "Could not connect to the Docker engine. The VM is stopped. Start the VM.", bundle: #bundle)
    case .retryOnly:
      String(localized: "Could not connect to the Docker engine. Check the VM state and try again.", bundle: #bundle)
    }
  }
}
