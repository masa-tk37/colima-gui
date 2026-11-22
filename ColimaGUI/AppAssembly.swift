import AppKit
import ColimaAdapters
import ColimaCore
import Foundation

/// The only place that creates adapters and screen models. Scenes and views receive these instances and never
/// create their own, so each pending confirmation and each cached list has exactly one owner.
final class AppAssembly {
  let vmController: VMController
  let settingsModel: VMSettingsModel
  let usageMonitor: VMUsageMonitor
  let containerStore: ContainerStore
  let imageStore: ImageStore
  let volumeStore: VolumeStore
  let networkStore: NetworkStore
  let slots: ContainerOperationSlots
  let sessions: ContainerSessionFactory

  private let engine: DockerEngineClient
  private let agent: AgentClient
  private var monitorTask: Task<Void, Never>?
  private var activationObservers: [any NSObjectProtocol] = []

  private static let shutdownWait: DispatchTimeInterval = .seconds(2)

  init() {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let agent = AgentClient.live()
    let cli = ColimaCommandLine(agent: agent)
    let files = ColimaProfileFiles(baseDirectory: home)
    let engine = DockerEngineClient(
      socketPath: home.appendingPathComponent(".colima/default/docker.sock").path
    )
    let slots = ContainerOperationSlots()

    let vmController = VMController(cli: cli, files: files)
    let containerStore = ContainerStore(engine: engine, controller: vmController, slots: slots)

    self.engine = engine
    self.agent = agent
    self.slots = slots
    self.vmController = vmController
    settingsModel = VMSettingsModel(controller: vmController, files: files)
    usageMonitor = VMUsageMonitor(controller: vmController, cli: cli)
    self.containerStore = containerStore
    imageStore = ImageStore(engine: engine, controller: vmController)
    volumeStore = VolumeStore(engine: engine, controller: vmController)
    networkStore = NetworkStore(
      engine: engine,
      controller: vmController,
      slots: slots,
      containerListDidChange: { await containerStore.refresh() }
    )
    sessions = ContainerSessionFactory(engine: engine)
  }

  func start() {
    guard monitorTask == nil else { return }

    let controller = vmController
    monitorTask = Task { await controller.monitor() }
    let agent = agent
    Task { await BackgroundServices.register(agent: agent) }

    controller.setCadence(NSApplication.shared.isActive ? .foreground : .background)
    let center = NotificationCenter.default
    activationObservers = [
      (NSApplication.didBecomeActiveNotification, PollingCadence.foreground),
      (NSApplication.didResignActiveNotification, PollingCadence.background),
    ].map { name, cadence in
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { controller.setCadence(cadence) }
      }
    }
  }

  /// `applicationWillTerminate` is synchronous, so the close runs off the main thread and is awaited for at most
  /// `shutdownWait`; the process is exiting either way.
  func shutdown() {
    monitorTask?.cancel()
    monitorTask = nil
    for observer in activationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    activationObservers = []

    let engine = engine
    let closed = DispatchSemaphore(value: 0)
    Task.detached {
      await engine.shutdown()
      closed.signal()
    }
    _ = closed.wait(timeout: .now() + Self.shutdownWait)
  }
}
