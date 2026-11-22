/// The container screen reaches the engine only through this type, so it cannot call destructive operations such as removal.
@MainActor
public final class ContainerSessionFactory {
  private let engine: any DockerEngine

  public init(engine: any DockerEngine) {
    self.engine = engine
  }

  public func makeLogSession(for container: ContainerID) -> LogSession {
    LogSession(engine: engine, container: container)
  }

  public func makeStatsSession(for container: ContainerID) -> StatsSession {
    StatsSession(engine: engine, container: container)
  }
}
