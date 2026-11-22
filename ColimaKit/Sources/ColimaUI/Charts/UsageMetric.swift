import Foundation

extension UsageChart {
  public enum Metric: Sendable, Equatable {
    /// 100 is one fully used core, so a container series can exceed 100 while the VM series stays within 100 × its
    /// share of the VM's CPUs.
    case cpuPercent
    case memoryBytes

    func yUpperBound(forMaximum maximum: Double?) -> Double {
      let top = max(maximum ?? 0, 0)
      switch self {
      case .cpuPercent:
        return max(100, (top / 100).rounded(.up) * 100)
      case .memoryBytes:
        return top > 0 ? top * 1.1 : Double(1 << 30)
      }
    }

    func text(for value: Double) -> String {
      switch self {
      case .cpuPercent:
        return (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
      case .memoryBytes:
        return Int64(value.rounded()).formatted(.byteCount(style: .memory))
      }
    }

    func axisText(for value: Double) -> String {
      switch self {
      case .cpuPercent:
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
      case .memoryBytes:
        return Int64(value.rounded()).formatted(.byteCount(style: .memory))
      }
    }
  }
}
