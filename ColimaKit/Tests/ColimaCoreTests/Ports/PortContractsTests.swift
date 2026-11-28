import Foundation
import Testing

@testable import ColimaCore

private final class RecordingEngine: DockerEngine {
  private let removedNetworks = Locked<[NetworkID]>([])
  private let createdNetworks = Locked<[ValidatedNetworkCreate]>([])

  var removed: [NetworkID] { removedNetworks.value }
  var created: [ValidatedNetworkCreate] { createdNetworks.value }

  func listContainers() async throws(DockerError) -> [ContainerSummary] { [] }
  func inspectContainer(id: ContainerID) async throws(DockerError) -> ContainerDetail {
    throw .cancelled
  }
  func perform(_ action: ContainerAction, on id: ContainerID) async throws(DockerError) {}
  func removeContainer(id: ContainerID) async throws(DockerError) {}
  func containerStats(id: ContainerID) async throws(DockerError) -> ContainerStatsSample {
    throw .timedOut
  }
  func consumeLogs(
    id: ContainerID,
    tail: Int,
    follow: Bool,
    onChunk: @Sendable ([UInt8]) async -> Void
  ) async throws(DockerError) {
    await onChunk([0x61])
  }
  func listImages() async throws(DockerError) -> [ImageSummary] { [] }
  func removeImage(_ reference: ImageReference) async throws(DockerError) {}
  func listVolumes(danglingOnly: Bool) async throws(DockerError) -> [VolumeSummary] { [] }
  func volumeSizes() async throws(DockerError) -> [String: VolumeSize] { [:] }
  func removeVolume(name: String) async throws(DockerError) {}
  func listNetworks(danglingOnly: Bool) async throws(DockerError) -> [NetworkSummary] { [] }
  func inspectNetwork(id: NetworkID) async throws(DockerError) -> NetworkDetail {
    throw .api(status: 404, message: "no such network")
  }
  func createNetwork(_ request: ValidatedNetworkCreate) async throws(DockerError) -> NetworkID {
    createdNetworks.mutate { $0.append(request) }
    return NetworkID(rawValue: "new")
  }
  func removeNetwork(_ id: DeletableNetworkID) async throws(DockerError) {
    removedNetworks.mutate { $0.append(id.id) }
  }
  func connect(container: ContainerID, to network: NetworkID) async throws(DockerError) {}
  func disconnect(container: ContainerID, from network: NetworkID) async throws(DockerError) {}
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value { lock.withLock { stored } }

  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private struct StubCLI: ColimaCLI {
  func preflight() async -> ToolchainStatus {
    ToolchainStatus(colima: .missing(searched: ["/opt/homebrew/bin"]), installedExecutables: [])
  }
  func listDefault() async throws(ColimaCLIError) -> VMObservation { throw .cancelled }
  func run(_ command: VMCommand) async -> VMCommandRun {
    let (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
    continuation.yield(.output("line"))
    continuation.yield(.exited(code: 0))
    continuation.finish()
    return VMCommandRun(events: events, terminate: { false })
  }
  func sampleUsage() async throws(ColimaCLIError) -> ProcSnapshot { throw .timedOut }
}

private struct StubFileStore: ColimaFileStore {
  func readProfileSettings() throws(ColimaFileError) -> ProfileSettings? { nil }
  func writeProfileSettings(_ settings: VMResourceSettings) throws(ColimaFileError) {
    throw .writeFailed(path: "/x", reason: "denied")
  }
  func readInstanceVMType() throws(ColimaFileError) -> VMType? { .vz }
}

@Test func networkRemovalAcceptsOnlyTheDedicatedType() async throws {
  let engine = RecordingEngine()
  let custom = NetworkSummary(
    id: NetworkID(rawValue: "abc"), name: "app", driver: "bridge", scope: "local", ipam: [])
  let builtIn = NetworkSummary(
    id: NetworkID(rawValue: "def"), name: "bridge", driver: "bridge", scope: "local", ipam: [])

  let deletable = try #require(custom.deletableID)
  try await engine.removeNetwork(deletable)

  #expect(builtIn.deletableID == nil)
  #expect(engine.removed == [NetworkID(rawValue: "abc")])
}

@Test func networkCreationAcceptsOnlyAValidatedRequest() async throws {
  let engine = RecordingEngine()
  let validated = try NetworkCreateForm(name: "app", subnet: "").validate(existingNames: []).get()

  let id = try await engine.createNetwork(validated)

  #expect(id == NetworkID(rawValue: "new"))
  #expect(engine.created == [validated])
}

@Test func commandRunEventsEndWithExit() async {
  let run = await StubCLI().run(.start)
  var events: [ProcessEvent] = []
  for await event in run.events { events.append(event) }
  _ = await run.terminate()
  #expect(events == [.output("line"), .exited(code: 0)])
}

@Test func typedErrorsDistinguishCancellation() async {
  do {
    _ = try await StubCLI().listDefault()
    Issue.record("expected a throw")
  } catch {
    #expect(error == .cancelled)
    #expect(error != .timedOut)
  }
  do {
    _ = try await RecordingEngine().inspectContainer(id: ContainerID(rawValue: "c"))
    Issue.record("expected a throw")
  } catch {
    #expect(error == .cancelled)
    #expect(error != .timedOut)
  }
}

@Test func fileStoreErrorsCarryTheirContext() {
  let store = StubFileStore()
  #expect(throws: ColimaFileError.writeFailed(path: "/x", reason: "denied")) {
    try store.writeProfileSettings(VMResourceSettings(cpus: 2, memoryGiB: 4, diskGiB: 100))
  }
  #expect((try? store.readInstanceVMType()) == .vz)
  #expect((try? store.readProfileSettings()) == .some(nil))
}

@Test func logLoggersExistForEveryCategory() {
  ColimaLog.vm.debug("vm")
  ColimaLog.docker.debug("docker")
  ColimaLog.process.debug("process")
  ColimaLog.machine.debug("machine")
  #expect(ColimaLog.subsystem == "cc.tk37.ColimaGUI")
}
