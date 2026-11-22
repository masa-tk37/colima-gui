import Testing

@testable import ColimaCore

private func input(
  cpus: String = "2",
  memory: String = "4",
  disk: String = "100",
  vmType: VMType = .vz
) -> SettingsFormInput {
  SettingsFormInput(cpus: cpus, memoryGiB: memory, diskGiB: disk, vmType: vmType)
}

private func failure(_ result: Result<VMCreateSpec, SettingsValidationFailure>)
  -> SettingsValidationFailure?
{
  if case .failure(let failure) = result { return failure }
  return nil
}

private func failedFields(_ result: Result<VMCreateSpec, SettingsValidationFailure>)
  -> [SettingsField]
{
  failure(result)?.fields.map(\.field) ?? []
}

@Test func validInputProducesSpecWithParsedValues() throws {
  let spec =
    try VMSettingsValidator
    .validate(input(cpus: "4", memory: "8.5", disk: "200", vmType: .qemu), diskFloorGiB: nil)
    .get()
  #expect(spec.resources == VMResourceSettings(cpus: 4, memoryGiB: 8.5, diskGiB: 200))
  #expect(spec.vmType == .qemu)
}

@Test func surroundingWhitespaceIsIgnored() throws {
  let spec =
    try VMSettingsValidator
    .validate(input(cpus: " 2 ", memory: "\t3\n", disk: " 50"), diskFloorGiB: nil)
    .get()
  #expect(spec.resources == VMResourceSettings(cpus: 2, memoryGiB: 3, diskGiB: 50))
}

@Test(arguments: ["0", "-1", "", "   ", "abc", "2.5", "1e1", "+2", "٣"])
func cpuRejectsNonPositiveIntegers(text: String) {
  let result = VMSettingsValidator.validate(input(cpus: text), diskFloorGiB: nil)
  #expect(failedFields(result) == [.cpu])
}

@Test(arguments: [
  "0", "-1", "", "abc", "0.99", "nan", "inf", "-inf", "1e3", "0x10", "1,5", "1.", ".5",
])
func memoryRejectsInvalidValues(text: String) {
  let result = VMSettingsValidator.validate(input(memory: text), diskFloorGiB: nil)
  #expect(failedFields(result) == [.memory])
}

@Test(arguments: ["1", "1.0", "1.5", "0010", "16.25"])
func memoryAcceptsDecimalsOfAtLeastOne(text: String) throws {
  let spec = try VMSettingsValidator.validate(input(memory: text), diskFloorGiB: nil).get()
  #expect(spec.resources.memoryGiB >= 1)
}

@Test func memoryTooLargeToRepresentIsRejected() {
  let huge = String(repeating: "9", count: 400)
  let result = VMSettingsValidator.validate(input(memory: huge), diskFloorGiB: nil)
  #expect(failedFields(result) == [.memory])
}

@Test(arguments: ["0", "-5", "", "abc", "2.5", "99999999999999999999"])
func diskRejectsNonPositiveIntegers(text: String) {
  let result = VMSettingsValidator.validate(input(disk: text), diskFloorGiB: nil)
  #expect(failedFields(result) == [.disk])
}

@Test func boundaryValueOneIsAccepted() throws {
  let spec =
    try VMSettingsValidator
    .validate(input(cpus: "1", memory: "1", disk: "1"), diskFloorGiB: nil)
    .get()
  #expect(spec.resources == VMResourceSettings(cpus: 1, memoryGiB: 1, diskGiB: 1))
}

@Test func everyInvalidFieldIsReportedInFormOrder() {
  let result = VMSettingsValidator.validate(
    input(cpus: "0", memory: "abc", disk: ""), diskFloorGiB: nil)
  #expect(failedFields(result) == [.cpu, .memory, .disk])
}

@Test func eachFieldErrorCarriesAMessage() {
  let result = VMSettingsValidator.validate(
    input(cpus: "0", memory: "abc", disk: ""), diskFloorGiB: nil)
  #expect(failure(result)?.fields.allSatisfy { !$0.message.isEmpty } == true)
}

@Test func shrinkingBelowTheFloorIsRejectedOnTheDiskField() {
  let result = VMSettingsValidator.validate(input(disk: "50"), diskFloorGiB: 100)
  #expect(failedFields(result) == [.disk])
}

@Test func diskEqualToOrAboveTheFloorIsAccepted() {
  #expect(failure(VMSettingsValidator.validate(input(disk: "100"), diskFloorGiB: 100)) == nil)
  #expect(failure(VMSettingsValidator.validate(input(disk: "101"), diskFloorGiB: 100)) == nil)
}

@Test func withoutAFloorShrinkingIsAccepted() throws {
  let spec = try VMSettingsValidator.validate(input(disk: "10"), diskFloorGiB: nil).get()
  #expect(spec.resources.diskGiB == 10)
}

@Test func malformedDiskReportsFormatErrorOnceEvenWithAFloor() {
  let result = VMSettingsValidator.validate(input(disk: "abc"), diskFloorGiB: 100)
  #expect(failure(result)?.fields.count == 1)
  #expect(failedFields(result) == [.disk])
}

@Test func shrinkAndOtherFieldErrorsAreReportedTogether() {
  let result = VMSettingsValidator.validate(input(cpus: "0", disk: "10"), diskFloorGiB: 100)
  #expect(failedFields(result) == [.cpu, .disk])
}

@Test func vmTypeIsCarriedThroughForEveryCase() throws {
  for vmType in VMType.allCases {
    let spec = try VMSettingsValidator.validate(input(vmType: vmType), diskFloorGiB: nil).get()
    #expect(spec.vmType == vmType)
  }
}
