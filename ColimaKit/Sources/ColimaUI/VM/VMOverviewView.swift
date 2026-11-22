import ColimaCore
import SwiftUI

public struct VMOverviewView: View {
  private nonisolated static let sideBySideMinWidth: CGFloat = 720

  private let controller: VMController
  private let usageMonitor: VMUsageMonitor
  @State private var retryRecreateResult: RecreateRequestResult?
  @State private var dismissedFailureID: VMOperationFailure.ID?
  @State private var isWide = true

  /// - Parameter retryRecreateResult: initial value of what `requestRetryRecreate()` returned, so a static preview
  ///   can show it.
  public init(
    controller: VMController, usageMonitor: VMUsageMonitor, retryRecreateResult: RecreateRequestResult? = nil
  ) {
    self.controller = controller
    self.usageMonitor = usageMonitor
    _retryRecreateResult = State(initialValue: retryRecreateResult)
  }

  public var body: some View {
    let availability = controller.dockerAvailability
    Group {
      if case .colimaMissing(let searched) = availability {
        ColimaMissingView(searched: searched) {
          Task { await controller.redetectToolchain() }
        }
      } else {
        overview(availability: availability)
          .toolbar { toolbar }
      }
    }
    .navigationTitle(LocalizedStringResource("VM", bundle: #bundle))
    // Outside the width-dependent layout, so switching layouts never restarts sampling.
    .task { await usageMonitor.run() }
  }

  private func overview(availability: DockerAvailability) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VMStatusSummary(controller: controller, refresh: controller.refreshState)
        if let operation = controller.activeOperation {
          GroupBox {
            OperationOutputView(
              operation: operation, record: controller.latestRecord, showsLogButton: false,
              abort: { controller.abortOperation() })
          }
        }
        if let failure = controller.lastFailure, failure.id != dismissedFailureID {
          OperationFailureView(failure: failure, onDismiss: { dismissedFailureID = failure.id })
        }
        if controller.dataDiskMayRemain, availability.isAwaitingUserAction {
          DataDiskRecoveryView(
            canRetry: controller.canRetryRecreate,
            retryResult: retryRecreateResult,
            retry: requestRetryRecreate)
        }
        VMUsageCharts(monitor: usageMonitor, isSideBySide: isWide)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onGeometryChange(for: Bool.self) { $0.size.width >= Self.sideBySideMinWidth } action: { isWide = $0 }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      startButton
        .labelStyle(.titleAndIcon)
      Button(LocalizedStringResource("Stop", bundle: #bundle), systemImage: "stop.fill") {
        controller.requestStop(from: .window)
      }
      .labelStyle(.titleAndIcon)
      .disabled(!controller.canRequestStopOrRestart)
      Button(LocalizedStringResource("Restart", bundle: #bundle), systemImage: "arrow.clockwise") {
        controller.requestRestart()
      }
      .labelStyle(.titleAndIcon)
      .disabled(!controller.canRequestStopOrRestart)
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      ShowOperationLogButton()
    }
  }

  /// Not prominent: the toolbar draws a prominent item as a glass group of its own, which split it from Stop and
  /// Restart whenever the VM was stopped.
  private var startButton: some View {
    Button(
      controller.observation.isAbsent
        ? LocalizedStringResource("Create", bundle: #bundle)
        : LocalizedStringResource("Start", bundle: #bundle),
      systemImage: "play.fill"
    ) { controller.start() }
    .disabled(!controller.canStart)
  }

  private func requestRetryRecreate() {
    Task { retryRecreateResult = await controller.requestRetryRecreate() }
  }
}

extension VMObservation {
  var isRunning: Bool {
    if case .present(let instance) = self { instance.runState.isRunning } else { false }
  }

  fileprivate var isAbsent: Bool {
    if case .absent = self { true } else { false }
  }
}

extension VMRunState {
  var isBroken: Bool {
    if case .stopped(let rawStatus) = self { rawStatus == "Broken" } else { false }
  }
}
