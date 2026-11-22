import AsyncHTTPClient
import ColimaCore
import Foundation
import Network

struct DeadlineExpired: Error {}

/// Bounds the whole operation, including body consumption, which `HTTPClient.execute(_:timeout:)` does not.
func withDeadline<T: Sendable>(
  _ limit: Duration,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T?.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: limit)
      return nil
    }
    defer { group.cancelAll() }
    guard let first = try await group.next(), let value = first else { throw DeadlineExpired() }
    return value
  }
}

extension DockerHTTPTransport {
  /// Once the head has arrived the engine was reachable, so a transport error of any other kind
  /// (Network.framework reports a peer reset as `ENETDOWN`) means the connection was cut.
  static func classifyAfterHead(_ error: Error) -> Error {
    switch error {
    case is CancellationError, is DockerError, is HTTPClientError: error
    default: DockerError.connectionLost(detail: String(describing: error))
    }
  }

  private static func isConnectFailure(_ error: Error) -> Bool {
    guard case .posix(let code) = error as? NWError else { return false }
    return [.ENOENT, .ECONNREFUSED, .ENOTDIR, .ENOTSOCK, .EACCES, .EPERM].contains(code)
  }

  /// The caller's cancellation is checked first: it also makes the underlying client report arbitrary errors.
  static func classify(_ error: Error) -> DockerError {
    if Task.isCancelled || error is CancellationError { return .cancelled }
    if let docker = error as? DockerError { return docker }
    if error is DeadlineExpired { return .timedOut }
    guard let http = error as? HTTPClientError else {
      return isConnectFailure(error)
        ? .engineUnreachable(detail: String(describing: error))
        : .connectionLost(detail: String(describing: error))
    }
    switch http {
    case .getConnectionFromPoolTimeout, .deadlineExceeded, .readTimeout, .writeTimeout:
      return .timedOut
    case .remoteConnectionClosed:
      return .connectionLost(detail: http.description)
    case .connectTimeout, .alreadyShutdown:
      return .engineUnreachable(detail: http.description)
    default:
      // Includes `.cancelled` from a client shutdown. Unreachable would advise restarting a VM that answered.
      return .connectionLost(detail: http.description)
    }
  }
}

extension DockerRequest.Method {
  var label: String {
    switch self {
    case .get: "GET"
    case .post: "POST"
    case .delete: "DELETE"
    }
  }
}

extension DockerError {
  var logLabel: String {
    switch self {
    case .engineUnreachable(let detail): "unreachable (\(detail))"
    case .api(let status, _): "api \(status)"
    case .connectionLost(let detail): "connection lost (\(detail))"
    case .timedOut: "timed out"
    case .unexpectedResponse(let detail): "unexpected response (\(detail))"
    case .cancelled: "cancelled"
    }
  }
}
