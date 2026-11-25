#if DEBUG
  import ColimaCore
  import Foundation

  /// `spacing` matches the real poll interval (`VMUsageMonitor.pollInterval`, 3 s).
  enum PreviewSeriesData {
    static func series(
      window: TimeInterval,
      count: Int,
      gaps: Set<Int>,
      spacing: TimeInterval = 3,
      value: (Int) -> Double
    ) -> UsageSeries {
      var series = UsageSeries(window: window)
      let end = Date()
      for index in 0..<count {
        let time = end.addingTimeInterval(-spacing * Double(count - 1 - index))
        if gaps.contains(index) {
          series.appendGap(at: time)
        } else {
          series.append(value(index), at: time)
        }
      }
      return series
    }

    static func cpu(window: TimeInterval, count: Int, gaps: Set<Int>) -> UsageSeries {
      series(window: window, count: count, gaps: gaps) { index in
        let wave = 35 + 25 * sin(Double(index) / 4) + 8 * sin(Double(index) / 1.3)
        return min(max(wave, 2), 98)
      }
    }

    static func memory(window: TimeInterval, count: Int, gaps: Set<Int>) -> UsageSeries {
      series(window: window, count: count, gaps: gaps) { index in
        Double(1_200 << 20) + Double(index) * Double(3 << 20) + 20_000_000 * sin(Double(index) / 5)
      }
    }
  }
#endif
