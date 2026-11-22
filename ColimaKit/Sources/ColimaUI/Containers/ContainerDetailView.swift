import ColimaCore
import SwiftUI

enum ContainerDetailSection: CaseIterable, Identifiable {
  case overview
  case logs
  case stats

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .overview: LocalizedStringResource("Overview", bundle: #bundle)
    case .logs: LocalizedStringResource("Logs", bundle: #bundle)
    case .stats: LocalizedStringResource("Stats", bundle: #bundle)
    }
  }
}

/// A log or statistics case carries its session, so leaving the case drops the session and the screen's `.task` that was running it.
private enum Presentation {
  case overview
  case logs(LogSession)
  case stats(StatsSession)

  var section: ContainerDetailSection {
    switch self {
    case .overview: .overview
    case .logs: .logs
    case .stats: .stats
    }
  }
}

/// The summary is read from `store.containers`, which only the list screen's `store.monitor()` keeps fresh, so the
/// owner must keep that screen alive.
public struct ContainerDetailView: View {
  private let containerID: ContainerID
  private let store: ContainerStore
  private let networks: NetworkStore
  private let sessions: ContainerSessionFactory
  private let slots: ContainerOperationSlots
  private let initialSection: ContainerDetailSection

  /// - Parameters:
  ///   - slots: the instance the stores were created with; it tells whether an operation holds the container.
  public init(
    containerID: ContainerID,
    store: ContainerStore,
    networks: NetworkStore,
    sessions: ContainerSessionFactory,
    slots: ContainerOperationSlots
  ) {
    self.init(
      containerID: containerID, store: store, networks: networks, sessions: sessions, slots: slots,
      initialSection: .overview)
  }

  init(
    containerID: ContainerID,
    store: ContainerStore,
    networks: NetworkStore,
    sessions: ContainerSessionFactory,
    slots: ContainerOperationSlots,
    initialSection: ContainerDetailSection
  ) {
    self.containerID = containerID
    self.store = store
    self.networks = networks
    self.sessions = sessions
    self.slots = slots
    self.initialSection = initialSection
  }

  public var body: some View {
    PresentedContainer(
      containerID: containerID, store: store, networks: networks, sessions: sessions, slots: slots,
      initialSection: initialSection
    )
    .id(containerID)
  }
}

private struct PresentedContainer: View {
  let containerID: ContainerID
  let store: ContainerStore
  let networks: NetworkStore
  let sessions: ContainerSessionFactory
  let slots: ContainerOperationSlots
  @State private var presentation: Presentation

  init(
    containerID: ContainerID,
    store: ContainerStore,
    networks: NetworkStore,
    sessions: ContainerSessionFactory,
    slots: ContainerOperationSlots,
    initialSection: ContainerDetailSection
  ) {
    self.containerID = containerID
    self.store = store
    self.networks = networks
    self.sessions = sessions
    self.slots = slots
    let initial: Presentation =
      switch initialSection {
      case .overview: .overview
      case .logs: .logs(sessions.makeLogSession(for: containerID))
      case .stats: .stats(sessions.makeStatsSession(for: containerID))
      }
    _presentation = State(initialValue: initial)
  }

  var body: some View {
    let snapshot = store.containers
    let summary = snapshot.value?.first { $0.id == containerID }
    if summary == nil, case .overview = presentation {
      overviewPlaceholder(snapshot)
    } else {
      VStack(spacing: 0) {
        Picker(LocalizedStringResource("Content", bundle: #bundle), selection: sectionBinding) {
          ForEach(ContainerDetailSection.allCases) { section in
            Text(section.title).tag(section)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        Divider()
        switch presentation {
        case .overview:
          if let summary {
            ContainerOverview(summary: summary, networks: networks, slots: slots)
          } else {
            overviewPlaceholder(snapshot)
          }
        case .logs(let session):
          // The screen runs its session once, so a different session needs a different screen.
          ContainerLogView(session: session).id(ObjectIdentifier(session))
        case .stats(let session):
          ContainerStatsView(session: session).id(ObjectIdentifier(session))
        }
      }
      .navigationTitle(
        summary.map { Text(verbatim: $0.name) }
          ?? Text("Deleted container", bundle: #bundle))
    }
  }

  @ViewBuilder
  private func overviewPlaceholder(_ snapshot: ResourceSnapshot<[ContainerSummary]>) -> some View {
    if snapshot.value != nil {
      ContentUnavailableView(LocalizedStringResource("Container not found", bundle: #bundle), systemImage: "shippingbox",
        description: Text("This container was removed or isn't in the list.", bundle: #bundle))
    } else if let error = snapshot.error {
      ContentUnavailableView {
        Label(LocalizedStringResource("Can't load the container", bundle: #bundle), systemImage: "exclamationmark.triangle")
      } description: {
        Text(verbatim: error.displayMessage).textSelection(.enabled)
      }
    } else {
      ProgressView(LocalizedStringResource("Loading containers…", bundle: #bundle))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var sectionBinding: Binding<ContainerDetailSection> {
    Binding(
      get: { presentation.section },
      set: { section in
        guard section != presentation.section else { return }
        switch section {
        case .overview: presentation = .overview
        case .logs: presentation = .logs(sessions.makeLogSession(for: containerID))
        case .stats: presentation = .stats(sessions.makeStatsSession(for: containerID))
        }
      })
  }
}

private struct ContainerOverview: View {
  let summary: ContainerSummary
  let networks: NetworkStore
  let slots: ContainerOperationSlots

  var body: some View {
    Form {
      Section(LocalizedStringResource("General", bundle: #bundle)) {
        LabeledContent(LocalizedStringResource("Name", bundle: #bundle)) { Text(verbatim: summary.name).textSelection(.enabled) }
        LabeledContent(LocalizedStringResource("Image", bundle: #bundle)) { Text(verbatim: summary.image).textSelection(.enabled) }
        LabeledContent(LocalizedStringResource("Status", bundle: #bundle)) { ContainerStateBadge(state: summary.state) }
        LabeledContent(LocalizedStringResource("Published ports", bundle: #bundle)) {
          Text(verbatim: summary.ports.displayText)
            .monospacedDigit()
            .textSelection(.enabled)
        }
      }
      AttachedNetworksSection(networkNames: summary.networkNames)
      ContainerNetworkConnectSection(container: summary, networks: networks, slots: slots)
    }
    .formStyle(.grouped)
    // Keeps the candidate networks of ContainerNetworkConnectSection current while the overview is shown.
    .task { await networks.monitor() }
  }
}
