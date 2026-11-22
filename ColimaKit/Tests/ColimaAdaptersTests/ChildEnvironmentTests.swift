import Testing

@testable import ColimaProcess

struct ChildEnvironmentTests {
  @Test func makeProducesOnlyTheFixedSet() {
    let env = ChildEnvironment.make(home: "/Users/a", user: "a", tmp: "/var/tmp/x/")

    #expect(
      env == [
        "HOME": "/Users/a",
        "USER": "a",
        "LOGNAME": "a",
        "TMPDIR": "/var/tmp/x/",
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
      ])
  }

  @Test func pathPutsHomebrewFirst() {
    #expect(ChildEnvironment.path.hasPrefix("/opt/homebrew/bin:"))
  }

  @Test func currentCopiesOnlyTheAllowedVariablesFromTheParent() {
    let parent = [
      "HOME": "/Users/b",
      "USER": "b",
      "LOGNAME": "b",
      "TMPDIR": "/tmp/b/",
      "PATH": "/somewhere/else",
      "COLIMA_HOME": "/elsewhere",
      "COLIMA_PROFILE": "other",
      "DOCKER_HOST": "unix:///nope",
    ]

    let env = ChildEnvironment.current(parent: parent)

    #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"])
    #expect(env["HOME"] == "/Users/b")
    #expect(env["PATH"] == ChildEnvironment.path)
  }

  @Test func currentFallsBackWhenParentLacksVariables() {
    let env = ChildEnvironment.current(parent: [:])

    #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"])
    #expect(env["HOME"]?.isEmpty == false)
    #expect(env["USER"]?.isEmpty == false)
    #expect(env["TMPDIR"]?.isEmpty == false)
  }
}
