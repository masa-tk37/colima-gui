#if DEBUG
  import ColimaCore
  import Synchronization

  final class PreviewRunProcess: Sendable {
    private let isFinished = Mutex(false)
    let events: AsyncStream<ProcessEvent>
    private let continuation: AsyncStream<ProcessEvent>.Continuation

    init() {
      (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
    }

    func send(_ line: String) {
      guard !isFinished.withLock({ $0 }) else { return }
      continuation.yield(.output(line))
    }

    func finish(code: Int32) {
      let wasOpen = isFinished.withLock { finished in
        defer { finished = true }
        return !finished
      }
      guard wasOpen else { return }
      continuation.yield(.exited(code: code))
      continuation.finish()
    }
  }
#endif
