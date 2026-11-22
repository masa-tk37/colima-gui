import Foundation
import Observation
import Synchronization
import Testing

@testable import ColimaCore

/// The lists are forwarded from a nested `@Observable`, so a broken forward would leave views stale
/// without failing any test that reads values directly.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StoreObservationTests {
  private let cli = FakeColimaCLI()
  private let engine = FakeDockerEngine()
  private let controller: VMController

  init() async {
    controller = VMController(cli: cli, files: InMemoryColimaFileStore())
    cli.configure {
      $0.listDefault = [
        .success(
          .present(
            VMInstance(
              runState: .running, arch: "aarch64", cpus: 2, memoryBytes: 2 << 30,
              diskBytes: 100 << 30,
              runtime: "docker"
            )))
      ]
    }
    await controller.redetectToolchain()
  }

  private func firesOnChange(reading read: @MainActor () -> Void, after change: () async -> Void)
    async -> Bool
  {
    let fired = Mutex(false)
    withObservationTracking(read) { fired.withLock { $0 = true } }
    await change()
    return fired.withLock { $0 }
  }

  @Test func refreshingTheVolumeListNotifiesObserversOfVolumes() async {
    let store = VolumeStore(engine: engine, controller: controller)
    let fired = await firesOnChange(
      reading: { _ = store.volumes }, after: { await store.refresh() })
    #expect(fired)
  }

  @Test func refreshingTheImageListNotifiesObserversOfImages() async {
    let store = ImageStore(engine: engine, controller: controller)
    let fired = await firesOnChange(reading: { _ = store.images }, after: { await store.refresh() })
    #expect(fired)
  }

  @Test func refreshingTheContainerListNotifiesObserversOfContainers() async {
    let store = ContainerStore(
      engine: engine, controller: controller, slots: ContainerOperationSlots())
    let fired = await firesOnChange(
      reading: { _ = store.containers }, after: { await store.refresh() })
    #expect(fired)
  }

  @Test func refreshingTheNetworkListNotifiesObserversOfNetworks() async {
    let store = NetworkStore(
      engine: engine, controller: controller, slots: ContainerOperationSlots())
    let fired = await firesOnChange(
      reading: { _ = store.networks }, after: { await store.refresh() })
    #expect(fired)
  }

  @Test func selectingANetworkNotifiesObserversOfTheDetail() async {
    let store = NetworkStore(
      engine: engine, controller: controller, slots: ContainerOperationSlots())
    let fired = await firesOnChange(
      reading: { _ = store.detail },
      after: {
        store.select(NetworkID(rawValue: "n"))
        await store.awaitOperations()
      }
    )
    #expect(fired)
  }
}
