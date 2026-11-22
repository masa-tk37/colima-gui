import Foundation
import Testing

func wireFixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  return try Data(contentsOf: url)
}
