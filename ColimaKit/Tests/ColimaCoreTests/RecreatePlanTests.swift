import Testing

@testable import ColimaCore

private let colima = ToolchainStatus.ColimaLookup.found(path: "/opt/homebrew/bin/colima")

private func spec(_ type: VMType, diskGiB: Int = 100) -> VMCreateSpec {
  VMCreateSpec(resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: diskGiB), vmType: type)
}

private let everythingInstalled = ToolchainStatus(
  colima: colima,
  installedExecutables: ["qemu-img", "qemu-system-aarch64", "krunkit"]
)

@Test func recreatePlanIsAcceptedForADifferentVMType() throws {
  let result = RecreatePlan.make(
    spec: spec(.qemu), currentVMType: .vz, toolchain: everythingInstalled)
  let plan = try result.get()
  #expect(plan.spec == spec(.qemu))
  #expect(plan.currentVMType == .vz)
}

@Test(arguments: VMType.allCases)
func recreatePlanRejectsTheCurrentVMType(type: VMType) {
  let result = RecreatePlan.make(
    spec: spec(type), currentVMType: type, toolchain: everythingInstalled)
  #expect(result == .failure(.sameVMType))
}

@Test func recreatePlanRejectsMissingExecutablesOfTheTargetType() {
  let toolchain = ToolchainStatus(colima: colima, installedExecutables: ["qemu-img"])
  let result = RecreatePlan.make(spec: spec(.qemu), currentVMType: .vz, toolchain: toolchain)
  #expect(result == .failure(.missingExecutables(vmType: .qemu, missing: ["qemu-system-aarch64"])))
}

@Test func recreatePlanIgnoresExecutablesOfOtherVMTypes() throws {
  let toolchain = ToolchainStatus(colima: colima, installedExecutables: [])
  let plan = try RecreatePlan.make(spec: spec(.vz), currentVMType: .qemu, toolchain: toolchain)
    .get()
  #expect(plan.spec.vmType == .vz)
}

@Test func recreatePlanDoesNotRejectShrinkingTheDisk() throws {
  let plan = try RecreatePlan.make(
    spec: spec(.qemu, diskGiB: 10), currentVMType: .vz, toolchain: everythingInstalled
  ).get()
  #expect(plan.spec.resources.diskGiB == 10)
}

@Test func recreatePlanReportsTheSameTypeBeforeMissingExecutables() {
  let toolchain = ToolchainStatus(colima: colima, installedExecutables: [])
  let result = RecreatePlan.make(
    spec: spec(.krunkit), currentVMType: .krunkit, toolchain: toolchain)
  #expect(result == .failure(.sameVMType))
}
