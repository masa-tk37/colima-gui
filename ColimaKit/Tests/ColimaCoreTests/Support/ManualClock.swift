import Synchronization

final class ManualClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var nextID = 0
    var sleepers: [Int: Sleeper] = [:]
    var cancelledBeforeRegistration: Set<Int> = []
  }

  private let state = Mutex(State())
  private let waiters = WaitList()

  var minimumResolution: Duration { .zero }
  var now: Instant { state.withLock { $0.now } }
  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        enum Outcome { case resume, cancel, registered }
        let outcome = state.withLock { state -> Outcome in
          if state.cancelledBeforeRegistration.remove(id) != nil { return .cancel }
          if deadline <= state.now { return .resume }
          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return .registered
        }
        switch outcome {
        case .resume: continuation.resume()
        case .cancel: continuation.resume(throwing: CancellationError())
        case .registered: waiters.notify()
        }
      }
    } onCancel: {
      let sleeper = state.withLock { state -> Sleeper? in
        if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
        state.cancelledBeforeRegistration.insert(id)
        return nil
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Sleeper] in
      state.now = state.now.advanced(by: duration)
      let ids = state.sleepers.filter { $0.value.deadline <= state.now }.keys
      return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  func waitForSleeper(until deadline: Instant) async {
    await waiters.wait {
      self.state.withLock { $0.sleepers.values.contains { $0.deadline == deadline } }
    }
  }
}
