import Synchronization

final class ScriptedStream: Sendable {
  let status: Int
  let headers: [String: String]

  private enum Operation {
    case chunk([UInt8])
    case finish
    case abort
  }

  private struct State {
    var connection: SocketConnection?
    var pending: [Operation] = []
    var opened = false
    var ended = false
    var clientDisconnected = false
  }

  private let state = Mutex(State())

  init(status: Int = 200, headers: [String: String] = [:]) {
    self.status = status
    self.headers = headers
  }

  var isOpen: Bool { state.withLock { $0.opened } }
  var clientDisconnected: Bool { state.withLock { $0.clientDisconnected } }

  func send(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    apply(.chunk(bytes))
  }

  func send(_ text: String) {
    send(Array(text.utf8))
  }

  func finish() {
    apply(.finish)
  }

  func abort() {
    apply(.abort)
  }

  func waitUntilOpened(timeout: Duration = .seconds(10)) async -> Bool {
    await pollUntil(timeout: timeout) { isOpen }
  }

  func waitUntilClientDisconnected(timeout: Duration = .seconds(10)) async -> Bool {
    await pollUntil(timeout: timeout) { clientDisconnected }
  }

  func attach(_ connection: SocketConnection) {
    state.withLock { state in
      state.connection = connection
      state.opened = true
      for operation in state.pending {
        Self.perform(operation, on: connection)
      }
      state.pending = []
    }
  }

  func detach() {
    state.withLock { state in
      state.connection = nil
      if !state.ended { state.clientDisconnected = true }
    }
  }

  private func apply(_ operation: Operation) {
    state.withLock { state in
      guard !state.ended else { return }
      switch operation {
      case .finish, .abort: state.ended = true
      case .chunk: break
      }
      if let connection = state.connection {
        Self.perform(operation, on: connection)
      } else {
        state.pending.append(operation)
      }
    }
  }

  private static func perform(_ operation: Operation, on connection: SocketConnection) {
    switch operation {
    case .chunk(let bytes):
      _ = connection.write(
        Array(String(bytes.count, radix: 16).utf8) + [13, 10] + bytes + [13, 10])
    case .finish:
      _ = connection.write(Array("0\r\n\r\n".utf8))
      connection.shutdownWrite()
    case .abort:
      connection.shutdownWrite()
    }
  }
}
