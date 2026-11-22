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
  public let capacity: Int
  public private(set) var points: [UsagePoint] = []

  public init(capacity: Int) {
    precondition(capacity > 0, "UsageSeries capacity must be positive")
    self.capacity = capacity
  }

  public mutating func appendGap(at time: Date) {
    append(nil, at: time)
  }

  public mutating func append(_ value: Double?, at time: Date) {
    points.append(UsagePoint(time: time, value: value))
    if points.count > capacity {
      points.removeFirst(points.count - capacity)
    }
  }
}
