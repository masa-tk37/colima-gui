import Testing

@testable import ColimaUI

struct UsageMetricTests {
  @Test func cpuScaleStartsAtOneHundredPercent() {
    #expect(UsageChart.Metric.cpuPercent.yUpperBound(forMaximum: nil) == 100)
    #expect(UsageChart.Metric.cpuPercent.yUpperBound(forMaximum: 37) == 100)
    #expect(UsageChart.Metric.cpuPercent.yUpperBound(forMaximum: 100) == 100)
  }

  @Test func cpuScaleGrowsInWholeCoresWhenAContainerExceedsOneCore() {
    #expect(UsageChart.Metric.cpuPercent.yUpperBound(forMaximum: 100.5) == 200)
    #expect(UsageChart.Metric.cpuPercent.yUpperBound(forMaximum: 250) == 300)
  }

  @Test func memoryScaleLeavesHeadroomAboveTheMaximum() {
    #expect(UsageChart.Metric.memoryBytes.yUpperBound(forMaximum: 1_000) == 1_100)
  }

  @Test func memoryScaleWithoutDataIsOneGibibyte() {
    #expect(UsageChart.Metric.memoryBytes.yUpperBound(forMaximum: nil) == Double(1 << 30))
    #expect(UsageChart.Metric.memoryBytes.yUpperBound(forMaximum: 0) == Double(1 << 30))
  }
}
