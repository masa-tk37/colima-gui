import ColimaCore
import Foundation
import Testing

@testable import ColimaProcess

struct LimaInvocationTests {
  private func makeHome() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("lima-invocation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func machine(_ name: String) throws -> MachineName {
    try MachineName.parse(name, limaHomeUTF8Count: 20).get()
  }

  @Test func pathsAreDerivedFromTheHomeDirectory() {
    let invocation = LimaInvocation(homeDirectory: "/Users/a")

    #expect(invocation.limactlPath == "/opt/homebrew/bin/limactl")
    #expect(invocation.limaHome == "/Users/a/.lima")
    #expect(invocation.workingDirectory == "/Users/a/.colima-gui")
  }

  @Test func limactlPathFollowsTheHomebrewDirectory() {
    let invocation = LimaInvocation(homebrewDirectory: "/fake/bin", homeDirectory: "/Users/a")

    #expect(invocation.limactlPath == "/fake/bin/limactl")
  }

  @Test func instanceDirectoryIsTheInstanceNameUnderLimaHome() throws {
    let invocation = LimaInvocation(homeDirectory: "/Users/a")

    #expect(try invocation.instanceDirectory(for: machine("dev")) == "/Users/a/.lima/cg-dev")
  }

  @Test func limaHomeOverridesTheParentLimaHome() {
    let invocation = LimaInvocation(homeDirectory: "/Users/a")
    let parent = [
      "HOME": "/Users/a",
      "USER": "a",
      "LIMA_HOME": "/Users/a/.colima/_lima",
      "COLIMA_HOME": "/elsewhere",
    ]

    let env = invocation.environment(parent: parent)

    #expect(env["LIMA_HOME"] == "/Users/a/.lima")
    #expect(env["PATH"] == ChildEnvironment.path)
    #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LIMA_HOME"])
  }

  @Test func limaHomeIsSetWhenTheParentHasNone() {
    let invocation = LimaInvocation(homeDirectory: "/Users/a")

    #expect(invocation.environment(parent: [:])["LIMA_HOME"] == "/Users/a/.lima")
  }

  @Test func makeBuildsTheInvocationForLimactl() {
    let invocation = LimaInvocation(homeDirectory: "/Users/a")

    let made = invocation.make(["list", "--json"], timeout: .seconds(5))

    #expect(made.executable == "/opt/homebrew/bin/limactl")
    #expect(made.arguments == ["list", "--json"])
    #expect(made.workingDirectory == "/Users/a/.colima-gui")
    #expect(made.timeout == .seconds(5))
    #expect(made.environment["LIMA_HOME"] == "/Users/a/.lima")
  }

  @Test func limaHomeCountUsesThePathAsIsWhenItDoesNotExist() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let invocation = LimaInvocation(homeDirectory: home.path)

    #expect(invocation.limaHomeUTF8Count == (home.path + "/.lima").utf8.count)
  }

  @Test func limaHomeCountUsesTheResolvedPathWhenItIsASymbolicLink() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let target = home.appendingPathComponent("a-much-longer-directory-name/real-lima")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: home.appendingPathComponent(".lima").path, withDestinationPath: target.path)

    let invocation = LimaInvocation(homeDirectory: home.path)

    let expected = realPath(target.path).utf8.count
    #expect(invocation.limaHomeUTF8Count == expected)
    #expect(invocation.limaHomeUTF8Count > (home.path + "/.lima").utf8.count)
  }

  @Test func limaHomeCountResolvesAnExistingDirectoryToItsRealPath() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".lima"), withIntermediateDirectories: true)

    let invocation = LimaInvocation(homeDirectory: home.path)

    #expect(invocation.limaHomeUTF8Count == realPath(home.path + "/.lima").utf8.count)
  }

  @Test func prepareWorkingDirectoryCreatesItWithMode0700() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let invocation = LimaInvocation(homeDirectory: home.path)

    try invocation.prepareWorkingDirectory()

    let attributes = try FileManager.default.attributesOfItem(atPath: invocation.workingDirectory)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
    #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
  }

  @Test func prepareWorkingDirectoryIsIdempotentAndLeavesContents() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let invocation = LimaInvocation(homeDirectory: home.path)
    try invocation.prepareWorkingDirectory()
    let marker = invocation.workingDirectory + "/lima.REJECTED.yaml"
    try Data("x".utf8).write(to: URL(fileURLWithPath: marker))

    try invocation.prepareWorkingDirectory()

    #expect(FileManager.default.fileExists(atPath: marker))
  }

  @Test func prepareWorkingDirectoryDoesNotTouchLimaHome() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let invocation = LimaInvocation(homeDirectory: home.path)

    try invocation.prepareWorkingDirectory()

    #expect(!FileManager.default.fileExists(atPath: invocation.limaHome))
  }
}
