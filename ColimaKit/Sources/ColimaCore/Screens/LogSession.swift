import Foundation
import Observation

public enum LogSessionMode: Sendable { case separated, singleStream }

public enum LogSessionState: Sendable, Equatable {
  case loading, following, history
  case ended(LogEndReason)
}

public enum LogEndReason: Sendable, Equatable {
  case streamClosed, containerGone
  case failed(String)
}

@MainActor @Observable
public final class LogSession {
  static let defaultLineLimit = 50_000
  static let tail = 500

  public private(set) var state: LogSessionState = .loading
  public private(set) var mode: LogSessionMode = .separated
  /// Trimmed back to the limit only once a tenth over it, so a full buffer is not shifted on every chunk.
  public private(set) var lines: [LogLine] = []
  public private(set) var provisionalLines: [LogLine] = []

  @ObservationIgnored private let engine: any DockerEngine
  @ObservationIgnored private let container: ContainerID
  @ObservationIgnored private let lineLimit: Int
  @ObservationIgnored private var hasRun = false
  @ObservationIgnored private var isFollowing = false
  @ObservationIgnored private var isTTY = false
  @ObservationIgnored private var decoder = LogFrameDecoder()
  @ObservationIgnored private var assemblers: [LogStreamKind: LineAssembler] = [:]
  @ObservationIgnored private var provisionalIDs: [LogStreamKind: Int] = [:]
  @ObservationIgnored private var nextID = 0
  @ObservationIgnored private var streamTask: Task<DockerError?, Never>?

  public convenience init(engine: any DockerEngine, container: ContainerID) {
    self.init(engine: engine, container: container, lineLimit: Self.defaultLineLimit)
  }

  init(engine: any DockerEngine, container: ContainerID, lineLimit: Int) {
    self.engine = engine
    self.container = container
    self.lineLimit = lineLimit
  }

  public func run() async {
    guard !hasRun else { return }
    hasRun = true

    let detail: ContainerDetail
    do {
      detail = try await engine.inspectContainer(id: container)
    } catch {
      finish(with: error)
      return
    }
    isTTY = detail.hasTTY
    mode = detail.hasTTY ? .singleStream : .separated
    let follow = detail.isRunning
    isFollowing = follow
    state = follow ? .following : .history

    let consumer = Task { [engine, container] () async -> DockerError? in
      do throws(DockerError) {
        try await engine.consumeLogs(id: container, tail: Self.tail, follow: follow) {
          [weak self] chunk in
          await self?.ingest(chunk)
        }
        return nil
      } catch {
        return error
      }
    }
    streamTask = consumer
    let failure = await withTaskCancellationHandler {
      await consumer.value
    } onCancel: {
      consumer.cancel()
    }
    streamTask = nil

    // A malformed frame already ended the session and stopped the stream itself.
    if case .ended = state { return }
    guard let failure else {
      flushPending()
      if isFollowing { state = .ended(.streamClosed) }
      return
    }
    finish(with: failure)
  }

  private func ingest(_ chunk: [UInt8]) {
    if case .ended = state { return }
    let data = Data(chunk)
    var completed: [(LogStreamKind, String)] = []
    var isMalformed = false
    if isTTY {
      completed = assemble(data, stream: .combined)
    } else {
      let (frames, malformed) = decodeFrames(data)
      isMalformed = malformed
      for frame in frames { completed += assemble(frame.payload, stream: frame.stream) }
    }
    confirm(completed)
    if isMalformed {
      flushPending()
      state = .ended(.failed(String(localized: "Could not interpret the log format.", bundle: #bundle)))
      streamTask?.cancel()
      return
    }
    if isFollowing { refreshProvisional() }
  }

  /// `LogFrameDecoder.append` discards the frames it parsed before a bad header, so on failure the chunk is
  /// replayed byte by byte to keep the lines that preceded it.
  private func decodeFrames(_ data: Data) -> (frames: [LogFrameDecoder.Chunk], isMalformed: Bool) {
    let before = decoder
    do {
      return (try decoder.append(data), false)
    } catch {
      decoder = before
      var frames: [LogFrameDecoder.Chunk] = []
      for byte in data {
        guard let parsed = try? decoder.append(Data([byte])) else { return (frames, true) }
        frames += parsed
      }
      return (frames, true)
    }
  }

  private func assemble(_ data: Data, stream: LogStreamKind) -> [(LogStreamKind, String)] {
    assemblers[stream, default: LineAssembler()].append(data).map { (stream, $0) }
  }

  private func confirm(_ completed: [(LogStreamKind, String)]) {
    guard !completed.isEmpty else { return }
    for (stream, text) in completed {
      let id = provisionalIDs.removeValue(forKey: stream) ?? makeID()
      lines.append(LogLine(id: id, stream: stream, text: text))
    }
    if lines.count > lineLimit + max(1, lineLimit / 10) {
      lines.removeFirst(lines.count - lineLimit)
    }
  }

  private func refreshProvisional() {
    var shown: [LogLine] = []
    for (stream, assembler) in assemblers {
      let pending = assembler.pending
      guard !pending.isEmpty else {
        provisionalIDs[stream] = nil
        continue
      }
      let id = provisionalIDs[stream] ?? makeID()
      provisionalIDs[stream] = id
      shown.append(LogLine(id: id, stream: stream, text: pending))
    }
    shown.sort { $0.id < $1.id }
    if shown != provisionalLines { provisionalLines = shown }
  }

  private func flushPending() {
    var flushed: [(LogStreamKind, String)] = []
    for stream in [LogStreamKind.stdout, .stderr, .combined] {
      guard var assembler = assemblers[stream], let text = assembler.finish() else { continue }
      assemblers[stream] = assembler
      flushed.append((stream, text))
    }
    confirm(flushed)
    provisionalIDs.removeAll()
    if !provisionalLines.isEmpty { provisionalLines = [] }
  }

  private func finish(with error: DockerError) {
    guard error != .cancelled else { return }
    flushPending()
    if case .api(404, _) = error {
      state = .ended(.containerGone)
    } else {
      state = .ended(.failed(error.displayMessage))
    }
  }

  private func makeID() -> Int {
    defer { nextID += 1 }
    return nextID
  }
}
