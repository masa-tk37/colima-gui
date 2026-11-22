import Synchronization

final class WaitList: Sendable {
  private struct Waiter {
    let id: Int
    let isSatisfied: @Sendable () -> Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var nextID = 0
    var waiters: [Waiter] = []
    var cancelledBeforeRegistration: Set<Int> = []
  }

  private let state = Mutex(State())

  func wait(until isSatisfied: @escaping @Sendable () -> Bool) async {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { state -> Bool in
          if state.cancelledBeforeRegistration.remove(id) != nil || isSatisfied() { return true }
          state.waiters.append(Waiter(id: id, isSatisfied: isSatisfied, continuation: continuation))
          return false
        }
        if resumeNow { continuation.resume() }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        if let index = state.waiters.firstIndex(where: { $0.id == id }) {
          return state.waiters.remove(at: index)
        }
        state.cancelledBeforeRegistration.insert(id)
        return nil
      }
      waiter?.continuation.resume()
    }
  }

  /// Call after the observed state changed, outside any lock that `isSatisfied` takes.
  func notify() {
    let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      var ready: [CheckedContinuation<Void, Never>] = []
      var pending: [Waiter] = []
      for waiter in state.waiters {
        if waiter.isSatisfied() {
          ready.append(waiter.continuation)
        } else {
          pending.append(waiter)
        }
      }
      state.waiters = pending
      return ready
    }
    for waiter in ready { waiter.resume() }
  }
}
