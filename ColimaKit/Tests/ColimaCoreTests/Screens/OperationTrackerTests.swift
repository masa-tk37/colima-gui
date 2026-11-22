import Testing

@testable import ColimaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OperationTrackerTests {
  @Test func awaitAllReturnsAtOnceWhenNothingWasTracked() async {
    await OperationTracker().awaitAll()
  }

  @Test func awaitAllWaitsForTrackedWork() async {
    let tracker = OperationTracker()
    let gate = ArrivalGate()
    var finished = false
    tracker.track {
      await gate.pass()
      finished = true
    }
    await gate.waitForArrivals(1)
    #expect(!finished)

    gate.open()
    await tracker.awaitAll()

    #expect(finished)
  }

  @Test func awaitAllAlsoWaitsForWorkTrackedByTrackedWork() async {
    let tracker = OperationTracker()
    var order: [String] = []
    tracker.track {
      tracker.track { order.append("inner") }
      order.append("outer")
    }

    await tracker.awaitAll()

    #expect(order.sorted() == ["inner", "outer"])
  }
}
