public enum ComposeProjectState: Sendable, Equatable {
  case allRunning, partiallyRunning, allStopped
}

public struct ComposeProject: Sendable, Equatable {
  public let name: String
  public let containers: [ContainerSummary]

  public init(name: String, containers: [ContainerSummary]) {
    self.name = name
    self.containers = containers
  }

  public var containerIDs: [ContainerID] { containers.map(\.id) }

  public var runningCount: Int { containers.count { $0.state.isRunning } }

  public var state: ComposeProjectState {
    switch runningCount {
    case 0: .allStopped
    case containers.count: .allRunning
    default: .partiallyRunning
    }
  }
}

public struct ContainerGroups: Sendable, Equatable {
  public let projects: [ComposeProject]
  public let ungrouped: [ContainerSummary]

  public init(projects: [ComposeProject], ungrouped: [ContainerSummary]) {
    self.projects = projects
    self.ungrouped = ungrouped
  }
}

public enum ComposeGrouping {
  public static let projectLabel = "com.docker.compose.project"

  public static func group(_ containers: [ContainerSummary]) -> ContainerGroups {
    var byProject: [String: [ContainerSummary]] = [:]
    var ungrouped: [ContainerSummary] = []
    for container in containers {
      if let name = container.labels[projectLabel], !name.isEmpty {
        byProject[name, default: []].append(container)
      } else {
        ungrouped.append(container)
      }
    }
    let projects =
      byProject
      .map { ComposeProject(name: $0.key, containers: $0.value) }
      .sorted { $0.name < $1.name }
    return ContainerGroups(projects: projects, ungrouped: ungrouped)
  }
}
