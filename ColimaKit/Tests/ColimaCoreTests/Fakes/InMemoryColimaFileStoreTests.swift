import Testing

@testable import ColimaCore

private let settings = VMResourceSettings(cpus: 4, memoryGiB: 8, diskGiB: 100)

@Test func fileStoreDefaultsToNoFiles() throws {
  let store = InMemoryColimaFileStore()
  #expect(try store.readProfileSettings() == nil)
  #expect(try store.readInstanceVMType() == nil)
}

@Test func fileStoreRecordsCallsInOrder() throws {
  let store = InMemoryColimaFileStore()
  _ = try store.readInstanceVMType()
  try store.writeProfileSettings(settings)
  _ = try store.readProfileSettings()

  #expect(
    store.calls == [.readInstanceVMType, .writeProfileSettings(settings), .readProfileSettings])
  #expect(store.writtenSettings == [settings])
}

@Test func fileStoreReturnsConfiguredFailures() {
  let store = InMemoryColimaFileStore()
  let readError = ColimaFileError.unreadable(path: "/c.yaml", reason: "denied")
  let formatError = ColimaFileError.unexpectedFormat(key: "cpu", reason: "duplicated")
  let writeError = ColimaFileError.writeFailed(path: "/c.yaml", reason: "read-only")
  store.configure {
    $0.profile = .failure(readError)
    $0.instanceVMType = .failure(formatError)
    $0.writeFailure = writeError
  }

  #expect(throws: readError) { try store.readProfileSettings() }
  #expect(throws: formatError) { try store.readInstanceVMType() }
  #expect(throws: writeError) { try store.writeProfileSettings(settings) }
  #expect(store.calls.count == 3)
}

@Test func fileStoreFailedWriteIsRecordedButLeavesTheStoredProfileAlone() throws {
  let original = ProfileSettings(
    resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 60), vmType: .vz)
  let store = InMemoryColimaFileStore()
  store.configure {
    $0.profile = .success(original)
    $0.writeFailure = .writeFailed(path: "/c.yaml", reason: "full")
  }

  _ = try? store.writeProfileSettings(settings)

  #expect(try store.readProfileSettings() == original)
  #expect(store.writtenSettings == [settings])
}

@Test func fileStoreSuccessfulWriteIsVisibleToTheNextReadAndKeepsVMType() throws {
  let store = InMemoryColimaFileStore()
  store.configure {
    $0.profile = .success(
      ProfileSettings(
        resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 60), vmType: .vz))
  }

  try store.writeProfileSettings(settings)

  #expect(try store.readProfileSettings() == ProfileSettings(resources: settings, vmType: .vz))
}
