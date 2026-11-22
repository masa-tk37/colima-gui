import ColimaCore
import Foundation

struct UsageSample: Equatable {
  let time: Date
  let value: Double
}

struct UsageSegment: Equatable, Identifiable {
  let id: Int
  let samples: [UsageSample]
}

struct UsageGap: Equatable, Identifiable {
  let id: Int
  let start: Date
  let end: Date
}

struct UsageSegmentation: Equatable {
  let segments: [UsageSegment]
  let gaps: [UsageGap]

  init(_ points: [UsagePoint]) {
    var segments: [UsageSegment] = []
    var gaps: [UsageGap] = []
    var run: [UsageSample] = []
    var gapFirst: Date?
    var lastMeasured: Date?

    for point in points {
      guard let value = point.value else {
        if !run.isEmpty {
          segments.append(UsageSegment(id: segments.count, samples: run))
          run = []
        }
        gapFirst = gapFirst ?? point.time
        continue
      }
      if let first = gapFirst {
        gaps.append(UsageGap(id: gaps.count, start: lastMeasured ?? first, end: point.time))
        gapFirst = nil
      }
      run.append(UsageSample(time: point.time, value: value))
      lastMeasured = point.time
    }
    if !run.isEmpty {
      segments.append(UsageSegment(id: segments.count, samples: run))
    }
    if let first = gapFirst, let end = points.last?.time {
      gaps.append(UsageGap(id: gaps.count, start: lastMeasured ?? first, end: end))
    }
    self.segments = segments
    self.gaps = gaps
  }
}
