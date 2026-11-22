import Charts
import ColimaCore
import SwiftUI

public struct UsageChart: View {
  private let title: LocalizedStringResource
  private let series: UsageSeries
  private let metric: Metric

  public init(_ title: LocalizedStringResource, series: UsageSeries, metric: Metric) {
    self.title = title
    self.series = series
    self.metric = metric
  }

  public var body: some View {
    let shape = UsageSegmentation(series.points)
    let maximum = shape.segments.lazy.flatMap(\.samples).map(\.value).max()
    let upper = metric.yUpperBound(forMaximum: maximum)

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.headline)
        Spacer()
        Text(latestText)
          .font(.title3.monospacedDigit())
          .foregroundStyle(series.points.last?.value == nil ? .secondary : .primary)
      }
      let timeLabel = LocalizedStringResource("Time", bundle: #bundle)
      let valueLabel = LocalizedStringResource("Value", bundle: #bundle)
      Chart {
        ForEach(shape.gaps) { gap in
          RectangleMark(
            xStart: .value(LocalizedStringResource("Gap start", bundle: #bundle), gap.start),
            xEnd: .value(LocalizedStringResource("Gap end", bundle: #bundle), gap.end)
          )
          .foregroundStyle(.secondary.opacity(0.2))
        }
        ForEach(shape.segments) { segment in
          ForEach(segment.samples, id: \.time) { sample in
            if segment.samples.count == 1 {
              PointMark(x: .value(timeLabel, sample.time), y: .value(valueLabel, sample.value))
            } else {
              LineMark(
                x: .value(timeLabel, sample.time),
                y: .value(valueLabel, sample.value),
                series: .value(LocalizedStringResource("Segment", bundle: #bundle), segment.id))
            }
          }
          .foregroundStyle(Color.accentColor)
        }
      }
      .chartYScale(domain: 0...upper)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) {
          AxisGridLine()
          AxisTick()
          AxisValueLabel(format: .dateTime.hour().minute().second())
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(metric.axisText(for: number))
            }
          }
        }
      }
      .chartLegend(.hidden)
      .overlay {
        if series.points.isEmpty {
          Text("No data", bundle: #bundle).foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 120)
      .accessibilityLabel(title)
      .accessibilityValue(summary(gapCount: shape.gaps.count, maximum: maximum))
    }
  }

  private var latestText: String {
    guard let latest = series.points.last else { return "—" }
    guard let value = latest.value else { return String(localized: "Missing", bundle: #bundle) }
    return metric.text(for: value)
  }

  private func summary(gapCount: Int, maximum: Double?) -> String {
    guard !series.points.isEmpty else { return String(localized: "No data", bundle: #bundle) }
    var parts = [String(localized: "Latest \(latestText)", bundle: #bundle)]
    if let maximum {
      parts.append(String(localized: "Maximum \(metric.text(for: maximum))", bundle: #bundle))
    }
    if gapCount > 0 {
      parts.append(String(localized: "\(gapCount) gaps", bundle: #bundle))
    }
    return parts.formatted(.list(type: .and))
  }
}
