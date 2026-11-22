import ColimaCore
import Foundation
import Testing

@testable import ColimaAdapters

private let profileYAML = """
  # Number of CPUs to be allocated to the virtual machine.
  cpu: 10 # keep me

  disk: 100
  memory: 8

  # Default: qemu
  vmType: vz

  mounts:
    - location: /Users/example
      writable: true
  """

private struct TempHome {
  let base: URL
  var profileURL: URL { base.appendingPathComponent(".colima/default/colima.yaml") }
  var profileDirectory: URL { profileURL.deletingLastPathComponent() }
  var stateURL: URL { base.appendingPathComponent(".colima/_lima/colima/colima.yaml") }

  init() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("colima-profile-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  func writeProfile(_ text: String = profileYAML, permissions: Int = 0o644) throws {
    try write(text, to: profileURL, permissions: permissions)
  }

  func writeState(_ text: String) throws {
    try write(text, to: stateURL, permissions: 0o644)
  }

  func write(_ text: String, to url: URL, permissions: Int) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  func makeStore() -> ColimaProfileFiles { ColimaProfileFiles(baseDirectory: base) }

  func cleanup() {
    // Restore access first so a read-only directory made by a test can be removed.
    if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
      for case let url as URL in walker {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }
    }
    try? FileManager.default.removeItem(at: base)
  }
}

private func text(_ url: URL) throws -> String {
  try String(contentsOf: url, encoding: .utf8)
}

private func permissions(_ url: URL) throws -> Int {
  let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  return try #require(value)
}

private func names(in directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private let newSettings = VMResourceSettings(cpus: 6, memoryGiB: 12, diskGiB: 150)

// MARK: - readProfileSettings

@Test func readsResourcesAndVMTypeFromProfile() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile()

  let settings = try home.makeStore().readProfileSettings()

  #expect(
    settings
      == ProfileSettings(
        resources: VMResourceSettings(cpus: 10, memoryGiB: 8, diskGiB: 100),
        vmType: .vz
      ))
}

@Test func readsFractionalMemory() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: 2\nmemory: 0.5\ndisk: 60\n")

  let settings = try home.makeStore().readProfileSettings()

  #expect(settings?.resources == VMResourceSettings(cpus: 2, memoryGiB: 0.5, diskGiB: 60))
  #expect(settings?.vmType == nil)
}

@Test func absentProfileReadsAsNil() throws {
  let home = try TempHome()
  defer { home.cleanup() }

  #expect(try home.makeStore().readProfileSettings() == nil)
}

@Test func missingKeyIsUnexpectedFormat() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: 2\ndisk: 60\n")

  #expect(throws: ColimaFileError.self) { try home.makeStore().readProfileSettings() }
  do {
    _ = try home.makeStore().readProfileSettings()
  } catch {
    guard case .unexpectedFormat(let key, _) = error else {
      Issue.record("expected unexpectedFormat, got \(error)")
      return
    }
    #expect(key == "memory")
  }
}

@Test func duplicateKeyIsUnexpectedFormat() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: 2\ncpu: 3\nmemory: 4\ndisk: 60\n")

  do {
    _ = try home.makeStore().readProfileSettings()
    Issue.record("expected a throw")
  } catch {
    guard case .unexpectedFormat(let key, _) = error else {
      Issue.record("expected unexpectedFormat, got \(error)")
      return
    }
    #expect(key == "cpu")
  }
}

@Test func nonNumericValueIsUnexpectedFormat() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: many\nmemory: 4\ndisk: 60\n")

  do {
    _ = try home.makeStore().readProfileSettings()
    Issue.record("expected a throw")
  } catch {
    guard case .unexpectedFormat(let key, _) = error else {
      Issue.record("expected unexpectedFormat, got \(error)")
      return
    }
    #expect(key == "cpu")
  }
}

@Test func indentedKeysAreIgnoredOnRead() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: 2\nmemory: 4\ndisk: 60\nnested:\n  cpu: 99\n  vmType: qemu\n")

  let settings = try home.makeStore().readProfileSettings()

  #expect(settings?.resources.cpus == 2)
  #expect(settings?.vmType == nil)
}

@Test func unknownVMTypeReadsAsNil() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile("cpu: 2\nmemory: 4\ndisk: 60\nvmType: hyperv\n")

  #expect(try home.makeStore().readProfileSettings()?.vmType == nil)
}

@Test func profilePathThatIsADirectoryIsUnreadable() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try FileManager.default.createDirectory(at: home.profileURL, withIntermediateDirectories: true)

  #expect {
    try home.makeStore().readProfileSettings()
  } throws: { error in
    guard case ColimaFileError.unreadable = error else { return false }
    return true
  }
}

// MARK: - writeProfileSettings

@Test func writeReplacesOnlyTheThreeLines() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile()

  try home.makeStore().writeProfileSettings(newSettings)

  let expected =
    profileYAML
    .replacingOccurrences(of: "cpu: 10 # keep me", with: "cpu: 6 # keep me")
    .replacingOccurrences(of: "disk: 100", with: "disk: 150")
    .replacingOccurrences(of: "memory: 8", with: "memory: 12")
  #expect(try text(home.profileURL) == expected)
  #expect(try home.makeStore().readProfileSettings()?.resources == newSettings)
}

@Test(arguments: [0o600, 0o644, 0o640])
func writeKeepsPermissions(mode: Int) throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile(permissions: mode)

  try home.makeStore().writeProfileSettings(newSettings)

  #expect(try permissions(home.profileURL) == mode)
}

@Test func writeLeavesNoTemporaryFileBehind() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile()

  try home.makeStore().writeProfileSettings(newSettings)

  #expect(try names(in: home.profileDirectory) == ["colima.yaml"])
}

@Test func writeRereadsTheFileJustBeforeSaving() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile()
  let store = home.makeStore()
  _ = try store.readProfileSettings()

  try home.writeProfile(profileYAML + "\n# added by colima meanwhile\nrosetta: true\n")
  try store.writeProfileSettings(newSettings)

  let saved = try text(home.profileURL)
  #expect(saved.contains("# added by colima meanwhile\nrosetta: true\n"))
  #expect(saved.contains("cpu: 6 # keep me"))
}

@Test func writeToUnexpectedFormatChangesNothing() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let original = "cpu: 2\nmemory: 4\n"
  try home.writeProfile(original)

  do {
    try home.makeStore().writeProfileSettings(newSettings)
    Issue.record("expected a throw")
  } catch {
    guard case .unexpectedFormat(let key, _) = error else {
      Issue.record("expected unexpectedFormat, got \(error)")
      return
    }
    #expect(key == "disk")
  }
  #expect(try text(home.profileURL) == original)
  #expect(try names(in: home.profileDirectory) == ["colima.yaml"])
}

@Test func writeToAbsentProfileIsUnreadableAndCreatesNothing() throws {
  let home = try TempHome()
  defer { home.cleanup() }

  #expect {
    try home.makeStore().writeProfileSettings(newSettings)
  } throws: { error in
    guard case ColimaFileError.unreadable = error else { return false }
    return true
  }
  #expect(!FileManager.default.fileExists(atPath: home.profileDirectory.path))
}

@Test func writeFailsAndKeepsOriginalWhenDirectoryIsNotWritable() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeProfile()
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o555], ofItemAtPath: home.profileDirectory.path)

  #expect {
    try home.makeStore().writeProfileSettings(newSettings)
  } throws: { error in
    guard case ColimaFileError.writeFailed(let path, _) = error else { return false }
    return path.hasSuffix("/.colima/default/colima.yaml")
  }
  #expect(try text(home.profileURL) == profileYAML)
  #expect(try names(in: home.profileDirectory) == ["colima.yaml"])
}

// MARK: - symbolic links

@Test func writeThroughSymlinkKeepsLinkAndChangesOnlyTheTargetLines() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let target = home.base.appendingPathComponent("dotfiles/colima.yaml")
  try home.write(profileYAML, to: target, permissions: 0o600)
  try FileManager.default.createDirectory(
    at: home.profileDirectory, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: home.profileURL, withDestinationURL: target)

  #expect(try home.makeStore().readProfileSettings()?.resources.cpus == 10)
  try home.makeStore().writeProfileSettings(newSettings)

  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: home.profileURL.path) == target.path)
  let expected =
    profileYAML
    .replacingOccurrences(of: "cpu: 10 # keep me", with: "cpu: 6 # keep me")
    .replacingOccurrences(of: "disk: 100", with: "disk: 150")
    .replacingOccurrences(of: "memory: 8", with: "memory: 12")
  #expect(try text(target) == expected)
  #expect(try permissions(target) == 0o600)
  #expect(try names(in: target.deletingLastPathComponent()) == ["colima.yaml"])
  #expect(try names(in: home.profileDirectory) == ["colima.yaml"])
}

@Test func writeFollowsAChainOfSymlinks() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let target = home.base.appendingPathComponent("real/colima.yaml")
  try home.write(profileYAML, to: target, permissions: 0o644)
  let middle = home.base.appendingPathComponent("middle.yaml")
  try FileManager.default.createSymbolicLink(
    atPath: middle.path, withDestinationPath: "real/colima.yaml")
  try FileManager.default.createDirectory(
    at: home.profileDirectory, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    atPath: home.profileURL.path, withDestinationPath: middle.path)

  try home.makeStore().writeProfileSettings(newSettings)

  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: home.profileURL.path) == middle.path)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: middle.path) == "real/colima.yaml")
  #expect(try text(target).contains("cpu: 6 # keep me"))
}

@Test func danglingSymlinkIsUnreadableAndNothingIsCreated() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let target = home.base.appendingPathComponent("missing/colima.yaml")
  try FileManager.default.createDirectory(
    at: home.profileDirectory, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: home.profileURL, withDestinationURL: target)

  #expect {
    try home.makeStore().readProfileSettings()
  } throws: { error in
    guard case ColimaFileError.unreadable = error else { return false }
    return true
  }
  #expect {
    try home.makeStore().writeProfileSettings(newSettings)
  } throws: { error in
    guard case ColimaFileError.unreadable = error else { return false }
    return true
  }
  #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: home.profileURL.path) == target.path)
}

@Test func symlinkTargetDirectoryNotWritableIsWriteFailedAndChangesNothing() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let target = home.base.appendingPathComponent("dotfiles/colima.yaml")
  try home.write(profileYAML, to: target, permissions: 0o644)
  try FileManager.default.createDirectory(
    at: home.profileDirectory, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: home.profileURL, withDestinationURL: target)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o555], ofItemAtPath: target.deletingLastPathComponent().path)

  #expect {
    try home.makeStore().writeProfileSettings(newSettings)
  } throws: { error in
    guard case ColimaFileError.writeFailed = error else { return false }
    return true
  }
  #expect(try text(target) == profileYAML)
  #expect(try names(in: target.deletingLastPathComponent()) == ["colima.yaml"])
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: home.profileURL.path) == target.path)
}

// MARK: - readInstanceVMType

@Test func instanceStateReadsTopLevelVMType() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeState(
    """
    # generated
    arch: aarch64
    vmType: vz
    mounts:
      - location: /x
    """)

  #expect(try home.makeStore().readInstanceVMType() == .vz)
}

@Test func instanceStateAcceptsQuotedValue() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeState("vmType: \"qemu\"\n")

  #expect(try home.makeStore().readInstanceVMType() == .qemu)
}

@Test func instanceStateIgnoresIndentedVMType() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  try home.writeState("nested:\n  vmType: qemu\n")

  #expect(try home.makeStore().readInstanceVMType() == nil)
}

@Test func instanceStateAbsentFileReadsAsNil() throws {
  let home = try TempHome()
  defer { home.cleanup() }

  #expect(try home.makeStore().readInstanceVMType() == nil)
}

@Test func instanceStateDoesNotTouchTheFile() throws {
  let home = try TempHome()
  defer { home.cleanup() }
  let original = "vmType: vz\n"
  try home.writeState(original)

  _ = try home.makeStore().readInstanceVMType()

  #expect(try text(home.stateURL) == original)
}
