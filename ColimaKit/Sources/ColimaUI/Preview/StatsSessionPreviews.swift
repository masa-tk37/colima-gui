#if DEBUG
  import ColimaCore

  /// A `StatsSession` in a chosen state. The session is marked as already run, so the screen's `.task` cannot change
  /// what it shows.
  @MainActor
  struct StatsSessionScene {
    let session: StatsSession
    let container: ContainerSummary
  }

  @MainActor
  enum StatsSessionPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case running
      case runningWithGaps
      case notRunning
      case containerStopped
    }

    static func make(_ scenario: Scenario) async -> StatsSessionScene {
      let backend = await PreviewDockerBackend.make()
      let container =
        scenario == .notRunning ? PreviewSampleData.adminer : PreviewSampleData.webshopWeb
      let session = ContainerSessionFactory(engine: backend.engine).makeStatsSession(
        for: container.id)
      let window = session.cpu.window
      switch scenario {
      case .running:
        session.seedForPreview(
          state: .running,
          cpu: PreviewSeriesData.cpu(window: window, count: 40, gaps: [0]),
          memory: PreviewSeriesData.memory(window: window, count: 40, gaps: []))
      case .runningWithGaps:
        session.seedForPreview(
          state: .running,
          cpu: PreviewSeriesData.cpu(window: window, count: 40, gaps: [0, 15, 16, 30]),
          memory: PreviewSeriesData.memory(window: window, count: 40, gaps: [15, 16]))
      case .notRunning:
        session.seedForPreview(
          state: .notRunning,
          cpu: UsageSeries(window: window), memory: UsageSeries(window: window))
      case .containerStopped:
        session.seedForPreview(
          state: .containerStopped,
          cpu: PreviewSeriesData.cpu(window: window, count: 40, gaps: [0]),
          memory: PreviewSeriesData.memory(window: window, count: 40, gaps: []))
      }
      return StatsSessionScene(session: session, container: container)
    }
  }
#endif
