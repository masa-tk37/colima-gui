import Foundation
import Testing

@Test func fixturesDirectoryIsBundledAsResource() throws {
  let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  var isDirectory: ObjCBool = false
  #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
  #expect(isDirectory.boolValue)
}
