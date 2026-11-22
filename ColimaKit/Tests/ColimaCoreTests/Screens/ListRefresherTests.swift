import Foundation
import Synchronization
import Testing

@testable import ColimaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ListRefresherTests {
  private func makeRefresher() -> ListRefresher<[Int]> {
    ListRefresher<[Int]>()
  }

  @Test func aSuccessfulFetchStoresTheValue() async {
    let refresher = makeRefresher()

    await refresher.refresh { [1, 2] }

    #expect(refresher.snapshot.value == [1, 2])
    #expect(refresher.snapshot.error == nil)
    #expect(!refresher.snapshot.isRefreshing)
  }

  @Test func aFailedFetchKeepsThePreviousValueAndRecordsTheError() async {
    let refresher = makeRefresher()
    await refresher.refresh { [1] }

    await refresher.refresh { () async throws(DockerError) -> [Int] in throw .timedOut }

    #expect(refresher.snapshot.value == [1])
    #expect(refresher.snapshot.error == .timedOut)
    #expect(!refresher.snapshot.isRefreshing)
  }

  @Test func isRefreshingIsTrueWhileTheFetchIsRunning() async {
    let refresher = makeRefresher()
    let gate = ArrivalGate()
    let running = Task {
      await refresher.refresh {
        await gate.pass()
        return [1]
      }
    }
    await gate.waitForArrivals(1)

    #expect(refresher.snapshot.isRefreshing)
    gate.open()
    await running.value

    #expect(!refresher.snapshot.isRefreshing)
  }

  @Test func aSlowEarlierFetchDoesNotOverwriteALaterOne() async {
    let refresher = makeRefresher()
    let gate = ArrivalGate()
    let slow = Task {
      await refresher.refresh {
        await gate.pass()
        return [1]
      }
    }
    await gate.waitForArrivals(1)

    await refresher.refresh { [2] }
    gate.open()
    await slow.value

    #expect(refresher.snapshot.value == [2])
    #expect(!refresher.snapshot.isRefreshing)
    #expect(refresher.snapshot.error == nil)
  }

  @Test func aStaleFailureDoesNotShowAsAnError() async {
    let refresher = makeRefresher()
    let gate = ArrivalGate()
    let slow = Task {
      await refresher.refresh { () async throws(DockerError) -> [Int] in
        await gate.pass()
        throw .timedOut
      }
    }
    await gate.waitForArrivals(1)

    await refresher.refresh { [2] }
    gate.open()
    await slow.value

    #expect(refresher.snapshot.value == [2])
    #expect(refresher.snapshot.error == nil)
  }

  @Test func aCancelledFetchEndsTheRefreshWithoutAnError() async {
    let refresher = makeRefresher()
    await refresher.refresh { [1] }

    await refresher.refresh { () async throws(DockerError) -> [Int] in throw .cancelled }

    #expect(refresher.snapshot.value == [1])
    #expect(refresher.snapshot.error == nil)
    #expect(!refresher.snapshot.isRefreshing)
  }
}
