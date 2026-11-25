import Foundation

public struct UsagePoint: Sendable, Equatable {
  public let time: Date
  public let value: Double?

  public init(time: Date, value: Double?) {
    self.time = time
    self.value = value
  }
}

public struct UsageSeries: Sendable, Equatable {
  public let window: TimeInterval
  public private(set) var points: [UsagePoint] = []

  public init(window: TimeInterval) {
    precondition(window > 0, "UsageSeries window must be positive")
    self.window = window
  }

  public mutating func appendGap(at time: Date) {
    append(nil, at: time)
  }

  public mutating func append(_ value: Double?, at time: Date) {
    // After a clock is set back, earlier points would lie past the chart's axis, which ends at the newest point.
    if let last = points.last, time < last.time {
      points.removeAll()
    }
    let oldest = time.addingTimeInterval(-window)
    points.removeAll { $0.time < oldest }
    points.append(UsagePoint(time: time, value: value))
  }
}
