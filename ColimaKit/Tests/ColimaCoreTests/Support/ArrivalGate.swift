import Synchronization

final class ArrivalGate: Sendable {
  private struct State {
    var arrivals = 0
    var isOpen = false
  }

  private let state = Mutex(State())
  private let blocking: Int
  private let waiters = WaitList()

  init(blocking: Int = 1) {
    self.blocking = blocking
  }

  var arrivals: Int { state.withLock { $0.arrivals } }

  @Sendable func pass() async {
    let held = state.withLock { state -> Bool in
      state.arrivals += 1
      return state.arrivals <= blocking && !state.isOpen
    }
    waiters.notify()
    guard held else { return }
    await waiters.wait { self.state.withLock { $0.isOpen } }
  }

  func waitForArrivals(_ count: Int) async {
    await waiters.wait { self.state.withLock { $0.arrivals >= count } }
  }

  func open() {
    state.withLock { $0.isOpen = true }
    waiters.notify()
  }
}
