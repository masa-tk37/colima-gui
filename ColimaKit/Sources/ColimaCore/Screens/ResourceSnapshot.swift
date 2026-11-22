import Foundation

public struct ResourceSnapshot<Value: Sendable>: Sendable {
  public private(set) var value: Value?
  public private(set) var isRefreshing = false
  public private(set) var error: DockerError?

  public init() {}

  public mutating func beginRefresh() {
    isRefreshing = true
  }

  public mutating func finishRefresh(with result: Result<Value, DockerError>) {
    isRefreshing = false
    switch result {
    case .success(let value):
      self.value = value
      error = nil
    case .failure(.cancelled):
      break
    case .failure(let failure):
      error = failure
    }
  }
}
