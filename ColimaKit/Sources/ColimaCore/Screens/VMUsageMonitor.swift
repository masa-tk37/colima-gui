import Foundation
import Observation

public enum VMUsageState: Sendable, Equatable {
  case sampling
  case unavailable(reason: String)
}

@MainActor @Observable
public final class VMUsageMonitor {
  static let pollInterval: Duration = .seconds(3)
  /// Ten minutes at `pollInterval`.
  static let capacity = 200
  /// A base older than this spans time the screen was closed, so its difference would be an average over the
  /// pause plotted at the reopening. Three periods leave room for the varying latency of `colima ssh`.
  static let baseMaxAge: TimeInterval = 9

  public private(set) var cpu = UsageSeries(capacity: VMUsageMonitor.capacity)
  public private(set) var memory = UsageSeries(capacity: VMUsageMonitor.capacity)

  @ObservationIgnored private let controller: VMController
  @ObservationIgnored private let cli: any ColimaCLI
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let poller = Poller(interval: VMUsageMonitor.pollInterval)
  @ObservationIgnored private var previous: (snapshot: ProcSnapshot, takenAt: Date)?

  public convenience init(controller: VMController, cli: any ColimaCLI) {
    self.init(controller: controller, cli: cli, now: { Date() })
  }

  init(controller: VMController, cli: any ColimaCLI, now: @escaping @Sendable () -> Date) {
    self.controller = controller
    self.cli = cli
    self.now = now
  }

  public var state: VMUsageState {
    switch controller.dockerAvailability {
    case .ready:
      .sampling
    case .colimaMissing:
      .unavailable(reason: String(localized: "Colima was not found.", bundle: #bundle))
    case .vmAbsent:
      .unavailable(reason: String(localized: "Usage is unavailable because the VM has not been created.", bundle: #bundle))
    case .vmStopped:
      .unavailable(reason: String(localized: "Usage is unavailable because the VM is stopped.", bundle: #bundle))
    case .vmBusy:
      .unavailable(reason: String(localized: "Usage is unavailable because the VM is busy with an operation.", bundle: #bundle))
    case .vmUnknown(let reason):
      if let reason {
        .unavailable(reason: String(localized: "Could not check the VM state: \(reason)", bundle: #bundle))
      } else {
        .unavailable(reason: String(localized: "Could not check the VM state.", bundle: #bundle))
      }
    }
  }

  public func run() async {
    await run(clock: ContinuousClock())
  }

  func run<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [self] in
      await sampleOnce()
    }
  }

  private func sampleOnce() async {
    guard state == .sampling else {
      previous = nil
      return
    }
    // The CLI may finish a sample after the screen left; by then a newer run may own the series.
    let snapshot: ProcSnapshot
    do {
      snapshot = try await cli.sampleUsage()
    } catch {
      guard !Task.isCancelled, error != .cancelled else { return }
      appendGap()
      return
    }
    guard !Task.isCancelled else { return }

    let time = now()
    let base = previous.flatMap {
      time.timeIntervalSince($0.takenAt) <= Self.baseMaxAge ? $0.snapshot : nil
    }
    previous = (snapshot, time)
    guard let cpuPercent = snapshot.cpuPercent(since: base) else {
      appendGap()
      return
    }
    cpu.append(cpuPercent, at: time)
    memory.append(Double(snapshot.memoryUsedBytes), at: time)
  }

  private func appendGap() {
    let time = now()
    cpu.appendGap(at: time)
    memory.appendGap(at: time)
  }
}

#if DEBUG
  extension VMUsageMonitor {
    /// `previous` is stamped as taken now so the screen's own first round continues the history instead of starting with a gap.
    package func seedForPreview(cpu: UsageSeries, memory: UsageSeries, previous: ProcSnapshot?) {
      self.cpu = cpu
      self.memory = memory
      self.previous = previous.map { ($0, now()) }
    }
  }
#endif
