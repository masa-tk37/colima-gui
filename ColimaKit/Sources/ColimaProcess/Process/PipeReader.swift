import Dispatch
import Foundation
import Synchronization

/// `FileHandle.readabilityHandler` is avoided: closing the handle while a handler is in flight raises an
/// Objective-C exception, so the descriptor is closed only from the source's cancel handler.
final class PipeReader: @unchecked Sendable {
  private let source: any DispatchSourceRead
  init(
    readEnd: FileHandle, queue: DispatchQueue, onData: @escaping @Sendable (Data) -> Void,
    onEnd: @escaping @Sendable () -> Void
  ) {
    let descriptor = readEnd.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

    let endOfFile = OneShot()
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    self.source = source

    source.setEventHandler { [endOfFile, weak source] in
      guard let source else { return }
      let capacity = max(Int(source.data), 4096)
      var buffer = [UInt8](repeating: 0, count: min(capacity, 1 << 16))
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        onData(Data(buffer[..<count]))
      } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
        source.cancel()
        if endOfFile.claim() { onEnd() }
      }
    }
    source.setCancelHandler {
      try? readEnd.close()
    }
    source.resume()
  }

  func cancel() {
    source.cancel()
  }
}

private final class OneShot: Sendable {
  private let claimed = Mutex(false)

  func claim() -> Bool {
    claimed.withLock { done in
      defer { done = true }
      return !done
    }
  }
}
