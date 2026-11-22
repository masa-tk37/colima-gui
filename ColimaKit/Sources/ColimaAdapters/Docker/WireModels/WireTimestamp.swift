import Foundation

/// A point in time as the engine reports it: epoch seconds in list responses, RFC3339 (nanoseconds, `Z` or an
/// offset) in inspect responses.
struct WireTimestamp: Decodable, Equatable {
  let date: Date

  init(date: Date) {
    self.date = date
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let seconds = try? container.decode(Double.self) {
      date = Date(timeIntervalSince1970: seconds)
      return
    }
    let text = try container.decode(String.self)
    guard let parsed = Self.parse(rfc3339: text) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Not an RFC3339 timestamp: \(text)")
    }
    date = parsed
  }

  static func parse(rfc3339 text: String) -> Date? {
    let (wholeSeconds, fraction) = splitFraction(text)
    guard let base = try? Date(wholeSeconds, strategy: Self.strategy) else { return nil }
    return base.addingTimeInterval(fraction)
  }

  private static let strategy = Date.ISO8601FormatStyle().timeZoneSeparator(.colon)

  // The format style rejects more than 3 fractional digits, and the engine sends up to 9.
  private static func splitFraction(_ text: String) -> (String, Double) {
    guard let dot = text.firstIndex(of: ".") else { return (text, 0) }
    let digitsStart = text.index(after: dot)
    let digitsEnd =
      text[digitsStart...].firstIndex(where: { !$0.isASCII || !$0.isNumber }) ?? text.endIndex
    let digits = text[digitsStart..<digitsEnd]
    let fraction = Double("0." + digits) ?? 0
    return (String(text[..<dot]) + String(text[digitsEnd...]), fraction)
  }
}
