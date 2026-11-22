import Foundation
import Observation

public enum StatsSessionState: Sendable, Equatable {
  case starting
  case running
  /// The session keeps checking and turns `running` if the container starts.
  case notRunning
  /// A running container stopped or disappeared. Updates have ended and the history stays.
  case containerStopped

  public var message: String? {
    switch self {
    case .starting, .running: nil
    case .notRunning: String(localized: "Statistics are not being collected because the container is not running.", bundle: #bundle)
    case .containerStopped: String(localized: "Updates stopped because the container stopped.", bundle: #bundle)
    }
  }
}

@MainActor @Observable
public final class StatsSession {
  static let pollInterval: Duration = .seconds(3)
  /// Five minutes at `pollInterval`.
  static let capacity = 100

  public private(set) var state: StatsSessionState = .starting
  /// CPU usage with one fully used core as 100.
  public private(set) var cpu = UsageSeries(capacity: StatsSession.capacity)
  public private(set) var memory = UsageSeries(capacity: StatsSession.capacity)

  @ObservationIgnored private let engine: any DockerEngine
  @ObservationIgnored private let container: ContainerID
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let poller = Poller(interval: StatsSession.pollInterval)
  @ObservationIgnored private var hasRun = false
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  public convenience init(engine: any DockerEngine, container: ContainerID) {
    self.init(engine: engine, container: container, now: { Date() })
  }

  init(engine: any DockerEngine, container: ContainerID, now: @escaping @Sendable () -> Date) {
    self.engine = engine
    self.container = container
    self.now = now
  }

  /// Also returns when the container is found stopped.
  public func run() async {
    await run(clock: ContinuousClock())
  }

  func run<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {}
  ) async where C.Duration == Duration {
    guard !hasRun else { return }
    hasRun = true

    let loop = Task { [poller, weak self] in
      await poller.run(clock: clock, didCompleteRound: didCompleteRound) { [weak self] in
        await self?.pollOnce()
      }
    }
    pollTask = loop
    await withTaskCancellationHandler {
      await loop.value
    } onCancel: {
      loop.cancel()
    }
    pollTask = nil
  }

  private func pollOnce() async {
    let detail: ContainerDetail
    do {
      detail = try await engine.inspectContainer(id: container)
    } catch {
      handle(error)
      return
    }
    guard detail.isRunning else {
      containerIsNotRunning()
      return
    }
    state = .running

    let sample: ContainerStatsSample
    do {
      sample = try await engine.containerStats(id: container)
    } catch {
      handle(error)
      return
    }
    let time = now()
    cpu.append(sample.cpuPercent, at: time)
    memory.append(sample.memoryBytes.map { Double($0) }, at: time)
  }

  private func handle(_ error: DockerError) {
    guard error != .cancelled else { return }
    if case .api(404, _) = error {
      containerIsNotRunning()
      return
    }
    let time = now()
    cpu.appendGap(at: time)
    memory.appendGap(at: time)
  }

  private func containerIsNotRunning() {
    guard state == .running else {
      state = .notRunning
      return
    }
    state = .containerStopped
    pollTask?.cancel()
  }
}

#if DEBUG
  extension StatsSession {
    /// Marks the session as already run so the screen's `.task` cannot rewrite the seeded values: the engine behind a preview only answers with fixed values.
    package func seedForPreview(state: StatsSessionState, cpu: UsageSeries, memory: UsageSeries) {
      self.state = state
      self.cpu = cpu
      self.memory = memory
      hasRun = true
    }
  }
#endif
