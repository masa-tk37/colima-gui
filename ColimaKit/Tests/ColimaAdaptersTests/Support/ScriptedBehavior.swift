import Foundation
import Synchronization

enum ScriptedBehavior: Sendable {
  case reply(ScriptedReply)
  case dropConnection
  case stream(ScriptedStream)
}

struct ScriptedReply: Sendable {
  var status: Int
  var headers: [String: String]
  var body: [UInt8]
  var delay: Duration
  var gate: ResponseGate?
  /// Writes only this many body bytes while still declaring the full `Content-Length`, then closes.
  var truncatedBodyLength: Int?

  init(
    status: Int = 200,
    headers: [String: String] = [:],
    body: [UInt8] = [],
    delay: Duration = .zero,
    gate: ResponseGate? = nil,
    truncatedBodyLength: Int? = nil
  ) {
    self.status = status
    self.headers = headers
    self.body = body
    self.delay = delay
    self.gate = gate
    self.truncatedBodyLength = truncatedBodyLength
  }
}

/// Create through `TestUnixHTTPServer.makeGate()` so that `stop()` can release a thread still waiting on it.
final class ResponseGate: Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let released = Mutex(false)

  var isReleased: Bool { released.withLock { $0 } }

  func release() {
    let first = released.withLock { value in
      defer { value = true }
      return !value
    }
    if first { semaphore.signal() }
  }

  func wait() {
    semaphore.wait()
    semaphore.signal()
  }
}

func pollUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}
