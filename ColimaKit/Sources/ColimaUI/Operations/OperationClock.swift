import Foundation

enum OperationClock {
  static func text(seconds: Int) -> String {
    let duration = Duration.seconds(seconds)
    return seconds >= 3600
      ? duration.formatted(.time(pattern: .hourMinuteSecond))
      : duration.formatted(.time(pattern: .minuteSecond))
  }
}
