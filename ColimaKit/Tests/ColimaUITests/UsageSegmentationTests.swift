import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

struct UsageSegmentationTests {
  private let origin = Date(timeIntervalSinceReferenceDate: 1_000)

  private func time(_ offset: Int) -> Date {
    origin.addingTimeInterval(Double(offset))
  }

  private func points(_ values: [Double?]) -> [UsagePoint] {
    values.enumerated().map { UsagePoint(time: time($0.offset), value: $0.element) }
  }

  private func sample(_ offset: Int, _ value: Double) -> UsageSample {
    UsageSample(time: time(offset), value: value)
  }

  @Test func aSeriesWithoutGapsIsOneSegmentAndNoGaps() {
    let result = UsageSegmentation(points([1, 2, 3]))
    #expect(
      result.segments == [UsageSegment(id: 0, samples: [sample(0, 1), sample(1, 2), sample(2, 3)])])
    #expect(result.gaps.isEmpty)
  }

  @Test func anEmptySeriesHasNeitherSegmentsNorGaps() {
    let result = UsageSegmentation([])
    #expect(result.segments.isEmpty)
    #expect(result.gaps.isEmpty)
  }

  @Test func aGapInTheMiddleSplitsTheLineAndSpansFromTheLastToTheNextMeasuredPoint() {
    let result = UsageSegmentation(points([1, 2, nil, 4, 5]))
    #expect(
      result.segments == [
        UsageSegment(id: 0, samples: [sample(0, 1), sample(1, 2)]),
        UsageSegment(id: 1, samples: [sample(3, 4), sample(4, 5)]),
      ])
    #expect(result.gaps == [UsageGap(id: 0, start: time(1), end: time(3))])
  }

  @Test func consecutiveGapsFormOneGap() {
    let result = UsageSegmentation(points([1, nil, nil, nil, 5]))
    #expect(result.segments.count == 2)
    #expect(result.gaps == [UsageGap(id: 0, start: time(0), end: time(4))])
  }

  @Test func aLeadingGapSpansFromItsFirstPointToTheFirstMeasuredPoint() {
    let result = UsageSegmentation(points([nil, nil, 3, 4]))
    #expect(result.segments == [UsageSegment(id: 0, samples: [sample(2, 3), sample(3, 4)])])
    #expect(result.gaps == [UsageGap(id: 0, start: time(0), end: time(2))])
  }

  @Test func aTrailingGapSpansFromTheLastMeasuredPointToTheEndOfTheSeries() {
    let result = UsageSegmentation(points([1, 2, nil, nil]))
    #expect(result.segments == [UsageSegment(id: 0, samples: [sample(0, 1), sample(1, 2)])])
    #expect(result.gaps == [UsageGap(id: 0, start: time(1), end: time(3))])
  }

  @Test func aSingleTrailingGapPointIsDrawnFromTheLastMeasuredPoint() {
    let result = UsageSegmentation(points([1, 2, nil]))
    #expect(result.gaps == [UsageGap(id: 0, start: time(1), end: time(2))])
  }

  @Test func aMeasuredPointBetweenGapsStaysAsASinglePointSegment() {
    let result = UsageSegmentation(points([1, nil, 3, nil, 5, 6]))
    #expect(
      result.segments == [
        UsageSegment(id: 0, samples: [sample(0, 1)]),
        UsageSegment(id: 1, samples: [sample(2, 3)]),
        UsageSegment(id: 2, samples: [sample(4, 5), sample(5, 6)]),
      ])
    #expect(
      result.gaps == [
        UsageGap(id: 0, start: time(0), end: time(2)),
        UsageGap(id: 1, start: time(2), end: time(4)),
      ])
  }

  @Test func aSeriesOfOnlyGapsHasNoSegmentsAndOneGapOverTheWholeSeries() {
    let result = UsageSegmentation(points([nil, nil, nil]))
    #expect(result.segments.isEmpty)
    #expect(result.gaps == [UsageGap(id: 0, start: time(0), end: time(2))])
  }

  @Test func aLoneGapPointHasAnEmptySpan() {
    let result = UsageSegmentation(points([nil]))
    #expect(result.segments.isEmpty)
    #expect(result.gaps == [UsageGap(id: 0, start: time(0), end: time(0))])
  }
}
