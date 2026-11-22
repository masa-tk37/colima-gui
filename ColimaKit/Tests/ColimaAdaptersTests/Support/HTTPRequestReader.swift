import Foundation

struct HTTPRequestReader {
  private let connection: SocketConnection
  private var buffer: [UInt8] = []

  private static let headLimit = 1024 * 1024

  init(connection: SocketConnection) {
    self.connection = connection
  }

  mutating func readRequest() -> RecordedRequest? {
    guard let head = readHead() else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard requestLine.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    }

    let body: [UInt8]?
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      body = readChunkedBody()
    } else if let length = headers["content-length"].flatMap({ Int($0) }), length > 0 {
      body = readExactly(length)
    } else {
      body = []
    }
    guard let body else { return nil }

    let target = String(requestLine[1])
    let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    return RecordedRequest(
      method: String(requestLine[0]),
      target: target,
      path: String(split[0]),
      query: split.count > 1 ? String(split[1]) : nil,
      headers: headers,
      body: body
    )
  }

  private mutating func readHead() -> String? {
    let terminator = Array("\r\n\r\n".utf8)
    while true {
      if let range = buffer.range(of: terminator) {
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return head
      }
      guard buffer.count < Self.headLimit, connection.read(into: &buffer) else { return nil }
    }
  }

  private mutating func readExactly(_ count: Int) -> [UInt8]? {
    while buffer.count < count {
      guard connection.read(into: &buffer) else { return nil }
    }
    defer { buffer.removeSubrange(..<count) }
    return Array(buffer[..<count])
  }

  private mutating func readLine() -> String? {
    let terminator = Array("\r\n".utf8)
    while true {
      if let range = buffer.range(of: terminator) {
        let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return line
      }
      guard connection.read(into: &buffer) else { return nil }
    }
  }

  private mutating func readChunkedBody() -> [UInt8]? {
    var body: [UInt8] = []
    while true {
      guard let sizeLine = readLine() else { return nil }
      let digits = sizeLine.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(
        in: .whitespaces)
      guard let size = Int(digits, radix: 16) else { return nil }
      if size == 0 {
        while let trailer = readLine(), !trailer.isEmpty {}
        return body
      }
      guard let chunk = readExactly(size), readExactly(2) != nil else { return nil }
      body += chunk
    }
  }
}
