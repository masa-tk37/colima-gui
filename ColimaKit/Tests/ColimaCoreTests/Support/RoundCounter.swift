import Synchronization

final class RoundCounter: Sendable {
  private let completed = Mutex(0)
  private let waiters = WaitList()

  @Sendable func roundCompleted() {
    completed.withLock { $0 += 1 }
    waiters.notify()
  }

  func waitForRounds(_ count: Int) async {
    await waiters.wait { self.completed.withLock { $0 >= count } }
  }
}
