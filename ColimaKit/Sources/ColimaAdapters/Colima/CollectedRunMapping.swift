import ColimaCore
import ColimaProcess

extension CollectedRun {
  private static let diagnosticLineLimit = 50

  func successfulStdout() throws(ColimaCLIError) -> [UInt8] {
    switch termination {
    case .exited(code: 0):
      return stdout
    case .exited(let code):
      let stderrLines = Self.tail(stderrText)
      throw .nonZeroExit(
        code: code, output: stderrLines.isEmpty ? Self.tail(stdoutText) : stderrLines)
    case .timedOut:
      throw .timedOut
    case .cancelled:
      throw .cancelled
    case .launchFailed(let reason):
      throw .launchFailed(reason: reason)
    }
  }

  static func tail(_ text: String) -> [String] {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    return Array(lines.suffix(diagnosticLineLimit))
  }
}
