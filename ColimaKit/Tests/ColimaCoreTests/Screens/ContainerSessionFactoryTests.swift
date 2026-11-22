import Foundation
import Observation
import Testing

@testable import ColimaCore

private let web = ContainerID(rawValue: "web")
private let db = ContainerID(rawValue: "db")

private func detail(_ id: ContainerID) -> ContainerDetail {
  ContainerDetail(id: id, hasTTY: true, isRunning: true, networkNames: [])
}

private func sample(memoryMiB: UInt64) -> ContainerStatsSample {
  ContainerStatsSample(
    cpuTotalUsage: 100, previousCPUTotalUsage: 0,
    systemCPUUsage: 1000, previousSystemCPUUsage: 0,
    onlineCPUs: 2, memoryUsage: memoryMiB << 20, memoryInactiveFile: nil
  )
}

@MainActor
private func waitFor(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
  for await holds in Observations({ condition() }) where holds { return }
}

@MainActor
private func makeEngine() -> FakeDockerEngine {
  let engine = FakeDockerEngine()
  engine.configure {
    $0.containerDetails[web] = .success(detail(web))
    $0.containerDetails[db] = .success(detail(db))
    $0.containerStats[web] = .success(sample(memoryMiB: 100))
    $0.containerStats[db] = .success(sample(memoryMiB: 200))
    $0.logChunks[web] = [Array("from web\n".utf8)]
    $0.logChunks[db] = [Array("from db\n".utf8)]
    $0.logStreamStaysOpen = true
  }
  return engine
}

@MainActor
struct ContainerSessionFactoryTests {
  @Test func everyCallReturnsANewSession() {
    let factory = ContainerSessionFactory(engine: makeEngine())

    #expect(factory.makeLogSession(for: web) !== factory.makeLogSession(for: web))
    #expect(factory.makeStatsSession(for: web) !== factory.makeStatsSession(for: web))
  }

  @Test func logSessionsReadTheirOwnContainer() async {
    let factory = ContainerSessionFactory(engine: makeEngine())
    let webLog = factory.makeLogSession(for: web)
    let dbLog = factory.makeLogSession(for: db)

    let webTask = Task { await webLog.run() }
    let dbTask = Task { await dbLog.run() }
    await waitFor { webLog.lines.count == 1 && dbLog.lines.count == 1 }
    webTask.cancel()
    dbTask.cancel()

    #expect(webLog.lines.map(\.text) == ["from web"])
    #expect(dbLog.lines.map(\.text) == ["from db"])
  }

  @Test func cancellingOneLogSessionLeavesTheOtherFollowing() async {
    let engine = makeEngine()
    let factory = ContainerSessionFactory(engine: engine)
    let webLog = factory.makeLogSession(for: web)
    let dbLog = factory.makeLogSession(for: db)

    let webTask = Task { await webLog.run() }
    let dbTask = Task { await dbLog.run() }
    await waitFor { webLog.lines.count == 1 && dbLog.lines.count == 1 }

    webTask.cancel()
    await webTask.value
    // The stream that stays open ends only through cancellation, so a still-following state proves the
    // other session's call was not cancelled.
    #expect(dbLog.state == .following)

    dbTask.cancel()
    await dbTask.value
  }

  @Test func statsSessionsReadTheirOwnContainer() async {
    let factory = ContainerSessionFactory(engine: makeEngine())
    let webStats = factory.makeStatsSession(for: web)
    let dbStats = factory.makeStatsSession(for: db)

    let webTask = Task { await webStats.run() }
    let dbTask = Task { await dbStats.run() }
    await waitFor { !webStats.memory.points.isEmpty && !dbStats.memory.points.isEmpty }
    webTask.cancel()
    dbTask.cancel()

    #expect(webStats.memory.points.last?.value == Double(100 << 20))
    #expect(dbStats.memory.points.last?.value == Double(200 << 20))
  }

  @Test func cancellingOneStatsSessionLeavesTheOtherRunning() async {
    let factory = ContainerSessionFactory(engine: makeEngine())
    let webStats = factory.makeStatsSession(for: web)
    let dbStats = factory.makeStatsSession(for: db)

    let webTask = Task { await webStats.run() }
    let dbTask = Task { await dbStats.run() }
    await waitFor { !webStats.memory.points.isEmpty && !dbStats.memory.points.isEmpty }

    webTask.cancel()
    await webTask.value
    #expect(dbStats.state == .running)

    dbTask.cancel()
    await dbTask.value
  }
}
