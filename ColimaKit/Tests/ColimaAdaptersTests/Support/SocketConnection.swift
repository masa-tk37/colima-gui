import Darwin
import Synchronization

/// One accepted socket. Only the serving thread closes it; other threads wake it with `shutdown()`.
final class SocketConnection: Sendable {
  private let fd: Int32
  private let closed = Mutex(false)

  init(fd: Int32) {
    self.fd = fd
  }

  func read(into buffer: inout [UInt8]) -> Bool {
    var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        buffer.append(contentsOf: scratch[..<count])
        return true
      }
      if count < 0, errno == EINTR { continue }
      return false
    }
  }

  func write(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += written
    }
    return true
  }

  func shutdown() {
    closed.withLock { isClosed in
      if !isClosed { Darwin.shutdown(fd, SHUT_RDWR) }
    }
  }

  /// `SHUT_RDWR` on Darwin can discard bytes the peer has not read yet.
  func shutdownWrite() {
    closed.withLock { isClosed in
      if !isClosed { Darwin.shutdown(fd, SHUT_WR) }
    }
  }

  func close() {
    closed.withLock { isClosed in
      if !isClosed {
        isClosed = true
        Darwin.close(fd)
      }
    }
  }
}
