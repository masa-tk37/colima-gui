import Foundation

package struct ColimaInvocation: Sendable {
  package let homebrewDirectory: String
  package let homeDirectory: String

  package init(
    homebrewDirectory: String = "/opt/homebrew/bin", homeDirectory: String = NSHomeDirectory()
  ) {
    self.homebrewDirectory = homebrewDirectory
    self.homeDirectory = homeDirectory
  }

  package var colimaPath: String { homebrewDirectory + "/colima" }

  package func make(_ arguments: [String], timeout: Duration?) -> ProcessInvocation {
    ProcessInvocation(
      executable: colimaPath,
      arguments: arguments,
      environment: ChildEnvironment.current(),
      workingDirectory: homeDirectory,
      timeout: timeout
    )
  }
}
