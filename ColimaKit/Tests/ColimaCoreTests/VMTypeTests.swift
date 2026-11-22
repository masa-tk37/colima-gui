import Testing

@testable import ColimaCore

@Test func vzRequiresNoExtraExecutables() {
  #expect(VMType.vz.requiredExecutables.isEmpty)
}

@Test func qemuRequiresImageToolAndSystemBinary() {
  #expect(VMType.qemu.requiredExecutables == ["qemu-img", "qemu-system-aarch64"])
}

@Test func krunkitRequiresItsOwnBinary() {
  #expect(VMType.krunkit.requiredExecutables == ["krunkit"])
}

@Test func vmTypeRawValuesMatchColimaFlagValues() {
  #expect(VMType.allCases.map(\.rawValue) == ["qemu", "vz", "krunkit"])
  #expect(VMType(rawValue: "vz") == .vz)
  #expect(VMType(rawValue: "docker") == nil)
}
