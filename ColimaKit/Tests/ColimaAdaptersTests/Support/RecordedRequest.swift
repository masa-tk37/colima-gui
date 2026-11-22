import Foundation

struct RecordedRequest: Sendable, Equatable {
  let method: String
  let target: String
  let path: String
  let query: String?
  /// Header names are lowercased; a repeated name keeps its last value.
  let headers: [String: String]
  let body: [UInt8]

  var queryItems: [String: String] {
    guard let query, let components = URLComponents(string: "http://host/?\(query)") else {
      return [:]
    }
    return (components.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
  }
}
