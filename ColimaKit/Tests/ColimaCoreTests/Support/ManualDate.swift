import Foundation
import Synchronization

final class ManualDate: Sendable {
  private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))

  var now: Date { current.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    current.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}
