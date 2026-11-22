import Synchronization

final class PollProbe: Sendable {
  private struct State {
    var starts = 0
    var finishes = 0
    var running = 0
    var maxRunning = 0
    var cancelled = 0
    var gateOpen: Bool
  }

  enum Behavior: Sendable {
    case instant
    case blockedOnGate
    case untilCancelled
  }

  private let state: Mutex<State>
  private let behavior: Behavior
  let rounds = RoundCounter()
  private let startWaiters = WaitList()
  private let gateWaiters = WaitList()

  init(_ behavior: Behavior = .instant) {
    self.behavior = behavior
    var initial = State(gateOpen: true)
    if case .blockedOnGate = behavior { initial.gateOpen = false }
    state = Mutex(initial)
  }

  var starts: Int { state.withLock { $0.starts } }
  var finishes: Int { state.withLock { $0.finishes } }
  var maxConcurrent: Int { state.withLock { $0.maxRunning } }
  var cancelledRuns: Int { state.withLock { $0.cancelled } }

  @Sendable func operation() async {
    state.withLock { state in
      state.starts += 1
      state.running += 1
      state.maxRunning = max(state.maxRunning, state.running)
    }
    startWaiters.notify()

    switch behavior {
    case .instant: break
    case .blockedOnGate:
      await gateWaiters.wait { self.state.withLock { $0.gateOpen } }
    case .untilCancelled:
      do { try await Task.sleep(for: .seconds(3600)) } catch {
        state.withLock { $0.cancelled += 1 }
      }
    }
    state.withLock { state in
      state.running -= 1
      state.finishes += 1
    }
  }

  func waitForStarts(_ count: Int) async {
    await startWaiters.wait { self.state.withLock { $0.starts >= count } }
  }

  func openGate() {
    state.withLock { $0.gateOpen = true }
    gateWaiters.notify()
  }
}
