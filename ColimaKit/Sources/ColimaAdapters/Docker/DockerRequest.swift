import Foundation

struct DockerRequest: Sendable {
  enum Method: Sendable {
    case get, post, delete
  }

  var method: Method
  var segments: [String]
  var query: [URLQueryItem]
  var jsonBody: [UInt8]?

  init(_ method: Method, _ segments: [String], query: [URLQueryItem] = [], jsonBody: [UInt8]? = nil)
  {
    self.method = method
    self.segments = segments
    self.query = query
    self.jsonBody = jsonBody
  }

  /// Only unreserved characters stay literal, so an ID or name containing `/` or `?` cannot change the route.
  var target: String {
    var target = "/" + segments.map(Self.encode).joined(separator: "/")
    if !query.isEmpty {
      target +=
        "?"
        + query.map { Self.encode($0.name) + "=" + Self.encode($0.value ?? "") }.joined(
          separator: "&")
    }
    return target
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  private static func encode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
  }
}

struct DockerResponse: Sendable, Equatable {
  let status: Int
  let body: [UInt8]
}

enum DockerDeadline: Sendable {
  case read
  /// Start, stop, restart, remove, and other changes that the engine may take long to finish.
  case mutate
}
