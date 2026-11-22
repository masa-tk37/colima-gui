import ColimaCore
import Foundation

struct MenuBarPresentation: Equatable {
  enum Tone: Equatable {
    case running, neutral, busy, caution
  }

  enum PrimaryAction: Equatable {
    case start(title: LocalizedStringResource)
    case stop
    case none
  }

  let statusTitle: LocalizedStringResource
  let statusSymbol: String
  let tone: Tone
  let isBusy: Bool
  let statusDetail: String?
  let failureTitle: LocalizedStringResource?
  let failureCause: String?
  let primaryAction: PrimaryAction
  let showsDataDiskNote: Bool

  init(
    availability: DockerAvailability,
    observation: VMObservation,
    operation: VMOperationProgress?,
    failure: VMOperationFailure?,
    dataDiskMayRemain: Bool
  ) {
    let status = Self.status(for: availability, observation: observation, operation: operation)
    statusTitle = status.title
    statusSymbol = status.symbol
    tone = status.tone
    statusDetail = status.detail
    isBusy = operation != nil

    let shownFailure = operation == nil ? failure : nil
    failureTitle = shownFailure.map {
      LocalizedStringResource("Last failure: \(String(localized: $0.kind.failureTitle))", bundle: #bundle)
    }
    failureCause = shownFailure?.cause.message

    primaryAction = Self.primaryAction(for: availability)
    showsDataDiskNote = dataDiskMayRemain && availability.isAwaitingUserAction
  }

  private static func primaryAction(for availability: DockerAvailability) -> PrimaryAction {
    switch availability {
    case .vmStopped: .start(title: LocalizedStringResource("Start", bundle: #bundle))
    case .vmAbsent: .start(title: LocalizedStringResource("Create and start", bundle: #bundle))
    case .ready: .stop
    case .colimaMissing, .vmBusy, .vmUnknown: .none
    }
  }

  private struct Status {
    let title: LocalizedStringResource
    let symbol: String
    let tone: Tone
    var detail: String?
  }

  private static func status(
    for availability: DockerAvailability, observation: VMObservation,
    operation: VMOperationProgress?
  ) -> Status {
    switch availability {
    case .vmBusy(let state):
      let detail = operation.map {
        String(localized: "\($0.kind.label): \($0.stage.label)", bundle: #bundle)
      }
      switch state {
      case .stopping:
        return Status(title: LocalizedStringResource("Stopping", bundle: #bundle), symbol: "stop.circle", tone: .busy, detail: detail)
      case .starting, .running, .stopped:
        return Status(title: LocalizedStringResource("Starting", bundle: #bundle), symbol: "play.circle", tone: .busy, detail: detail)
      }
    case .colimaMissing:
      return Status(
        title: LocalizedStringResource("Colima not found", bundle: #bundle), symbol: "exclamationmark.triangle.fill", tone: .caution)
    case .ready:
      return Status(title: LocalizedStringResource("Running", bundle: #bundle), symbol: "checkmark.circle.fill", tone: .running)
    case .vmStopped:
      if case .present(let instance) = observation, instance.runState.isBroken {
        return Status(title: LocalizedStringResource("Broken", bundle: #bundle), symbol: "exclamationmark.triangle.fill", tone: .caution)
      }
      return Status(title: LocalizedStringResource("Stopped", bundle: #bundle), symbol: "pause.circle", tone: .neutral)
    case .vmAbsent:
      return Status(title: LocalizedStringResource("Not created", bundle: #bundle), symbol: "shippingbox", tone: .neutral)
    case .vmUnknown(let reason):
      return Status(title: LocalizedStringResource("Unknown", bundle: #bundle), symbol: "questionmark.circle", tone: .neutral, detail: reason)
    }
  }
}
