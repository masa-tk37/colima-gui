import ColimaCore
import SwiftUI

public struct DockerGateView: View {
  private let controller: VMController
  private let engineError: DockerError?
  private let retry: @MainActor () async -> Void
  @State private var retryRecreateResult: RecreateRequestResult?
  @State private var dismissedFailureID: VMOperationFailure.ID?

  /// - Parameters:
  ///   - engineError: the owning screen's last error; consulted only while the VM reads as running.
  ///   - retry: reloads the owning screen; offered when the engine cannot be reached.
  ///   - retryRecreateResult: initial value of what `requestRetryRecreate()` returned, so a static preview can show it.
  public init(
    controller: VMController,
    engineError: DockerError? = nil,
    retry: @escaping @MainActor () async -> Void,
    retryRecreateResult: RecreateRequestResult? = nil
  ) {
    self.controller = controller
    self.engineError = engineError
    self.retry = retry
    _retryRecreateResult = State(initialValue: retryRecreateResult)
  }

  public var body: some View {
    let availability = controller.dockerAvailability
    VStack(spacing: 16) {
      if let failure = controller.lastFailure, failure.id != dismissedFailureID {
        OperationFailureView(failure: failure, onDismiss: { dismissedFailureID = failure.id })
          .frame(maxWidth: 560)
      }
      content(for: availability)
      if controller.dataDiskMayRemain, availability.isAwaitingUserAction {
        DataDiskRecoveryView(
          canRetry: controller.canRetryRecreate,
          retryResult: retryRecreateResult,
          retry: requestRetryRecreate
        )
        .frame(maxWidth: 560)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func content(for availability: DockerAvailability) -> some View {
    switch availability {
    case .ready:
      unavailable(LocalizedStringResource("Can't connect to the Docker engine", bundle: #bundle), systemImage: "exclamationmark.triangle",
        message: Text(verbatim: engineMessage)
      ) {
        retryButton { await retry() }
      }
    case .colimaMissing(let searched):
      ColimaMissingView(searched: searched) {
        Task { await controller.redetectToolchain() }
      }
    case .vmStopped:
      unavailable(LocalizedStringResource("The VM is stopped", bundle: #bundle), systemImage: "pause.circle",
        message: Text("Start the VM to use Docker.", bundle: #bundle)
      ) {
        Button(LocalizedStringResource("Start", bundle: #bundle)) { controller.start() }
          .buttonStyle(.borderedProminent)
      }
    case .vmAbsent:
      unavailable(LocalizedStringResource("The VM hasn't been created", bundle: #bundle), systemImage: "shippingbox",
        message: Text("You can create a VM with the default settings.", bundle: #bundle)
      ) {
        Button(LocalizedStringResource("Create", bundle: #bundle)) { controller.create(controller.creationDefaults()) }
          .buttonStyle(.borderedProminent)
      }
    case .vmBusy:
      busy
    case .vmUnknown(let reason):
      unknown(reason: reason)
    }
  }

  private var engineMessage: String {
    if let engineError, !engineError.isConnectionFailure { return engineError.displayMessage }
    return EngineGuidance(observation: controller.observation).message
  }

  @ViewBuilder
  private var busy: some View {
    if let operation = controller.activeOperation {
      OperationOutputView(
        operation: operation, record: controller.latestRecord, abort: { controller.abortOperation() })
        .frame(maxWidth: 560)
    } else {
      ProgressView(LocalizedStringResource("Working on the VM", bundle: #bundle))
    }
  }

  @ViewBuilder
  private func unknown(reason: String?) -> some View {
    if let reason {
      unavailable(LocalizedStringResource("Can't check the VM status", bundle: #bundle), systemImage: "questionmark.circle", message: Text(verbatim: reason)
      ) {
        retryButton { await controller.refreshState() }
      }
    } else {
      ProgressView(LocalizedStringResource("Checking the VM status", bundle: #bundle))
    }
  }

  private func unavailable<Actions: View>(
    _ title: LocalizedStringResource,
    systemImage: String,
    message: Text,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      message
    } actions: {
      actions()
    }
  }

  private func retryButton(_ action: @escaping @MainActor () async -> Void) -> some View {
    Button(LocalizedStringResource("Retry", bundle: #bundle)) { Task { await action() } }
  }

  private func requestRetryRecreate() {
    Task { retryRecreateResult = await controller.requestRetryRecreate() }
  }
}

struct ColimaMissingView: View {
  let searched: [String]
  let redetect: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(LocalizedStringResource("Colima not found", bundle: #bundle), systemImage: "exclamationmark.triangle")
    } description: {
      VStack(spacing: 8) {
        Text("Install Colima, then detect it again.", bundle: #bundle)
        if !searched.isEmpty {
          Text("Searched locations", bundle: #bundle)
            .font(.subheadline)
          VStack(spacing: 2) {
            ForEach(searched, id: \.self) { path in
              Text(path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }
          }
        }
      }
    } actions: {
      Button(LocalizedStringResource("Detect again", bundle: #bundle), action: redetect)
    }
  }
}

extension DockerAvailability {
  var isAwaitingUserAction: Bool {
    switch self {
    case .vmAbsent, .vmStopped: true
    case .ready, .colimaMissing, .vmBusy, .vmUnknown: false
    }
  }
}

extension DockerError {
  var isConnectionFailure: Bool {
    switch self {
    case .engineUnreachable, .connectionLost, .timedOut: true
    case .api, .unexpectedResponse, .cancelled: false
    }
  }
}
