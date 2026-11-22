public enum DockerError: Error, Equatable {
  case engineUnreachable(detail: String)
  case api(status: Int, message: String)
  /// Dropped mid-request; the outcome is unknown.
  case connectionLost(detail: String)
  /// Includes waiting for a free pooled connection.
  case timedOut
  case unexpectedResponse(detail: String)
  case cancelled
}
