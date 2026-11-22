import Testing

@testable import ColimaCore

private let colimaFound = ToolchainStatus.ColimaLookup.found(path: "/opt/homebrew/bin/colima")

@Test func nothingMissingWhenEveryDependencyIsInstalled() {
  let status = ToolchainStatus(
    colima: colimaFound,
    installedExecutables: ["qemu-img", "qemu-system-aarch64", "krunkit"]
  )
  for type in VMType.allCases {
    #expect(status.missingExecutables(for: type).isEmpty)
  }
}

@Test func vzNeverReportsMissingExecutables() {
  let status = ToolchainStatus(colima: colimaFound, installedExecutables: [])
  #expect(status.missingExecutables(for: .vz).isEmpty)
}

@Test func missingIsComputedPerVMTypeInDeclaredOrder() {
  let status = ToolchainStatus(colima: colimaFound, installedExecutables: ["qemu-img"])
  #expect(status.missingExecutables(for: .qemu) == ["qemu-system-aarch64"])
  #expect(status.missingExecutables(for: .krunkit) == ["krunkit"])
  #expect(status.missingExecutables(for: .vz) == [])
}

@Test func bothQemuExecutablesReportedWhenNoneInstalled() {
  let status = ToolchainStatus(colima: colimaFound, installedExecutables: [])
  #expect(status.missingExecutables(for: .qemu) == ["qemu-img", "qemu-system-aarch64"])
}

@Test func missingColimaKeepsSearchedLocations() {
  let status = ToolchainStatus(
    colima: .missing(searched: ["/opt/homebrew/bin/colima"]),
    installedExecutables: []
  )
  #expect(status.colima == .missing(searched: ["/opt/homebrew/bin/colima"]))
}

@Test func explicitMissingByVMTypeIsReturnedAndDefaultsToEmpty() {
  let status = ToolchainStatus(colima: colimaFound, missingByVMType: [.krunkit: ["krunkit"]])
  #expect(status.missingExecutables(for: .krunkit) == ["krunkit"])
  #expect(status.missingExecutables(for: .qemu).isEmpty)
}
