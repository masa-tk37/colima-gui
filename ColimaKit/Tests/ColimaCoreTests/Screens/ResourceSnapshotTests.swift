import Foundation
import Testing

@testable import ColimaCore

struct ResourceSnapshotTests {
  @Test func startsEmpty() {
    let snapshot = ResourceSnapshot<[String]>()
    #expect(snapshot.value == nil)
    #expect(snapshot.isRefreshing == false)
    #expect(snapshot.error == nil)
  }

  @Test func successStoresTheValueAndEndsRefreshing() {
    var snapshot = ResourceSnapshot<[String]>()
    snapshot.beginRefresh()
    #expect(snapshot.isRefreshing)
    snapshot.finishRefresh(with: .success(["a"]))
    #expect(snapshot.value == ["a"])
    #expect(snapshot.isRefreshing == false)
    #expect(snapshot.error == nil)
  }

  @Test func failureKeepsThePreviousValueAndShowsTheError() {
    var snapshot = ResourceSnapshot<[String]>()
    snapshot.finishRefresh(with: .success(["a"]))
    snapshot.beginRefresh()
    snapshot.finishRefresh(with: .failure(.timedOut))
    #expect(snapshot.value == ["a"])
    #expect(snapshot.error == .timedOut)
    #expect(snapshot.isRefreshing == false)
  }

  @Test func nextSuccessClearsTheError() {
    var snapshot = ResourceSnapshot<[String]>()
    snapshot.finishRefresh(with: .failure(.engineUnreachable(detail: "x")))
    #expect(snapshot.value == nil)
    snapshot.finishRefresh(with: .success(["b"]))
    #expect(snapshot.error == nil)
    #expect(snapshot.value == ["b"])
  }

  @Test func cancellationOnlyClearsRefreshing() {
    var snapshot = ResourceSnapshot<[String]>()
    snapshot.finishRefresh(with: .success(["a"]))
    snapshot.finishRefresh(with: .failure(.api(status: 500, message: "boom")))
    snapshot.beginRefresh()
    snapshot.finishRefresh(with: .failure(.cancelled))
    #expect(snapshot.value == ["a"])
    #expect(snapshot.error == .api(status: 500, message: "boom"))
    #expect(snapshot.isRefreshing == false)
  }
}
