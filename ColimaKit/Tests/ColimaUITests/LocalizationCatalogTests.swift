import Foundation
import Testing

/// Run `Scripts/sync-string-catalogs.sh` first: a key missing from the catalog entirely is only caught after a sync.
@Suite struct LocalizationCatalogTests {
  private static let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static let catalogs: [URL] = [
    packageRoot.appending(path: "Sources/ColimaCore/Resources/Localizable.xcstrings"),
    packageRoot.appending(path: "Sources/ColimaAdapters/Resources/Localizable.xcstrings"),
    packageRoot.appending(path: "Sources/ColimaUI/Resources/Localizable.xcstrings"),
    packageRoot.deletingLastPathComponent().appending(path: "ColimaGUI/Localizable.xcstrings"),
  ]

  @Test(arguments: catalogs)
  func everyKeyIsCurrentAndTranslatedToJapanese(catalog: URL) throws {
    let strings = try Self.strings(in: catalog)
    for (key, entry) in strings {
      #expect(entry["extractionState"] as? String != "stale", "stale key in \(catalog.lastPathComponent): \(key)")
      #expect(!key.containsJapanese, "source key is not English: \(key)")
      let japanese = (entry["localizations"] as? [String: Any])?["ja"] as? [String: Any]
      #expect(japanese.map(Self.isTranslated) == true, "missing ja translation: \(key)")
    }
  }

  /// Tests resolve every bundle to English, so this reads the built Japanese tables directly; otherwise a resource that
  /// failed to compile would fall back to English unnoticed.
  @Test(arguments: ["ColimaCore", "ColimaAdapters", "ColimaUI"])
  func builtJapaneseTableMatchesTheCatalog(target: String) throws {
    let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    let resources = try #require(Bundle(url: products.appending(path: "ColimaKit_\(target).bundle")))
    let japanese = try #require(resources.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
    let catalog = Self.packageRoot.appending(path: "Sources/\(target)/Resources/Localizable.xcstrings")
    for (key, entry) in try Self.strings(in: catalog) {
      let unit = ((entry["localizations"] as? [String: Any])?["ja"] as? [String: Any])?["stringUnit"]
      guard let expected = (unit as? [String: Any])?["value"] as? String else { continue }
      #expect(japanese.localizedString(forKey: key, value: nil, table: nil) == expected, "\(target): \(key)")
    }
  }

  @Test(arguments: ["ColimaCore", "ColimaAdapters", "ColimaUI"])
  func bundleOffersEnglishAndJapaneseWithEnglishAsFallback(target: String) throws {
    let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    let resources = try #require(Bundle(url: products.appending(path: "ColimaKit_\(target).bundle")))
    #expect(Set(resources.localizations).isSuperset(of: ["en", "ja"]))
    #expect(Bundle.preferredLocalizations(from: resources.localizations, forPreferences: ["en-US"]) == ["en"])
    #expect(Bundle.preferredLocalizations(from: resources.localizations, forPreferences: ["fr-FR"]) == ["en"])
    #expect(Bundle.preferredLocalizations(from: resources.localizations, forPreferences: ["ja-JP"]) == ["ja"])
  }

  /// Package views must name their bundle: a bare literal becomes a `LocalizedStringKey`, looked up in the app's main
  /// bundle, where the package's keys do not exist.
  @Test func packageViewsNameTheirBundle() throws {
    let sources = Self.packageRoot.appending(path: "Sources/ColimaUI")
    let pattern = try Regex(
      #"\b(Text|Button|Label|LabeledContent|GroupBox|Toggle|Section|Menu|ContentUnavailableView|Picker|TextField|Stepper|ProgressView|Link|DisclosureGroup)\(\s*""#
        + #"|\.(navigationTitle|help|accessibilityLabel|accessibilityHint|accessibilityValue|badge)\(\s*""#)
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for file in files {
      let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        #expect(!line.contains("LocalizedStringKey"), "\(file.lastPathComponent):\(index + 1) uses LocalizedStringKey")
        guard line.contains(pattern), !line.contains("bundle:") else { continue }
        Issue.record("\(file.lastPathComponent):\(index + 1) passes a literal without its bundle: \(line)")
      }
    }
  }

  private static func strings(in catalog: URL) throws -> [String: [String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
    return try #require(object?["strings"] as? [String: [String: Any]])
  }

  /// Japanese has no plural forms, but a plural-varied entry is accepted when its `other` form is translated.
  private static func isTranslated(_ localization: [String: Any]) -> Bool {
    if let unit = localization["stringUnit"] as? [String: Any] {
      return unit["state"] as? String == "translated"
    }
    let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any]
    let other = (plural?["other"] as? [String: Any])?["stringUnit"] as? [String: Any]
    return other?["state"] as? String == "translated"
  }
}

extension String {
  fileprivate var containsJapanese: Bool {
    unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
  }
}

private final class BundleAnchor {}
