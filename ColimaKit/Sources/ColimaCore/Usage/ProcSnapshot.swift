public enum ProcParseError: Error, Sendable, Equatable {
  case missingCPULine
  case malformedCPULine
  case missingMemoryField(String)
  case malformedMemoryField(String)
}

public struct ProcSnapshot: Sendable, Equatable {
  /// guest and guest_nice are already inside user and nice.
  let busyTicks: UInt64
  let idleTicks: UInt64
  public let memoryTotalBytes: UInt64
  public let memoryAvailableBytes: UInt64

  public var memoryUsedBytes: UInt64 { memoryTotalBytes - memoryAvailableBytes }

  /// Parses the concatenated output of `cat /proc/stat /proc/meminfo`.
  public static func parse(_ text: String) throws(ProcParseError) -> ProcSnapshot {
    let lines = text.split(whereSeparator: \.isNewline)
    guard
      let cpuLine = lines.first(where: { $0.split(whereSeparator: \.isWhitespace).first == "cpu" })
    else {
      throw .missingCPULine
    }
    let fields = cpuLine.split(whereSeparator: \.isWhitespace).dropFirst()
    guard fields.count >= 8 else { throw .malformedCPULine }
    var counters: [UInt64] = []
    for field in fields.prefix(8) {
      guard let value = UInt64(field) else { throw .malformedCPULine }
      counters.append(value)
    }
    // Field order: user nice system idle iowait irq softirq steal.
    let busy = counters[0] + counters[1] + counters[2] + counters[5] + counters[6] + counters[7]
    let idle = counters[3] + counters[4]

    let total = try memoryKiB("MemTotal", in: lines)
    let available = try memoryKiB("MemAvailable", in: lines)
    guard available <= total else { throw .malformedMemoryField("MemAvailable") }
    return ProcSnapshot(
      busyTicks: busy, idleTicks: idle,
      memoryTotalBytes: total * 1024, memoryAvailableBytes: available * 1024
    )
  }

  /// CPU usage in 0...100. `nil` (a gap) when a counter went backwards, which happens after a VM restart.
  public func cpuPercent(since previous: ProcSnapshot?) -> Double? {
    guard let previous,
      busyTicks >= previous.busyTicks,
      idleTicks >= previous.idleTicks
    else { return nil }
    let busy = busyTicks - previous.busyTicks
    let total = busy + (idleTicks - previous.idleTicks)
    guard total > 0 else { return nil }
    return Double(busy) / Double(total) * 100
  }

  private static func memoryKiB(_ key: String, in lines: [Substring]) throws(ProcParseError)
    -> UInt64
  {
    guard let line = lines.first(where: { $0.hasPrefix(key + ":") }) else {
      throw .missingMemoryField(key)
    }
    let parts = line.dropFirst(key.count + 1).split(whereSeparator: \.isWhitespace)
    guard parts.count == 2, parts[1] == "kB", let value = UInt64(parts[0]) else {
      throw .malformedMemoryField(key)
    }
    return value
  }
}
