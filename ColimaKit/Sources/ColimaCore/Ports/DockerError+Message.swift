import Foundation

extension DockerError {
  public var displayMessage: String {
    switch self {
    case .api(_, let message): message
    case .engineUnreachable: String(localized: "Could not connect to the Docker engine.", bundle: #bundle)
    case .connectionLost:
      String(localized: "The connection was lost. Check the list to see whether the operation completed.", bundle: #bundle)
    case .timedOut: String(localized: "The Docker engine did not respond.", bundle: #bundle)
    case .unexpectedResponse: String(localized: "Could not interpret the Docker engine's response.", bundle: #bundle)
    case .cancelled: String(localized: "The operation was interrupted.", bundle: #bundle)
    }
  }
}
