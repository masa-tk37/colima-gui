import Darwin
import Dispatch
import Foundation
import Synchronization

enum TestServerError: Error {
  case socketPathTooLong(String)
  case posix(call: String, errno: Int32)
}

final class TestUnixHTTPServer: Sendable {
  let socketPath: String

  private struct Route {
    let matches: @Sendable (RecordedRequest) -> Bool
    let behaviors: [ScriptedBehavior]
    var served = 0
  }

  private struct State {
    var routes: [Route] = []
    var requests: [RecordedRequest] = []
    var connections: [Int: SocketConnection] = [:]
    var gates: [ResponseGate] = []
    var nextConnectionID = 0
    var stopped = false
    var acceptSource: DispatchSourceRead?
  }

  private let listenFD: Int32
  private let state = Mutex(State())
  private let stopSignal = StopSignal()
  private let serving = DispatchGroup()

  static func start() throws -> TestUnixHTTPServer {
    // sun_path holds 104 bytes on macOS, which rules out most deep directories.
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("cgs-\(UUID().uuidString.prefix(8)).sock").path
    let fd = try bindListeningSocket(at: path)
    let server = TestUnixHTTPServer(socketPath: path, listenFD: fd)
    server.beginAccepting()
    return server
  }

  private init(socketPath: String, listenFD: Int32) {
    self.socketPath = socketPath
    self.listenFD = listenFD
  }

  deinit { stop() }

  /// The n-th matching request gets the n-th behavior and the last repeats; routes are tried in registration order.
  func script(method: String? = nil, path: String? = nil, _ behaviors: ScriptedBehavior...) {
    script(
      matching: { request in
        (method == nil || request.method == method) && (path == nil || request.path == path)
      }, behaviors)
  }

  func script(
    matching matches: @escaping @Sendable (RecordedRequest) -> Bool,
    _ behaviors: ScriptedBehavior...
  ) {
    script(matching: matches, behaviors)
  }

  var requests: [RecordedRequest] { state.withLock { $0.requests } }

  func waitForRequests(count: Int, timeout: Duration = .seconds(10)) async -> Bool {
    await pollUntil(timeout: timeout) { requests.count >= count }
  }

  func stop() {
    let snapshot = state.withLock {
      state -> (DispatchSourceRead?, [SocketConnection], [ResponseGate])? in
      guard !state.stopped else { return nil }
      state.stopped = true
      defer { state.acceptSource = nil }
      return (state.acceptSource, Array(state.connections.values), state.gates)
    }
    guard let (source, connections, gates) = snapshot else { return }

    stopSignal.fire()
    for gate in gates { gate.release() }
    if let source {
      let cancelled = DispatchSemaphore(value: 0)
      source.setCancelHandler { cancelled.signal() }
      source.cancel()
      cancelled.wait()
    }
    Darwin.close(listenFD)
    unlink(socketPath)
    for connection in connections { connection.shutdown() }
    serving.wait()
  }

  private func script(
    matching matches: @escaping @Sendable (RecordedRequest) -> Bool, _ behaviors: [ScriptedBehavior]
  ) {
    precondition(!behaviors.isEmpty, "a route needs at least one behavior")
    state.withLock { $0.routes.append(Route(matches: matches, behaviors: behaviors)) }
  }

  private func beginAccepting() {
    let source = DispatchSource.makeReadSource(
      fileDescriptor: listenFD, queue: DispatchQueue(label: "TestUnixHTTPServer.accept"))
    source.setEventHandler { [weak self] in self?.acceptPending() }
    state.withLock { $0.acceptSource = source }
    source.resume()
  }

  private func acceptPending() {
    while true {
      let fd = Darwin.accept(listenFD, nil, nil)
      if fd < 0 { return }
      configureAcceptedSocket(fd)
      let connection = SocketConnection(fd: fd)
      let id = state.withLock { state -> Int? in
        guard !state.stopped else { return nil }
        state.nextConnectionID += 1
        state.connections[state.nextConnectionID] = connection
        return state.nextConnectionID
      }
      guard let id else {
        connection.close()
        return
      }
      serving.enter()
      Thread.detachNewThread { [self] in
        defer {
          connection.close()
          state.withLock { _ = $0.connections.removeValue(forKey: id) }
          serving.leave()
        }
        serve(connection)
      }
    }
  }

  private func serve(_ connection: SocketConnection) {
    var reader = HTTPRequestReader(connection: connection)
    guard let request = reader.readRequest() else { return }
    switch nextBehavior(for: request) {
    case .dropConnection:
      return
    case .reply(let reply):
      serveReply(reply, to: request, on: connection)
    case .stream(let stream):
      serveStream(stream, on: connection)
    }
  }

  private func nextBehavior(for request: RecordedRequest) -> ScriptedBehavior {
    state.withLock { state in
      state.requests.append(request)
      guard let index = state.routes.firstIndex(where: { $0.matches(request) }) else {
        let note = "no scripted behavior for \(request.method) \(request.target)"
        return .reply(ScriptedReply(status: 404, body: Array(note.utf8)))
      }
      let route = state.routes[index]
      state.routes[index].served += 1
      return route.behaviors[min(route.served, route.behaviors.count - 1)]
    }
  }

  private func serveReply(
    _ reply: ScriptedReply, to request: RecordedRequest, on connection: SocketConnection
  ) {
    if reply.delay > .zero, !stopSignal.sleep(for: reply.delay) { return }
    if let gate = reply.gate {
      guard waitOnGate(gate) else { return }
    }
    let bodyless = reply.status == 204 || reply.status == 304 || reply.status / 100 == 1
    var head = "HTTP/1.1 \(reply.status) \(httpReasonPhrase(reply.status))\r\n"
    for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
    if !bodyless, !reply.headers.keys.contains(where: { $0.lowercased() == "content-length" }) {
      head += "Content-Length: \(reply.body.count)\r\n"
    }
    head += "Connection: close\r\n\r\n"

    var bytes = Array(head.utf8)
    if !bodyless, request.method != "HEAD" {
      bytes += reply.body.prefix(reply.truncatedBodyLength ?? reply.body.count)
    }
    _ = connection.write(bytes)
  }

  private func waitOnGate(_ gate: ResponseGate) -> Bool {
    let stopped = state.withLock { state in
      if !state.stopped { state.gates.append(gate) }
      return state.stopped
    }
    if stopped { return false }
    gate.wait()
    return !stopSignal.isStopped
  }

  private func serveStream(_ stream: ScriptedStream, on connection: SocketConnection) {
    var head = "HTTP/1.1 \(stream.status) \(httpReasonPhrase(stream.status))\r\n"
    for (name, value) in stream.headers { head += "\(name): \(value)\r\n" }
    head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    guard connection.write(Array(head.utf8)) else { return }

    stream.attach(connection)
    var discarded: [UInt8] = []
    while connection.read(into: &discarded) { discarded.removeAll(keepingCapacity: true) }
    stream.detach()
  }
}
