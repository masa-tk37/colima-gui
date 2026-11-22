import Synchronization

/// One `Poller` drives one `run` at a time.
final class Poller: Sendable {
  private struct State {
    var interval: Duration
    var version = 0
    var sleeper: Task<Void, any Error>?
  }

  private enum WaitResult {
    case elapsed, rearm, stopped
  }

  private let state: Mutex<State>

  init(interval: Duration) {
    precondition(interval > .zero, "a polling interval must be positive")
    state = Mutex(State(interval: interval))
  }

  var interval: Duration { state.withLock { $0.interval } }

  func setInterval(_ interval: Duration) {
    precondition(interval > .zero, "a polling interval must be positive")
    let sleeper = state.withLock { state -> Task<Void, any Error>? in
      guard state.interval != interval else { return nil }
      state.interval = interval
      state.version += 1
      return state.sleeper
    }
    sleeper?.cancel()
  }

  func run<C: Clock>(
    clock: C,
    didCompleteRound: @escaping @Sendable () -> Void = {},
    _ operation: @escaping @Sendable () async -> Void
  ) async where C.Duration == Duration {
    let isRunning = Mutex(false)
    // Discarding: a plain task group keeps every finished round until `next()`, which this loop never calls.
    await withDiscardingTaskGroup { group in
      var roundStart = clock.now
      while !Task.isCancelled {
        let acquired = isRunning.withLock { running in
          if running { return false }
          running = true
          return true
        }
        if acquired {
          group.addTask {
            await operation()
            isRunning.withLock { $0 = false }
            didCompleteRound()
          }
        }

        var next = roundStart
        var interval = self.interval
        waiting: while true {
          let version: Int
          (interval, version) = state.withLock { ($0.interval, $0.version) }
          next = roundStart.advanced(by: interval)
          switch await wait(until: next, version: version, clock: clock) {
          case .elapsed: break waiting
          case .rearm: continue waiting
          case .stopped: return
          }
        }
        // After a stall longer than one interval, resume from now instead of replaying missed rounds.
        let now = clock.now
        roundStart = next.duration(to: now) >= interval ? now : next
      }
    }
  }

  private func wait<C: Clock>(until deadline: C.Instant, version: Int, clock: C) async -> WaitResult
  where C.Duration == Duration {
    let sleeper = Task { try await clock.sleep(until: deadline, tolerance: nil) }
    let isStale = state.withLock { state in
      if state.version != version { return true }
      state.sleeper = sleeper
      return false
    }
    if isStale { sleeper.cancel() }
    defer { state.withLock { $0.sleeper = nil } }

    do {
      try await withTaskCancellationHandler {
        try await sleeper.value
      } onCancel: {
        sleeper.cancel()
      }
      return .elapsed
    } catch {
      return !Task.isCancelled && state.withLock({ $0.version }) != version ? .rearm : .stopped
    }
  }
}
