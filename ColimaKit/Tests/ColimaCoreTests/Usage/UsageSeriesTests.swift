import Foundation
import Testing

@testable import ColimaCore

private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func newSeriesIsEmpty() {
  let series = UsageSeries(capacity: 3)
  #expect(series.points.isEmpty)
}

@Test func pointsKeepInsertionOrderWithGapsInline() {
  var series = UsageSeries(capacity: 5)
  series.append(1.5, at: time(0))
  series.appendGap(at: time(3))
  series.append(2.5, at: time(6))
  #expect(
    series.points == [
      UsagePoint(time: time(0), value: 1.5),
      UsagePoint(time: time(3), value: nil),
      UsagePoint(time: time(6), value: 2.5),
    ])
}

@Test func appendingOptionalValueMapsNilToGap() {
  var series = UsageSeries(capacity: 5)
  series.append(nil, at: time(0))
  series.append(Optional(4.0), at: time(3))
  #expect(series.points.map(\.value) == [nil, 4.0])
}

@Test func oldestPointsAreDroppedBeyondCapacity() {
  var series = UsageSeries(capacity: 3)
  for i in 0..<5 { series.append(Double(i), at: time(Double(i))) }
  #expect(series.points.map(\.value) == [2, 3, 4])
}

@Test func gapsCountTowardCapacity() {
  var series = UsageSeries(capacity: 2)
  series.append(1, at: time(0))
  series.append(2, at: time(1))
  series.appendGap(at: time(2))
  #expect(
    series.points == [UsagePoint(time: time(1), value: 2), UsagePoint(time: time(2), value: nil)])
}

@Test func capacityIsExposed() {
  #expect(UsageSeries(capacity: 200).capacity == 200)
}
