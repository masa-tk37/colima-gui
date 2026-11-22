import Darwin
import Foundation

enum RawSocketError: Error {
  case pathTooLong
  case socket(errno: Int32)
  case connect(errno: Int32)
  case write(errno: Int32)
}

enum RawReadOutcome: Equatable {
  case data([UInt8])
  case eof
  case timedOut
}

/// A bare connect(2)/write(2)/read(2) client, so the test server is checked without AsyncHTTPClient.
final class RawSocketClient {
  private var fd: Int32

  init(path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw RawSocketError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path.utf8)
      buffer[path.utf8.count] = 0
    }

    fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RawSocketError.socket(errno: errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(fd)
      fd = -1
      throw RawSocketError.connect(errno: code)
    }
  }

  deinit { close() }

  func close() {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
  }

  func send(_ text: String) throws {
    try send(Array(text.utf8))
  }

  func send(_ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        throw RawSocketError.write(errno: errno)
      }
      offset += written
    }
  }

  func read(timeout: Duration = .seconds(10)) -> RawReadOutcome {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32(
      clamping: timeout.components.seconds * 1000
        + timeout.components.attoseconds / 1_000_000_000_000_000)
    let ready = poll(&descriptor, 1, milliseconds)
    if ready == 0 { return .timedOut }
    if ready < 0 { return errno == EINTR ? read(timeout: timeout) : .eof }

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if count > 0 { return .data(Array(buffer[..<count])) }
    if count < 0, errno == EINTR { return read(timeout: timeout) }
    return .eof
  }

  func readToEOF(timeout: Duration = .seconds(30)) -> (bytes: [UInt8], reachedEOF: Bool) {
    var collected: [UInt8] = []
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      switch read(timeout: deadline - clock.now) {
      case .data(let bytes): collected += bytes
      case .eof: return (collected, true)
      case .timedOut: return (collected, false)
      }
    }
    return (collected, false)
  }

  func read(untilContains marker: String, timeout: Duration = .seconds(10)) -> [UInt8]? {
    var collected: [UInt8] = []
    let needle = Array(marker.utf8)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if collected.contains(subsequence: needle) { return collected }
      guard case .data(let bytes) = read(timeout: deadline - clock.now) else { return nil }
      collected += bytes
    }
    return collected.contains(subsequence: needle) ? collected : nil
  }
}

struct ParsedHTTPResponse {
  let status: Int
  let headers: [String: String]
  let body: [UInt8]

  init?(_ bytes: [UInt8]) {
    guard let separator = bytes.range(of: Array("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let statusLine = lines.removeFirst().split(separator: " ")
    guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
    self.status = status
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    self.headers = headers
    body = Array(bytes[separator.upperBound...])
  }
}
