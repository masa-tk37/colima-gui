import Darwin
import Dispatch
import Foundation
import Synchronization

func configureAcceptedSocket(_ fd: Int32) {
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
  var on: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  // A client that stops reading must not wedge a writer, and with it `stop()`, forever.
  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

func bindListeningSocket(at path: String) throws -> Int32 {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw TestServerError.socketPathTooLong(path)
  }
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: path.utf8)
    buffer[path.utf8.count] = 0
  }

  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw TestServerError.posix(call: "socket", errno: errno) }
  unlink(path)
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard bound == 0, listen(fd, 64) == 0 else {
    let code = errno
    Darwin.close(fd)
    throw TestServerError.posix(call: "bind/listen", errno: code)
  }
  // Non-blocking so the accept loop drains the backlog and returns at EAGAIN.
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  return fd
}

final class StopSignal: Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let stopped = Mutex(false)

  var isStopped: Bool { stopped.withLock { $0 } }

  func fire() {
    let first = stopped.withLock { value in
      defer { value = true }
      return !value
    }
    if first { semaphore.signal() }
  }

  func sleep(for duration: Duration) -> Bool {
    let nanoseconds =
      Int(duration.components.seconds) * 1_000_000_000
      + Int(duration.components.attoseconds / 1_000_000_000)
    if semaphore.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success {
      semaphore.signal()
      return false
    }
    return true
  }
}

/// A fixed ASCII phrase; `HTTPURLResponse.localizedString` follows the user's locale.
func httpReasonPhrase(_ status: Int) -> String {
  switch status {
  case 200: "OK"
  case 201: "Created"
  case 204: "No Content"
  case 304: "Not Modified"
  case 400: "Bad Request"
  case 404: "Not Found"
  case 409: "Conflict"
  case 500: "Internal Server Error"
  case 503: "Service Unavailable"
  default: "Status"
  }
}
