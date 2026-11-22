import AsyncHTTPClient
import ColimaCore
import Foundation
import Synchronization

/// HTTP over the engine's Unix socket. Requests and log streams use separate clients so that followed logs,
/// which hold a connection each for as long as they run, can never starve the periodic requests.
/// Call `shutdown()` before releasing it: AsyncHTTPClient traps in debug builds when dropped while running.
final class DockerHTTPTransport: Sendable {
  static let maxBodyBytes = 16 * 1024 * 1024
  static let requestConnectionLimit = 8
  static let logConnectionLimit = 16

  struct Timeouts: Sendable {
    var read: Duration
    var mutate: Duration
    /// Bounds only the wait for the response head of a log stream; its body is unbounded.
    var logHead: Duration

    static let standard = Timeouts(read: .seconds(10), mutate: .seconds(60), logHead: .seconds(10))
  }

  private let socketPath: String
  private let timeouts: Timeouts
  private let maxBodyBytes: Int
  private let requestClient: HTTPClient
  private let logClient: HTTPClient
  private let shutDown = Mutex(false)

  init(
    socketPath: String,
    timeouts: Timeouts = .standard,
    maxBodyBytes: Int = DockerHTTPTransport.maxBodyBytes,
    requestConnectionLimit: Int = DockerHTTPTransport.requestConnectionLimit,
    logConnectionLimit: Int = DockerHTTPTransport.logConnectionLimit
  ) {
    self.socketPath = socketPath
    self.timeouts = timeouts
    self.maxBodyBytes = maxBodyBytes
    requestClient = Self.makeClient(connectionLimit: requestConnectionLimit)
    logClient = Self.makeClient(connectionLimit: logConnectionLimit)
  }

  private static func makeClient(connectionLimit: Int) -> HTTPClient {
    var configuration = HTTPClient.Configuration()
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = connectionLimit
    // A missing or refused socket is the normal state while the VM is stopped; report it at once
    // instead of retrying with backoff until the request deadline.
    configuration.connectionPool.retryConnectionEstablishment = false
    configuration.networkFrameworkWaitForConnectivity = false
    configuration.redirectConfiguration = .disallow
    return HTTPClient(configuration: configuration)
  }

  func shutdown() async {
    let first = shutDown.withLock { done in
      defer { done = true }
      return !done
    }
    guard first else { return }
    for client in [requestClient, logClient] {
      do {
        try await client.shutdown()
      } catch {
        ColimaLog.docker.error(
          "HTTP client shutdown failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  // MARK: Requests

  func send(_ request: DockerRequest, deadline: DockerDeadline) async throws(DockerError)
    -> DockerResponse
  {
    let limit = deadline == .read ? timeouts.read : timeouts.mutate
    do {
      try Task.checkCancellation()
      let response = try await withDeadline(limit) {
        try await self.exchange(request, limit: limit)
      }
      // Cancelling the consumer can end a body early without an error; never hand that back as complete.
      try Task.checkCancellation()
      ColimaLog.docker.debug("\(request.method.label, privacy: .public) -> \(response.status)")
      return response
    } catch {
      throw logged(Self.classify(error), method: request.method)
    }
  }

  private func exchange(_ request: DockerRequest, limit: Duration) async throws -> DockerResponse {
    let response = try await requestClient.execute(
      try httpRequest(for: request), timeout: .nanoseconds(Self.nanoseconds(limit)))
    let status = Int(response.status.code)
    let body = try await Self.collectAfterHead(response.body, limit: maxBodyBytes)
    if status >= 400 {
      throw DockerError.api(status: status, message: Self.errorMessage(status: status, body: body))
    }
    return DockerResponse(status: status, body: body)
  }

  // MARK: Streams

  func stream(
    _ request: DockerRequest,
    onChunk: @Sendable ([UInt8]) async -> Void
  ) async throws(DockerError) {
    do {
      try Task.checkCancellation()
      let response = try await logClient.execute(
        try httpRequest(for: request),
        timeout: .nanoseconds(Self.nanoseconds(timeouts.logHead))
      )
      let status = Int(response.status.code)
      if status >= 400 {
        let body = try await withDeadline(timeouts.logHead) {
          try await Self.collectAfterHead(response.body, limit: self.maxBodyBytes)
        }
        throw DockerError.api(
          status: status, message: Self.errorMessage(status: status, body: body))
      }
      do {
        for try await buffer in response.body {
          await onChunk(Array(buffer.readableBytesView))
        }
      } catch {
        throw Self.classifyAfterHead(error)
      }
      try Task.checkCancellation()
    } catch {
      throw logged(Self.classify(error), method: request.method)
    }
  }

  // MARK: Helpers

  private func httpRequest(for request: DockerRequest) throws -> HTTPClientRequest {
    guard let url = URL(httpURLWithSocketPath: socketPath, uri: request.target) else {
      throw DockerError.unexpectedResponse(detail: "invalid request target")
    }
    var http = HTTPClientRequest(url: url.absoluteString)
    // AsyncHTTPClient derives Host from the URL's host and sends none for a Unix socket.
    http.headers.add(name: "Host", value: "docker")
    switch request.method {
    case .get: http.method = .GET
    case .post: http.method = .POST
    case .delete: http.method = .DELETE
    }
    if let payload = request.jsonBody {
      http.headers.add(name: "Content-Type", value: "application/json")
      http.body = .bytes(payload)
    }
    return http
  }

  private static func collectAfterHead(_ body: HTTPClientResponse.Body, limit: Int) async throws
    -> [UInt8]
  {
    var bytes: [UInt8] = []
    do {
      for try await buffer in body {
        guard bytes.count + buffer.readableBytes <= limit else {
          throw DockerError.unexpectedResponse(detail: "response body exceeds \(limit) bytes")
        }
        bytes += buffer.readableBytesView
      }
    } catch {
      throw classifyAfterHead(error)
    }
    return bytes
  }

  private static func errorMessage(status: Int, body: [UInt8]) -> String {
    if let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
      let message = object["message"] as? String
    {
      return message
    }
    let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "HTTP \(status)" : text
  }

  private static func nanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
  }

  private func logged(_ error: DockerError, method: DockerRequest.Method) -> DockerError {
    if error != .cancelled {
      ColimaLog.docker.error(
        "\(method.label, privacy: .public) failed: \(error.logLabel, privacy: .public)")
    }
    return error
  }
}
