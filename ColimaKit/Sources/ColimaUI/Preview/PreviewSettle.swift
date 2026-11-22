#if DEBUG
  import ColimaCore
  import Synchronization

  /// The model finishes on tasks of its own; this polls for the result and gives up after a deadline so a preview still renders when a scenario cannot reach its state.
  @MainActor
  enum PreviewSettle {
    nonisolated static let timeouts = Mutex(0)

    @discardableResult
    static func until(
      _ what: StaticString,
      timeout: Duration = .seconds(3),
      _ condition: @MainActor () -> Bool
    ) async -> Bool {
      let deadline = ContinuousClock.now.advanced(by: timeout)
      while !condition() {
        if Task.isCancelled { return false }
        if ContinuousClock.now >= deadline {
          timeouts.withLock { $0 += 1 }
          ColimaLog.process.error("preview scenario did not settle: \(what, privacy: .public)")
          return false
        }
        try? await Task.sleep(for: .milliseconds(2))
      }
      return true
    }
  }
#endif
