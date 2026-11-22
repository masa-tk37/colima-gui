import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@Suite
struct LogFollowRuleTests {
  private func metrics(offset: CGFloat, content: CGFloat = 1000, viewport: CGFloat = 400)
    -> LogScrollMetrics
  {
    LogScrollMetrics(
      offset: offset, contentHeight: content, viewportHeight: viewport, bottomInset: 0)
  }

  @Test func distanceFromBottomIsTheRemainingScrollableHeight() {
    #expect(metrics(offset: 0).distanceFromBottom == 600)
    #expect(metrics(offset: 600).distanceFromBottom == 0)
    #expect(
      LogScrollMetrics(offset: 590, contentHeight: 1000, viewportHeight: 400, bottomInset: 10)
        .distanceFromBottom == 20)
  }

  @Test func shortContentAndOverscrollCountAsAtTheBottom() {
    #expect(metrics(offset: 0, content: 100).distanceFromBottom == 0)
    #expect(metrics(offset: 640).distanceFromBottom == 0)
  }

  @Test func scrollingUpAwayFromTheBottomStopsFollowing() {
    let pinned = LogFollowRule.isPinned(
      was: true, from: metrics(offset: 600), to: metrics(offset: 540))
    #expect(!pinned)
  }

  @Test func aBounceAtTheBottomKeepsFollowing() {
    let pinned = LogFollowRule.isPinned(
      was: true, from: metrics(offset: 640), to: metrics(offset: 600))
    #expect(pinned)
  }

  @Test func contentGrowingUnderANonScrollingUserKeepsFollowing() {
    let before = metrics(offset: 600)
    let after = metrics(offset: 600, content: 1100)
    #expect(LogFollowRule.isPinned(was: true, from: before, to: after))
  }

  @Test func scrollingBackToTheBottomResumesFollowing() {
    let pinned = LogFollowRule.isPinned(
      was: false, from: metrics(offset: 500), to: metrics(offset: 600))
    #expect(pinned)
  }

  @Test func scrollingDownWithoutReachingTheBottomStaysStopped() {
    let pinned = LogFollowRule.isPinned(
      was: false, from: metrics(offset: 100), to: metrics(offset: 300))
    #expect(!pinned)
  }
}

@Suite
struct LogRowsTests {
  @Test func confirmedLinesComeBeforeProvisionalOnesAsOneCollection() {
    let confirmed = [
      LogLine(id: 0, stream: .stdout, text: "a"), LogLine(id: 1, stream: .stderr, text: "b"),
    ]
    let provisional = [LogLine(id: 2, stream: .stdout, text: "c")]
    let rows = LogRows(confirmed: confirmed, provisional: provisional)
    #expect(rows.count == 3)
    #expect(rows.map(\.id) == [0, 1, 2])
    #expect(LogRows(confirmed: [], provisional: []).isEmpty)
  }
}
