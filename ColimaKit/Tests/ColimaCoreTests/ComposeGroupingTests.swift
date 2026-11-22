import Testing

@testable import ColimaCore

private let projectLabel = "com.docker.compose.project"

private func container(
  _ name: String,
  running: Bool,
  project: String? = nil,
  labels extra: [String: String] = [:]
) -> ContainerSummary {
  var labels = extra
  if let project { labels[projectLabel] = project }
  return ContainerSummary(
    id: ContainerID(rawValue: "id-\(name)"),
    name: name,
    image: "img",
    state: ContainerState(dockerState: running ? "running" : "exited"),
    ports: [],
    labels: labels,
    networkNames: []
  )
}

@Test func allRunningProject() {
  let groups = ComposeGrouping.group([
    container("a", running: true, project: "shop"),
    container("b", running: true, project: "shop"),
  ])
  #expect(groups.projects.count == 1)
  let project = groups.projects[0]
  #expect(project.name == "shop")
  #expect(project.containers.count == 2)
  #expect(project.runningCount == 2)
  #expect(project.state == .allRunning)
}

@Test func partiallyRunningProject() {
  let project = ComposeGrouping.group([
    container("a", running: true, project: "shop"),
    container("b", running: false, project: "shop"),
    container("c", running: false, project: "shop"),
  ]).projects[0]
  #expect(project.containers.count == 3)
  #expect(project.runningCount == 1)
  #expect(project.state == .partiallyRunning)
}

@Test func allStoppedProject() {
  let project = ComposeGrouping.group([
    container("a", running: false, project: "shop"),
    container("b", running: false, project: "shop"),
  ]).projects[0]
  #expect(project.runningCount == 0)
  #expect(project.state == .allStopped)
}

@Test func singleContainerProjectStates() {
  #expect(
    ComposeGrouping.group([container("a", running: true, project: "p")]).projects[0].state
      == .allRunning)
  #expect(
    ComposeGrouping.group([container("a", running: false, project: "p")]).projects[0].state
      == .allStopped)
}

@Test func containersWithoutProjectLabelAreSeparated() {
  let groups = ComposeGrouping.group([
    container("a", running: true, project: "shop"),
    container("plain", running: true, labels: ["other": "x"]),
    container("empty", running: false, labels: [projectLabel: ""]),
  ])
  #expect(groups.projects.map(\.name) == ["shop"])
  #expect(groups.ungrouped.map(\.name) == ["plain", "empty"])
}

@Test func ungroupedContainersDoNotFormAProject() {
  let groups = ComposeGrouping.group([container("plain", running: true)])
  #expect(groups.projects.isEmpty)
  #expect(groups.ungrouped.count == 1)
}

@Test func emptyInputGivesEmptyGroups() {
  let groups = ComposeGrouping.group([])
  #expect(groups.projects.isEmpty)
  #expect(groups.ungrouped.isEmpty)
}

@Test func projectsAreSortedByNameAndKeepContainerOrder() {
  let groups = ComposeGrouping.group([
    container("z1", running: true, project: "zeta"),
    container("a2", running: true, project: "alpha"),
    container("z0", running: false, project: "zeta"),
  ])
  #expect(groups.projects.map(\.name) == ["alpha", "zeta"])
  #expect(groups.projects[1].containers.map(\.name) == ["z1", "z0"])
}

@Test func projectExposesMemberIDsForBatchOperations() {
  let project = ComposeGrouping.group([
    container("a", running: true, project: "shop"),
    container("b", running: false, project: "shop"),
  ]).projects[0]
  #expect(project.containerIDs == [ContainerID(rawValue: "id-a"), ContainerID(rawValue: "id-b")])
}
