import os

/// Subsystem is the app's bundle ID; `Bundle.main` is not used because it is the test host's ID under test.
public enum ColimaLog {
  public static let subsystem = "cc.tk37.ColimaGUI"

  public static let vm = Logger(subsystem: subsystem, category: "vm")
  public static let docker = Logger(subsystem: subsystem, category: "docker")
  public static let process = Logger(subsystem: subsystem, category: "process")
  public static let machine = Logger(subsystem: subsystem, category: "machine")
}
