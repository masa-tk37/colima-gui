#if DEBUG
  import ColimaCore
  import Foundation

  /// A `LogSession` in a chosen state. The session has already run, so the screen's own `.task` returns at once;
  /// `runTask` is the call that is still waiting on a followed stream.
  @MainActor
  struct LogSessionScene {
    let session: LogSession
    let container: ContainerSummary
    let runTask: Task<Void, Never>
  }

  @MainActor
  enum LogSessionPreviews {
    enum Scenario: Sendable, Equatable, CaseIterable {
      case following
      case followingWithUnterminatedLine
      case followingLong
      case tty
      case history
      case endedStreamClosed
      case endedContainerGone
      case endedConnectionLost
      case endedMalformedFrame
    }

    private typealias Entry = (stream: LogStreamKind, text: String)

    static func make(_ scenario: Scenario) async -> LogSessionScene {
      let running = PreviewSampleData.webshopWeb
      let stopped = PreviewSampleData.adminer
      let ttyContainer = PreviewSampleData.analyticsWorker

      var container = running
      var script = PreviewDockerEngine.LogScript()
      var confirmedLines = 0
      var provisionalLines = 0
      var tty = false

      switch scenario {
      case .following:
        let entries = PreviewSampleData.logEntries(count: 24)
        script = .init(chunks: PreviewSampleData.logChunks(entries, tty: false), ending: .staysOpen)
        confirmedLines = entries.count
      case .followingWithUnterminatedLine:
        let entries = PreviewSampleData.logEntries(count: 12)
        let tail: Entry = (
          .stdout, "172.20.0.1 - - [01/Nov/2024:10:12:30 +0000] \"POST /orders HTTP/1.1\" 20"
        )
        script = .init(
          chunks: PreviewSampleData.logChunks(entries, tty: false, unterminated: tail),
          ending: .staysOpen)
        confirmedLines = entries.count
        provisionalLines = 1
      case .followingLong:
        let entries = PreviewSampleData.logEntries(count: 400)
        script = .init(chunks: PreviewSampleData.logChunks(entries, tty: false), ending: .staysOpen)
        confirmedLines = entries.count
      case .tty:
        container = ttyContainer
        tty = true
        let entries = PreviewSampleData.logEntries(count: 18).map {
          (stream: LogStreamKind.combined, text: $0.text)
        }
        script = .init(chunks: PreviewSampleData.logChunks(entries, tty: true), ending: .staysOpen)
        confirmedLines = entries.count
      case .history:
        container = stopped
        let entries = PreviewSampleData.logEntries(count: 16)
        script = .init(chunks: PreviewSampleData.logChunks(entries, tty: false), ending: .closes)
        confirmedLines = entries.count
      case .endedStreamClosed:
        let entries = PreviewSampleData.logEntries(count: 16)
        script = .init(chunks: PreviewSampleData.logChunks(entries, tty: false), ending: .closes)
        confirmedLines = entries.count
      case .endedContainerGone:
        let entries = PreviewSampleData.logEntries(count: 10)
        script = .init(
          chunks: PreviewSampleData.logChunks(entries, tty: false),
          ending: .fails(.api(status: 404, message: "No such container: webshop-web-1")))
        confirmedLines = entries.count
      case .endedConnectionLost:
        let entries = PreviewSampleData.logEntries(count: 10)
        script = .init(
          chunks: PreviewSampleData.logChunks(entries, tty: false),
          ending: .fails(.connectionLost(detail: "the connection was closed")))
        confirmedLines = entries.count
      case .endedMalformedFrame:
        let entries = PreviewSampleData.logEntries(count: 6)
        script = .init(
          chunks: PreviewSampleData.logChunks(entries, tty: false) + [
            [0x7F, 0, 0, 0, 0, 0, 0, 4, 0x6F, 0x6F, 0x70, 0x73]
          ], ending: .closes)
        confirmedLines = entries.count
      }

      let backend = await PreviewDockerBackend.make { config in
        config.logs[container.id] = script
        if tty { config.ttyContainers.insert(container.id) }
      }
      let session = ContainerSessionFactory(engine: backend.engine).makeLogSession(
        for: container.id)
      let task = Task { await session.run() }

      switch scenario {
      case .following, .followingWithUnterminatedLine, .followingLong, .tty:
        await PreviewSettle.until("the log lines arrived") {
          session.lines.count == confirmedLines
            && session.provisionalLines.count == provisionalLines
        }
      case .history, .endedStreamClosed, .endedContainerGone, .endedConnectionLost,
        .endedMalformedFrame:
        await task.value
      }
      return LogSessionScene(session: session, container: container, runTask: task)
    }
  }
#endif
