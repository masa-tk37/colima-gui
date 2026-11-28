import Foundation
import Testing

@testable import ColimaCore

@Suite("MachineCommand arguments")
struct MachineCommandTests {
  private let name = MachineName.parse("dev", limaHomeUTF8Count: 21).get()
  private let home = MachineMount(path: "/Users/masahiro", writable: true)

  private func createSpec(
    templateID: String = "ubuntu-24.04", memoryGiB: Double = 4, mounts: [MachineMount]? = nil
  ) -> MachineCreateSpec {
    MachineCreateSpec(
      name: name, template: MachineTemplate(id: templateID)!,
      resources: MachineResources(cpus: 2, memoryGiB: memoryGiB, diskGiB: 100),
      mounts: mounts ?? [home])
  }

  private func editSpec(memoryGiB: Double = 6.5, mounts: [MachineMount]? = nil) -> MachineEditSpec {
    MachineEditSpec(
      resources: MachineResources(cpus: 4, memoryGiB: memoryGiB, diskGiB: 120), mounts: mounts ?? [home])
  }

  @Test func createBuildsTheDocumentedArguments() {
    let arguments = MachineCommand.create(createSpec()).arguments
    #expect(
      arguments == [
        "create", "--tty=false", "--name=cg-dev", "--vm-type=vz", "--cpus=2", "--memory=4", "--disk=100",
        "--containerd=none",
        #"--set=.mounts = [{"location":"/Users/masahiro","mountPoint":"/Users/masahiro","writable":true}]"#,
        #"--set=.env.COLIMAGUI_TEMPLATE = "ubuntu-24.04""#,
        "template:ubuntu-24.04",
      ])
  }

  @Test func createDoesNotStartTheMachine() {
    #expect(!MachineCommand.create(createSpec()).arguments.contains("start"))
  }

  @Test func createWritesTheTemplateIDForTheAliasToo() {
    let arguments = MachineCommand.create(createSpec(templateID: "debian")).arguments
    #expect(arguments.contains(#"--set=.env.COLIMAGUI_TEMPLATE = "debian""#))
    #expect(arguments.last == "template:debian")
  }

  @Test func fractionalMemoryUsesADotSeparator() {
    #expect(MachineCommand.create(createSpec(memoryGiB: 6.5)).arguments.contains("--memory=6.5"))
    #expect(MachineCommand.edit(name, editSpec(memoryGiB: 6.5)).arguments.contains("--memory=6.5"))
  }

  @Test func startStopAndDeleteBuildTheDocumentedArguments() {
    #expect(MachineCommand.start(name).arguments == ["start", "--tty=false", "cg-dev"])
    #expect(MachineCommand.stop(name).arguments == ["stop", "--tty=false", "cg-dev"])
    #expect(MachineCommand.delete(name).arguments == ["delete", "--tty=false", "--force", "cg-dev"])
  }

  @Test func editBuildsTheDocumentedArgumentsAndLeavesTheMarkAlone() {
    let arguments = MachineCommand.edit(name, editSpec()).arguments
    #expect(
      arguments == [
        "edit", "--tty=false", "cg-dev", "--cpus=4", "--memory=6.5", "--disk=120",
        #"--set=.mounts = [{"location":"/Users/masahiro","mountPoint":"/Users/masahiro","writable":true}]"#,
      ])
    #expect(!arguments.joined(separator: " ").contains(".env"))
  }

  @Test func mountsKeepCommasQuotesAndBackslashesInsideOneArgument() throws {
    let path = #"/Volumes/a,b/"c"\d"#
    let mounts = [MachineMount(path: path, writable: false), home]
    let arguments = MachineCommand.edit(name, editSpec(mounts: mounts)).arguments
    let set = try #require(arguments.first { $0.hasPrefix("--set=.mounts = ") })
    let json = String(set.dropFirst("--set=.mounts = ".count))
    let decoded = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(json.utf8))
    #expect(decoded.count == 2)
    #expect(decoded[0]["location"] == .string(path))
    #expect(decoded[0]["mountPoint"] == .string(path))
    #expect(decoded[0]["writable"] == .bool(false))
    #expect(arguments.filter { $0.hasPrefix("--set=") }.count == 1)
  }

  @Test func anInheritedGuestMountPointSurvivesAnEdit() throws {
    let inherited = MachineMount(path: "/Users/me/src", writable: true, mountPoint: "/src")
    let arguments = MachineCommand.edit(name, editSpec(mounts: [inherited, home])).arguments
    let set = try #require(arguments.first { $0.hasPrefix("--set=.mounts = ") })
    let json = String(set.dropFirst("--set=.mounts = ".count))
    let decoded = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(json.utf8))
    #expect(decoded[0]["location"] == .string("/Users/me/src"))
    #expect(decoded[0]["mountPoint"] == .string("/src"))
    #expect(decoded[1]["mountPoint"] == decoded[1]["location"])
  }

  @Test func slashesInPathsAreNotEscaped() {
    let arguments = MachineCommand.edit(name, editSpec()).arguments
    #expect(arguments.contains { $0.contains("/Users/masahiro") && !$0.contains(#"\/"#) })
  }

  @Test func noMountsGiveAnEmptyArray() {
    let arguments = MachineCommand.edit(name, editSpec(mounts: [])).arguments
    #expect(arguments.last == "--set=.mounts = []")
  }

  @Test func everyInstanceNameCarriesThePrefix() {
    let commands: [MachineCommand] = [
      .create(createSpec()), .start(name), .stop(name), .delete(name), .edit(name, editSpec()),
    ]
    for command in commands {
      let instances = command.arguments.filter { $0.hasPrefix("cg-") || $0.hasPrefix("--name=") }
      #expect(!instances.isEmpty)
      #expect(instances.allSatisfy { $0.hasPrefix("cg-") || $0.hasPrefix("--name=cg-") })
      #expect(!command.arguments.contains("dev"))
      #expect(!command.arguments.contains("--name=dev"))
    }
  }

  @Test func everyCommandDisablesTheTerminal() {
    let commands: [MachineCommand] = [
      .create(createSpec()), .start(name), .stop(name), .delete(name), .edit(name, editSpec()),
    ]
    #expect(commands.allSatisfy { $0.arguments.contains("--tty=false") })
  }

  @Test func createDisablesTheContainerRuntime() {
    #expect(MachineCommand.create(createSpec()).arguments.contains("--containerd=none"))
  }

  @Test func nameAndKindAreExposed() {
    #expect(MachineCommand.create(createSpec()).name == name)
    #expect(MachineCommand.edit(name, editSpec()).name == name)
    #expect(MachineCommand.create(createSpec()).kind == .create)
    #expect(MachineCommand.start(name).kind == .start)
    #expect(MachineCommand.stop(name).kind == .stop)
    #expect(MachineCommand.delete(name).kind == .delete)
    #expect(MachineCommand.edit(name, editSpec()).kind == .edit)
  }
}

private enum JSONValue: Decodable, Equatable {
  case string(String)
  case bool(Bool)

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }
}

extension Result {
  fileprivate func get() -> Success where Failure == MachineNameProblem {
    switch self {
    case .success(let value): value
    case .failure(let problem): fatalError("unexpected \(problem)")
    }
  }
}
