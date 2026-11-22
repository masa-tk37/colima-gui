import ColimaCore
import SwiftUI

/// The VM controller's window confirmation is presented here because `VMOverviewView` and `VMSettingsView` only raise it.
public struct RootView: View {
  private let controller: VMController
  private let settingsModel: VMSettingsModel
  private let usageMonitor: VMUsageMonitor
  private let containerStore: ContainerStore
  private let imageStore: ImageStore
  private let volumeStore: VolumeStore
  private let networkStore: NetworkStore
  private let slots: ContainerOperationSlots
  private let sessions: ContainerSessionFactory

  @State private var selection: SidebarItem = .overview
  @State private var selectedContainer: ContainerID?

  public init(
    controller: VMController,
    settingsModel: VMSettingsModel,
    usageMonitor: VMUsageMonitor,
    containerStore: ContainerStore,
    imageStore: ImageStore,
    volumeStore: VolumeStore,
    networkStore: NetworkStore,
    slots: ContainerOperationSlots,
    sessions: ContainerSessionFactory
  ) {
    self.controller = controller
    self.settingsModel = settingsModel
    self.usageMonitor = usageMonitor
    self.containerStore = containerStore
    self.imageStore = imageStore
    self.volumeStore = volumeStore
    self.networkStore = networkStore
    self.slots = slots
    self.sessions = sessions
  }

  public var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    } detail: {
      VStack(spacing: 0) {
        ConfirmationPresenter(
          origin: .window,
          request: controller.pendingConfirmation,
          confirm: { controller.confirm(id: $0) },
          dismiss: { controller.dismissConfirmation() })
        screen
      }
    }
    .sidebarSelectionForCommands($selection)
  }

  private var sidebar: some View {
    List(selection: sidebarSelection) {
      ForEach(SidebarItem.Group.allCases, id: \.self) { group in
        Section(group.title) {
          ForEach(group.items, id: \.self) { item in
            Label(item.title, systemImage: item.systemImage)
              .tag(item)
          }
        }
      }
    }
    .accessibilityLabel(LocalizedStringResource("Sidebar", bundle: #bundle))
  }

  private var sidebarSelection: Binding<SidebarItem?> {
    Binding(
      get: { selection },
      set: { if let item = $0 { selection = item } })
  }

  @ViewBuilder
  private var screen: some View {
    switch selection {
    case .overview:
      VMOverviewView(controller: controller, usageMonitor: usageMonitor)
    case .settings:
      VMSettingsView(model: settingsModel, controller: controller)
    case .containers:
      containers
    case .images:
      ImageListView(store: imageStore, controller: controller)
    case .volumes:
      VolumeListView(store: volumeStore, controller: controller)
    case .networks:
      NetworkListView(store: networkStore, controller: controller)
    }
  }

  /// The list stays mounted next to the detail because it runs the list monitor. Both sit in the window's
  /// detail column, so the detail's title and toolbar items reach the window toolbar.
  private var containers: some View {
    HStack(spacing: 0) {
      ContainerListView(
        store: containerStore, controller: controller, slots: slots, selection: $selectedContainer
      )
      .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
      Divider()
      containerDetail
        .frame(minWidth: 360, maxWidth: .infinity)
    }
    .navigationTitle(LocalizedStringResource("Containers", bundle: #bundle))
  }

  @ViewBuilder
  private var containerDetail: some View {
    if let selectedContainer {
      ContainerDetailView(
        containerID: selectedContainer,
        store: containerStore,
        networks: networkStore,
        sessions: sessions,
        slots: slots)
    } else {
      ContentUnavailableView(
        LocalizedStringResource("Select a container", bundle: #bundle), systemImage: "shippingbox",
        description: Text("Choose a container from the list to see its details, logs, and stats.", bundle: #bundle))
    }
  }
}
