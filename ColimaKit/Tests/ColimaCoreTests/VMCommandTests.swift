import Testing

@testable import ColimaCore

private func spec(
  cpus: Int = 2,
  memoryGiB: Double = 4,
  diskGiB: Int = 100,
  vmType: VMType = .vz
) -> VMCreateSpec {
  VMCreateSpec(
    resources: VMResourceSettings(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB),
    vmType: vmType
  )
}

@Test func startAndStopArgumentsAreFixed() {
  #expect(VMCommand.start.arguments == ["start"])
  #expect(VMCommand.stop.arguments == ["stop"])
}

@Test func deleteForcesAndRemovesData() {
  #expect(VMCommand.delete.arguments == ["delete", "--force", "--data"])
}

@Test func createArgumentsAreFixedForVz() {
  #expect(
    VMCommand.create(spec(cpus: 4, memoryGiB: 8, diskGiB: 120, vmType: .vz)).arguments == [
      "start", "--vm-type", "vz", "--cpus", "4", "--memory", "8", "--disk", "120",
      "--template=false",
    ])
}

@Test func createArgumentsAreFixedForQemu() {
  #expect(
    VMCommand.create(spec(vmType: .qemu)).arguments == [
      "start", "--vm-type", "qemu", "--cpus", "2", "--memory", "4", "--disk", "100",
      "--template=false",
    ])
}

@Test func createAddsSshfsMountTypeOnlyForKrunkit() {
  #expect(
    VMCommand.create(spec(vmType: .krunkit)).arguments == [
      "start", "--vm-type", "krunkit", "--cpus", "2", "--memory", "4", "--disk", "100",
      "--template=false",
      "--mount-type", "sshfs",
    ])
  for type in VMType.allCases where type != .krunkit {
    #expect(!VMCommand.create(spec(vmType: type)).arguments.contains("--mount-type"))
  }
}

@Test func createAlwaysDisablesTemplate() {
  for type in VMType.allCases {
    #expect(VMCommand.create(spec(vmType: type)).arguments.contains("--template=false"))
  }
}

@Test func memoryIsFormattedWithoutLocaleOrTrailingZero() {
  func memory(_ gib: Double) -> String {
    let arguments = VMCommand.create(spec(memoryGiB: gib)).arguments
    return arguments[arguments.firstIndex(of: "--memory")! + 1]
  }
  #expect(memory(4) == "4")
  #expect(memory(8.5) == "8.5")
  #expect(memory(0.5) == "0.5")
  #expect(memory(16) == "16")
}
