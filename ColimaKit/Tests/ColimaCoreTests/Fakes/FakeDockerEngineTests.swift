import Foundation
import Testing

@testable import ColimaCore

private let web = ContainerID(rawValue: "web")
private let db = ContainerID(rawValue: "db")
private let netA = NetworkID(rawValue: "net-a")

private func summary(_ id: ContainerID) -> ContainerSummary {
  ContainerSummary(
    id: id, name: id.rawValue, image: "img", state: .running, ports: [], labels: [:],
    networkNames: [])
}

private func cancelledResult<T: Sendable>(
  _ body: @escaping @Sendable () async throws -> T
) async -> DockerError? {
  await Task { () -> DockerError? in
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      _ = try await body()
      return DockerError?.none
    } catch {
      return error as? DockerError
    }
  }.value
}

@Test func engineUnconfiguredListsAreEmptyAndSucceed() async throws {
  let engine = FakeDockerEngine()
  #expect(try await engine.listContainers().isEmpty)
  #expect(try await engine.listImages().isEmpty)
  #expect(try await engine.listVolumes(danglingOnly: false).isEmpty)
  #expect(try await engine.volumeSizes().isEmpty)
  #expect(try await engine.listNetworks(danglingOnly: true).isEmpty)
}

@Test func engineRecordsEveryMethodInCallOrder() async throws {
  let engine = FakeDockerEngine()
  let created = try NetworkCreateForm(name: "app", subnet: "").validate(existingNames: []).get()
  let deletable = try #require(
    NetworkSummary(id: netA, name: "app", driver: "bridge", scope: "local", ipam: []).deletableID
  )
  let tag = ImageReference.tag(repository: "nginx", tag: "latest")

  _ = try await engine.listContainers()
  _ = try? await engine.inspectContainer(id: web)
  try await engine.perform(.restart, on: web)
  try await engine.removeContainer(id: web)
  _ = try? await engine.containerStats(id: web)
  try await engine.consumeLogs(id: web, tail: 100, follow: true) { _ in }
  _ = try await engine.listImages()
  try await engine.removeImage(tag)
  _ = try await engine.listVolumes(danglingOnly: true)
  _ = try await engine.volumeSizes()
  try await engine.removeVolume(name: "data")
  _ = try await engine.listNetworks(danglingOnly: false)
  _ = try? await engine.inspectNetwork(id: netA)
  _ = try await engine.createNetwork(created)
  try await engine.removeNetwork(deletable)
  try await engine.connect(container: web, to: netA)
  try await engine.disconnect(container: web, from: netA)

  #expect(
    engine.calls == [
      .listContainers,
      .inspectContainer(web),
      .perform(.restart, web),
      .removeContainer(web),
      .containerStats(web),
      .consumeLogs(id: web, tail: 100, follow: true),
      .listImages,
      .removeImage(tag),
      .listVolumes(danglingOnly: true),
      .volumeSizes,
      .removeVolume("data"),
      .listNetworks(danglingOnly: false),
      .inspectNetwork(netA),
      .createNetwork(created),
      .removeNetwork(deletable),
      .connect(container: web, network: netA),
      .disconnect(container: web, network: netA),
    ])
}

@Test func engineReturnsConfiguredListsAndWholeListFailures() async throws {
  let engine = FakeDockerEngine()
  engine.configure {
    $0.containers = .success([summary(web), summary(db)])
    $0.images = .failure(.engineUnreachable(detail: "no socket"))
    $0.volumes = .success([VolumeSummary(name: "all", driver: "local", createdAt: nil, labels: nil)]
    )
    $0.danglingVolumes = .success([])
    $0.networks = .failure(.timedOut)
  }

  #expect(try await engine.listContainers().map(\.id) == [web, db])
  await #expect(throws: DockerError.engineUnreachable(detail: "no socket")) {
    try await engine.listImages()
  }
  #expect(try await engine.listVolumes(danglingOnly: false).map(\.name) == ["all"])
  #expect(try await engine.listVolumes(danglingOnly: true).isEmpty)
  await #expect(throws: DockerError.timedOut) { try await engine.listNetworks(danglingOnly: false) }
}

@Test func engineFailsPerItemWithTheConfiguredErrorText() async throws {
  let engine = FakeDockerEngine()
  let busy = DockerError.api(status: 409, message: "container is running")
  let tag = ImageReference.tag(repository: "nginx", tag: "latest")
  engine.configure {
    $0.containerRemovalFailures[web] = busy
    $0.containerActionFailures[db] = .api(status: 500, message: "boom")
    $0.imageRemovalFailures[tag] = .api(status: 409, message: "image is in use")
    $0.volumeRemovalFailures["data"] = .api(status: 409, message: "volume in use")
  }

  await #expect(throws: busy) { try await engine.removeContainer(id: web) }
  try await engine.removeContainer(id: db)
  await #expect(throws: DockerError.api(status: 500, message: "boom")) {
    try await engine.perform(.stop, on: db)
  }
  try await engine.perform(.stop, on: web)
  await #expect(throws: DockerError.api(status: 409, message: "image is in use")) {
    try await engine.removeImage(tag)
  }
  try await engine.removeImage(.imageID("sha256:x"))
  await #expect(throws: DockerError.api(status: 409, message: "volume in use")) {
    try await engine.removeVolume(name: "data")
  }
  try await engine.removeVolume(name: "other")
}

@Test func engineNetworkItemsFailPerNetworkAndPerMembership() async throws {
  let engine = FakeDockerEngine()
  let other = NetworkID(rawValue: "net-b")
  let deletableA = try #require(
    NetworkSummary(id: netA, name: "a", driver: "bridge", scope: "local", ipam: []).deletableID)
  let deletableB = try #require(
    NetworkSummary(id: other, name: "b", driver: "bridge", scope: "local", ipam: []).deletableID)
  engine.configure {
    $0.networkRemovalFailures[netA] = .api(status: 403, message: "has active endpoints")
    $0.connectFailures[.init(container: web, network: netA)] = .api(
      status: 404, message: "no such container")
    $0.disconnectFailures[.init(container: web, network: other)] = .timedOut
    $0.createdNetworkID = .failure(.api(status: 409, message: "name in use"))
  }
  let created = try NetworkCreateForm(name: "app", subnet: "").validate(existingNames: []).get()

  await #expect(throws: DockerError.api(status: 403, message: "has active endpoints")) {
    try await engine.removeNetwork(deletableA)
  }
  try await engine.removeNetwork(deletableB)
  await #expect(throws: DockerError.api(status: 404, message: "no such container")) {
    try await engine.connect(container: web, to: netA)
  }
  try await engine.connect(container: db, to: netA)
  await #expect(throws: DockerError.timedOut) {
    try await engine.disconnect(container: web, from: other)
  }
  await #expect(throws: DockerError.api(status: 409, message: "name in use")) {
    try await engine.createNetwork(created)
  }
}

@Test func engineInspectOfAnUnconfiguredItemIsNotFound() async throws {
  let engine = FakeDockerEngine()
  engine.configure {
    $0.containerDetails[web] = .success(
      ContainerDetail(id: web, hasTTY: true, isRunning: true, networkNames: ["bridge"]))
  }

  #expect(try await engine.inspectContainer(id: web).hasTTY)
  await #expect(throws: DockerError.api(status: 404, message: "No such container: db")) {
    try await engine.inspectContainer(id: db)
  }
  await #expect(throws: DockerError.api(status: 404, message: "No such network: net-a")) {
    try await engine.inspectNetwork(id: netA)
  }
  await #expect(throws: DockerError.api(status: 404, message: "No such container: db")) {
    try await engine.containerStats(id: db)
  }
}

@Test func engineLogsDeliverConfiguredChunksThenEndOrFail() async throws {
  let engine = FakeDockerEngine()
  engine.configure {
    $0.logChunks[web] = [[0x61], [0x62, 0x0A]]
    $0.logChunks[db] = [[0x63]]
    $0.logFailures[db] = .connectionLost(detail: "reset")
  }

  let received = ChunkBox()
  try await engine.consumeLogs(id: web, tail: 10, follow: false) { await received.append($0) }
  #expect(await received.chunks == [[0x61], [0x62, 0x0A]])

  let partial = ChunkBox()
  await #expect(throws: DockerError.connectionLost(detail: "reset")) {
    try await engine.consumeLogs(id: db, tail: 10, follow: true) { await partial.append($0) }
  }
  #expect(await partial.chunks == [[0x63]])
}

@Test func engineFollowedLogsStayOpenUntilTheTaskIsCancelled() async {
  let engine = FakeDockerEngine()
  engine.configure { $0.logStreamStaysOpen = true }

  let task = Task { () -> DockerError? in
    do {
      try await engine.consumeLogs(id: web, tail: 0, follow: true) { _ in }
      return nil
    } catch {
      return error as? DockerError
    }
  }
  while engine.calls.isEmpty { await Task.yield() }
  task.cancel()

  #expect(await task.value == .cancelled)
}

@Test func engineCancelledTaskGetsCancelledEvenWhenAnotherResultIsConfigured() async throws {
  let engine = FakeDockerEngine()
  engine.configure {
    $0.containerRemovalFailures[web] = .timedOut
    $0.containers = .failure(.timedOut)
  }
  let deletable = try #require(
    NetworkSummary(id: netA, name: "a", driver: "bridge", scope: "local", ipam: []).deletableID)

  #expect(await cancelledResult { try await engine.listContainers() } == .cancelled)
  #expect(await cancelledResult { try await engine.removeContainer(id: web) } == .cancelled)
  #expect(await cancelledResult { try await engine.removeNetwork(deletable) } == .cancelled)
  #expect(await cancelledResult { try await engine.listVolumes(danglingOnly: false) } == .cancelled)
  #expect(
    await cancelledResult { try await engine.consumeLogs(id: web, tail: 1, follow: false) { _ in } }
      == .cancelled)
}

@Test func engineBeforeReturnHookCanHoldACallInFlight() async throws {
  let engine = FakeDockerEngine()
  let gate = Gate()
  engine.configure { $0.beforeReturn = { _ in await gate.wait() } }

  let task = Task { () -> DockerError? in
    do {
      try await engine.perform(.start, on: web)
      return nil
    } catch {
      return error as? DockerError
    }
  }
  while engine.calls.isEmpty { await Task.yield() }
  engine.configure { $0.containerActionFailures[web] = .timedOut }
  await gate.open()

  #expect(await task.value == .timedOut)
}

private actor ChunkBox {
  private(set) var chunks: [[UInt8]] = []
  func append(_ chunk: [UInt8]) { chunks.append(chunk) }
}

private actor Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

@Test func engineLogsReportEachDeliveredChunkIndexToTheAfterChunkHook() async throws {
  let engine = FakeDockerEngine()
  let indexes = ChunkBox()
  engine.configure {
    $0.logChunks[web] = [[0x61], [0x62], [0x63]]
    $0.afterLogChunk = { await indexes.append([UInt8($0)]) }
  }

  let received = ChunkBox()
  try await engine.consumeLogs(id: web, tail: 10, follow: false) { await received.append($0) }

  #expect(await indexes.chunks == [[0], [1], [2]])
  #expect(await received.chunks == [[0x61], [0x62], [0x63]])
}
