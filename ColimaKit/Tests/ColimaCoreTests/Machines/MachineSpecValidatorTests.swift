import Testing

@testable import ColimaCore

@Suite("MachineSpecValidator")
struct MachineSpecValidatorTests {
  private let host = HostResources(cpus: 8, memoryGiB: 16, diskGiB: 460)
  private let ubuntu = MachineTemplate(id: "ubuntu")!
  private let debian12 = MachineTemplate(id: "debian-12")!

  private func context(
    host: HostResources? = nil,
    appKeys: Set<MachineKey> = [],
    unownedKeys: Set<MachineKey> = []
  ) -> MachineCreateContext {
    MachineCreateContext(
      host: host ?? self.host,
      homeDirectory: "/Users/masahiro",
      limaHomeUTF8Count: 21,
      appMachineKeys: appKeys,
      unownedMachineKeys: unownedKeys,
      templates: [ubuntu, debian12])
  }

  private func input(
    name: String = "dev", templateID: String? = "ubuntu",
    cpus: String = "2", memory: String = "4", disk: String = "100"
  ) -> MachineFormInput {
    MachineFormInput(name: name, templateID: templateID, cpus: cpus, memoryGiB: memory, diskGiB: disk)
  }

  private func key(_ name: String) -> MachineKey {
    guard case .success(let parsed) = MachineName.parse(name, limaHomeUTF8Count: 21) else {
      preconditionFailure("test name must parse")
    }
    return parsed.key
  }

  private func createFailure(_ input: MachineFormInput, context: MachineCreateContext? = nil) -> [MachineFieldError] {
    guard case .failure(let failure) = MachineSpecValidator.validateCreate(input, context: context ?? self.context())
    else { return [] }
    return failure.fields
  }

  private func createFields(_ input: MachineFormInput, context: MachineCreateContext? = nil) -> [MachineField] {
    createFailure(input, context: context).map(\.field)
  }

  private func editInput(
    cpus: String = "2", memory: String = "4", disk: String = "100", mounts: [MachineMount] = []
  ) -> MachineEditInput {
    MachineEditInput(cpus: cpus, memoryGiB: memory, diskGiB: disk, mounts: mounts)
  }

  private let currentDiskBytes: Int64 = 100 << 30

  private func editFailure(
    _ input: MachineEditInput, currentDiskBytes: Int64? = nil, currentMounts: [MachineMount] = [],
    host: HostResources? = nil, directoryExists: @escaping (String) -> Bool = { _ in true }
  ) -> [MachineFieldError] {
    let result = MachineSpecValidator.validateEdit(
      input, currentDiskBytes: currentDiskBytes ?? self.currentDiskBytes, currentMounts: currentMounts,
      host: host ?? self.host, directoryExists: directoryExists)
    guard case .failure(let failure) = result else { return [] }
    return failure.fields
  }

  // MARK: create, defaults

  @Test func defaultsAre2CPU4GiB100GiBAndPassValidation() throws {
    let defaults = MachineFormInput.defaults(firstTemplateID: "ubuntu")

    #expect(defaults.cpus == "2")
    #expect(defaults.memoryGiB == "4")
    #expect(defaults.diskGiB == "100")
    #expect(defaults.name == "")
    #expect(defaults.templateID == "ubuntu")
    #expect(MachineFormInput.defaults(firstTemplateID: nil).templateID == nil)

    var filled = defaults
    filled.name = "dev"
    let spec = try MachineSpecValidator.validateCreate(filled, context: context()).get()
    #expect(spec.resources == MachineResources(cpus: 2, memoryGiB: 4, diskGiB: 100))
  }

  @Test func successCarriesNameTemplateResourcesAndTheWritableHomeMount() throws {
    let spec = try MachineSpecValidator.validateCreate(
      input(name: "Dev", templateID: "debian-12", cpus: "4", memory: "8.5", disk: "50"), context: context()
    ).get()

    #expect(spec.name.rawValue == "Dev")
    #expect(spec.name.instanceName == "cg-Dev")
    #expect(spec.template == debian12)
    #expect(spec.resources.cpus == 4)
    #expect(spec.resources.memoryGiB == 8.5)
    #expect(spec.resources.diskGiB == 50)
    #expect(spec.mounts == [MachineMount(path: "/Users/masahiro", writable: true)])
  }

  @Test func resourcesAtTheHostLimitPass() throws {
    let spec = try MachineSpecValidator.validateCreate(
      input(cpus: "8", memory: "16", disk: "460"), context: context()
    ).get()

    #expect(spec.resources == MachineResources(cpus: 8, memoryGiB: 16, diskGiB: 460))
  }

  // MARK: create, name

  @Test func emptyNameIsReportedOnTheNameField() {
    let errors = createFailure(input(name: ""))

    #expect(errors.map(\.field) == [.name])
    #expect(!errors[0].message.isEmpty)
  }

  @Test(arguments: ["a b", "-dev", "dev/x", "dev.yml", "日本語"])
  func invalidCharactersAreReportedOnTheNameField(name: String) {
    #expect(createFields(input(name: name)) == [.name])
  }

  @Test func aNameOverTheLengthLimitIsReported() {
    let limit = MachineName.maxLength(limaHomeUTF8Count: 21)

    #expect(createFields(input(name: String(repeating: "a", count: limit))) == [])
    #expect(createFields(input(name: String(repeating: "a", count: limit + 1))) == [.name])
  }

  @Test func theLengthLimitFollowsTheLimaHomePath() {
    let longHome = MachineCreateContext(
      host: host, homeDirectory: "/Users/masahiro", limaHomeUTF8Count: 60, appMachineKeys: [],
      unownedMachineKeys: [], templates: [ubuntu])

    #expect(MachineName.maxLength(limaHomeUTF8Count: 60) < 20)
    #expect(createFields(input(name: String(repeating: "a", count: 20)), context: longHome) == [.name])
  }

  @Test func aDuplicateOfAnAppMachineIsReportedInAnyCase() {
    let existing = context(appKeys: [key("dev")])

    #expect(createFields(input(name: "dev"), context: existing) == [.name])
    #expect(createFields(input(name: "DEV"), context: existing) == [.name])
    #expect(createFields(input(name: "dev2"), context: existing) == [])
  }

  @Test(arguments: ["default", "colima", "Default", "COLIMA"])
  func reservedNamesAreRejectedAsConflictsWithTheDefaultVM(name: String) {
    #expect(createFields(input(name: name)) == [.name])
  }

  @Test func aCollisionWithAnUnownedInstanceIsReportedInAnyCase() {
    let unowned = context(unownedKeys: [key("dev")])

    #expect(createFields(input(name: "dev"), context: unowned) == [.name])
    #expect(createFields(input(name: "Dev"), context: unowned) == [.name])
    #expect(createFields(input(name: "other"), context: unowned) == [])
  }

  @Test func duplicateCollisionAndReservedMessagesDiffer() {
    let both = context(appKeys: [key("dup")], unownedKeys: [key("ext")])
    let messages = [
      createFailure(input(name: "dup"), context: both)[0].message,
      createFailure(input(name: "ext"), context: both)[0].message,
      createFailure(input(name: "default"), context: both)[0].message,
      createFailure(input(name: ""), context: both)[0].message,
      createFailure(input(name: "a b"), context: both)[0].message,
    ]

    #expect(Set(messages).count == messages.count)
  }

  // MARK: create, template

  @Test(arguments: [nil, "", "alpine", "ubuntu-99.1", "default", "docker"])
  func aTemplateOutsideTheOfferedListIsReported(templateID: String?) {
    #expect(createFields(input(templateID: templateID)) == [.template])
  }

  // MARK: create, resources

  @Test(arguments: ["0", "-1", "", "abc", "1.5", "1e1", "+2", " ", "٣", "99999999999999999999"])
  func invalidCPUIsReported(cpus: String) {
    #expect(createFields(input(cpus: cpus)) == [.cpu])
  }

  @Test(arguments: ["0", "-4", "", "abc", "nan", "inf", "1e1", "0.5", "1."])
  func invalidMemoryIsReported(memory: String) {
    #expect(createFields(input(memory: memory)) == [.memory])
  }

  @Test(arguments: ["0", "-100", "", "abc", "1.5"])
  func invalidDiskIsReported(disk: String) {
    #expect(createFields(input(disk: disk)) == [.disk])
  }

  @Test func resourcesOverTheHostLimitAreReported() {
    #expect(createFields(input(cpus: "9")) == [.cpu])
    #expect(createFields(input(memory: "16.5")) == [.memory])
    #expect(createFields(input(memory: "17")) == [.memory])
    #expect(createFields(input(disk: "461")) == [.disk])
  }

  @Test func theOverLimitMessageNamesTheLimit() {
    let message = createFailure(input(cpus: "9"))[0].message

    #expect(message.contains("8"))
  }

  @Test func everyBadFieldIsReportedAtOnceInFormOrder() {
    let fields = createFields(input(name: "", templateID: nil, cpus: "0", memory: "x", disk: "-1"))

    #expect(fields == [.name, .template, .cpu, .memory, .disk])
  }

  // MARK: edit, resources and disk

  @Test func editWithUnchangedValuesPassesAndKeepsTheMounts() throws {
    let mounts = [MachineMount(path: "/Users/masahiro/work", writable: true)]
    let spec = try MachineSpecValidator.validateEdit(
      editInput(mounts: mounts), currentDiskBytes: currentDiskBytes, host: host, directoryExists: { _ in true }
    ).get()

    #expect(spec.resources == MachineResources(cpus: 2, memoryGiB: 4, diskGiB: 100))
    #expect(spec.mounts == mounts)
  }

  @Test func shrinkingTheDiskIsRejectedAndTheSameSizePasses() {
    #expect(editFailure(editInput(disk: "99")).map(\.field) == [.disk])
    #expect(editFailure(editInput(disk: "100")).isEmpty)
    #expect(editFailure(editInput(disk: "101")).isEmpty)
  }

  @Test func theDiskFloorComparesBytesSoAPartialGiBRoundsUp() {
    let current = (100 << 30) + 1 as Int64

    #expect(editFailure(editInput(disk: "100"), currentDiskBytes: current).map(\.field) == [.disk])
    #expect(editFailure(editInput(disk: "101"), currentDiskBytes: current).isEmpty)
  }

  @Test func theShrinkMessageNamesTheCurrentSize() {
    #expect(editFailure(editInput(disk: "10"))[0].message.contains("100"))
  }

  @Test func editReportsInvalidAndOverLimitResourcesPerField() {
    let fields = editFailure(editInput(cpus: "0", memory: "17", disk: "abc")).map(\.field)

    #expect(fields == [.cpu, .memory, .disk])
    #expect(editFailure(editInput(cpus: "9")).map(\.field) == [.cpu])
    #expect(editFailure(editInput(disk: "461")).map(\.field) == [.disk])
  }

  @Test func aDiskAlreadyOverTheHostLimitCanStayTheSame() {
    let small = HostResources(cpus: 8, memoryGiB: 16, diskGiB: 80)

    #expect(editFailure(editInput(disk: "100"), host: small).isEmpty)
    #expect(editFailure(editInput(disk: "101"), host: small).map(\.field) == [.disk])
  }

  // MARK: edit, mounts

  @Test func aMissingDirectoryIsReportedOnItsMountIndex() {
    let mounts = [
      MachineMount(path: "/Users/masahiro/ok", writable: true),
      MachineMount(path: "/Users/masahiro/missing", writable: false),
    ]
    let errors = editFailure(editInput(mounts: mounts), directoryExists: { $0 == "/Users/masahiro/ok" })

    #expect(errors.map(\.field) == [.mount(index: 1)])
  }

  @Test func aFolderTheMachineAlreadySharesNeedNotExistButANewOneMust() {
    let unplugged = MachineMount(path: "/Volumes/unplugged", writable: false)
    let input = editInput(mounts: [unplugged, MachineMount(path: "/Volumes/new-and-missing", writable: false)])
    let errors = editFailure(input, currentMounts: [unplugged], directoryExists: { _ in false })

    #expect(errors.map(\.field) == [.mount(index: 1)])
  }

  @Test(arguments: ["relative/dir", "~", "~/work", "", "/Users/{{.User}}/x", "{{.Home}}"])
  func relativeAndExpandedPathsAreRejectedWithoutAskingTheFileSystem(path: String) {
    var asked: [String] = []
    let errors = editFailure(
      editInput(mounts: [MachineMount(path: path, writable: false)]),
      directoryExists: {
        asked.append($0)
        return true
      })

    #expect(errors.map(\.field) == [.mount(index: 0)])
    #expect(asked.isEmpty)
  }

  @Test func containedAndIdenticalPathsAreRejected() {
    let nested = [
      MachineMount(path: "/Users/masahiro", writable: true),
      MachineMount(path: "/Users/masahiro/work", writable: false),
    ]
    let same = [
      MachineMount(path: "/Users/masahiro/work", writable: true),
      MachineMount(path: "/Users/masahiro/work", writable: false),
    ]
    let nestedFirstInner = Array(nested.reversed())

    #expect(editFailure(editInput(mounts: nested)).map(\.field) == [.mount(index: 1)])
    #expect(editFailure(editInput(mounts: same)).map(\.field) == [.mount(index: 1)])
    #expect(editFailure(editInput(mounts: nestedFirstInner)).map(\.field) == [.mount(index: 1)])
  }

  @Test func trailingSlashesAndDotSegmentsDoNotHideAnOverlap() {
    let trailing = [MachineMount(path: "/a/b/", writable: true), MachineMount(path: "/a/b", writable: true)]
    let dots = [MachineMount(path: "/a/b", writable: true), MachineMount(path: "/a/./b/c/../d", writable: true)]

    #expect(editFailure(editInput(mounts: trailing)).map(\.field) == [.mount(index: 1)])
    #expect(editFailure(editInput(mounts: dots)).map(\.field) == [.mount(index: 1)])
  }

  @Test func siblingsWithACommonPrefixDoNotOverlap() {
    let mounts = [MachineMount(path: "/Users/masahiro/work", writable: true), MachineMount(path: "/Users/masahiro/work2", writable: true)]

    #expect(editFailure(editInput(mounts: mounts)).isEmpty)
  }

  @Test func resourceAndMountErrorsAreReportedTogether() {
    let errors = editFailure(
      editInput(cpus: "0", mounts: [MachineMount(path: "/gone", writable: true)]), directoryExists: { _ in false })

    #expect(errors.map(\.field) == [.cpu, .mount(index: 0)])
  }

  @Test func mountMessagesDifferByReason() {
    let missing = editFailure(editInput(mounts: [MachineMount(path: "/gone", writable: true)]), directoryExists: { _ in false })
    let relative = editFailure(editInput(mounts: [MachineMount(path: "gone", writable: true)]))
    let overlap = editFailure(
      editInput(mounts: [MachineMount(path: "/a", writable: true), MachineMount(path: "/a/b", writable: true)]))

    #expect(Set([missing[0].message, relative[0].message, overlap[0].message]).count == 3)
  }
}
