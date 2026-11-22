import Foundation

/// Runs operations in tasks of their own, so closing the screen that started one never cuts it off.
@MainActor
final class OperationTracker {
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func track(_ work: @escaping @MainActor () async -> Void) {
    let key = UUID()
    tasks[key] = Task { [weak self] in
      await work()
      self?.tasks[key] = nil
    }
  }

  func awaitAll() async {
    while let task = tasks.values.first {
      await task.value
    }
  }
}
