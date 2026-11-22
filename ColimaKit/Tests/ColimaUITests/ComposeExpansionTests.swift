import ColimaCore
import Testing

@testable import ColimaUI

@MainActor
@Suite struct ComposeExpansionTests {
  private let web = ContainerID(rawValue: "web")
  private let db = ContainerID(rawValue: "db")

  private func outcome(failed: [ContainerID: String]) -> BatchOutcome<ContainerID> {
    BatchOutcome(succeeded: [], failed: failed)
  }

  @Test func aNewPartialFailureOpensItsProject() {
    let new = ["shop": outcome(failed: [web: "boom"])]
    #expect(ContainerListView.projectsWithNewFailures(old: [:], new: new) == ["shop"])
  }

  @Test func anUnchangedFailureDoesNotReopenAProjectTheUserCollapsed() {
    let failed = ["shop": outcome(failed: [web: "boom"])]
    #expect(ContainerListView.projectsWithNewFailures(old: failed, new: failed).isEmpty)
  }

  @Test func aBatchWithoutFailuresOpensNothing() {
    let new = ["shop": BatchOutcome(succeeded: [web, db], failed: [:])]
    #expect(ContainerListView.projectsWithNewFailures(old: [:], new: new).isEmpty)
  }

  @Test func aDifferentFailureInTheSameProjectOpensItAgain() {
    let old = ["shop": outcome(failed: [web: "boom"])]
    let new = ["shop": outcome(failed: [db: "boom"])]
    #expect(ContainerListView.projectsWithNewFailures(old: old, new: new) == ["shop"])
  }
}
