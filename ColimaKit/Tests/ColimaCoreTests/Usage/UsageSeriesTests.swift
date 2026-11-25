import Foundation
import Testing

@testable import ColimaCore

private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func newSeriesIsEmpty() {
  let series = UsageSeries(window: 10)
  #expect(series.points.isEmpty)
}

@Test func pointsKeepInsertionOrderWithGapsInline() {
  var series = UsageSeries(window: 10)
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
  var series = UsageSeries(window: 10)
  series.append(nil, at: time(0))
  series.append(Optional(4.0), at: time(3))
  #expect(series.points.map(\.value) == [nil, 4.0])
}

@Test func pointsOlderThanTheWindowAreDroppedOnAppend() {
  var series = UsageSeries(window: 10)
  for seconds in stride(from: 0.0, through: 15, by: 3) { series.append(seconds, at: time(seconds)) }
  #expect(series.points.map(\.value) == [6, 9, 12, 15])
}

@Test func aPointExactlyAtTheWindowEdgeIsKept() {
  var series = UsageSeries(window: 10)
  series.append(1, at: time(0))
  series.append(2, at: time(10))
  #expect(series.points.map(\.value) == [1, 2])
}

@Test func anAppendAfterALongPauseDropsAllEarlierPoints() {
  var series = UsageSeries(window: 10)
  series.append(1, at: time(0))
  series.append(2, at: time(3))
  series.append(3, at: time(3600))
  #expect(series.points == [UsagePoint(time: time(3600), value: 3)])
}

@Test func gapsAreDroppedByTheSameWindow() {
  var series = UsageSeries(window: 10)
  series.appendGap(at: time(0))
  series.append(1, at: time(5))
  series.appendGap(at: time(11))
  #expect(
    series.points == [UsagePoint(time: time(5), value: 1), UsagePoint(time: time(11), value: nil)])
}

@Test func aTimeEarlierThanTheLastPointStartsTheSeriesOver() {
  var series = UsageSeries(window: 10)
  series.append(1, at: time(100))
  series.append(2, at: time(103))
  series.append(3, at: time(50))
  #expect(series.points == [UsagePoint(time: time(50), value: 3)])
}

@Test func windowIsExposed() {
  #expect(UsageSeries(window: 600).window == 600)
}
