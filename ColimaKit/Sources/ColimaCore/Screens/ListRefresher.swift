import Foundation
import Observation

/// Keeps an older response from overwriting a newer one when refreshes overlap.
@MainActor @Observable
final class ListRefresher<Value: Sendable> {
  private(set) var snapshot = ResourceSnapshot<Value>()

  @ObservationIgnored private var ticket = 0
  @ObservationIgnored private var lastAppliedTicket = 0
  @ObservationIgnored private var inFlight = 0

  func refresh(_ fetch: () async throws(DockerError) -> Value) async {
    ticket += 1
    let mine = ticket
    inFlight += 1
    snapshot.beginRefresh()

    let result: Result<Value, DockerError>
    do {
      result = .success(try await fetch())
    } catch {
      result = .failure(error)
    }

    inFlight -= 1
    if mine > lastAppliedTicket {
      lastAppliedTicket = mine
      snapshot.finishRefresh(with: result)
      if inFlight > 0 { snapshot.beginRefresh() }
    } else if inFlight == 0 {
      snapshot.finishRefresh(with: .failure(.cancelled))
    }
  }
}
