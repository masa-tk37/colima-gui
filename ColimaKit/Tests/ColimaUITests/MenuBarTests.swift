import AppKit
import ColimaCore
import Foundation
import Testing

@testable import ColimaUI

@Suite(.timeLimit(.minutes(1)))
struct MenuBarIconTests {
  private let states: [VMDisplayState] = [.running, .stopped, .starting, .stopping]

  @Test func eachStateHasItsOwnImageAndLabel() {
    #expect(Set(states.map(\.menuBarImageName)).count == states.count)
    #expect(Set(states.map { String(localized: $0.menuBarAccessibilityLabel) }).count == states.count)
  }

  /// The menu bar tints a template image; a non-template one would stay black on a dark menu bar.
  @Test func everyImageIsATemplateInTheModuleBundle() throws {
    let products = Bundle(for: MenuBarBundleAnchor.self).bundleURL.deletingLastPathComponent()
    let resources = try #require(Bundle(url: products.appending(path: "ColimaKit_ColimaUI.bundle")))
    for state in states {
      let image = try #require(resources.image(forResource: state.menuBarImageName), "\(state.menuBarImageName)")
      #expect(image.isTemplate, "\(state.menuBarImageName) is not a template")
    }
  }

  @Test func labelsNameTheState() {
    #expect(String(localized: VMDisplayState.running.menuBarAccessibilityLabel) == "Colima: Running")
    #expect(String(localized: VMDisplayState.stopped.menuBarAccessibilityLabel) == "Colima: Stopped")
    #expect(String(localized: VMDisplayState.starting.menuBarAccessibilityLabel) == "Colima: Starting")
    #expect(String(localized: VMDisplayState.stopping.menuBarAccessibilityLabel) == "Colima: Stopping")
  }
}

@Suite(.timeLimit(.minutes(1)))
struct MenuBarPresentationTests {
  private let t0 = Date(timeIntervalSince1970: 1_000)

  private func presentation(
    _ availability: DockerAvailability,
    observation: VMObservation = .unknown(reason: "x"),
    operation: VMOperationProgress? = nil,
    failure: VMOperationFailure? = nil,
    dataDiskMayRemain: Bool = false
  ) -> MenuBarPresentation {
    MenuBarPresentation(
      availability: availability, observation: observation, operation: operation, failure: failure,
      dataDiskMayRemain: dataDiskMayRemain)
  }

  private func startTitle(_ presentation: MenuBarPresentation) -> String? {
    guard case .start(let title) = presentation.primaryAction else { return nil }
    return String(localized: title)
  }

  private func failure(_ cause: VMFailureCause = .exited(code: 1)) -> VMOperationFailure {
    VMOperationFailure(kind: .start, stage: .starting, cause: cause, outputLines: [])
  }

  @Test func runningOffersStop() {
    let p = presentation(.ready, observation: .present(PreviewVMData.instance(running: true)))
    #expect(String(localized: p.statusTitle) == "Running")
    #expect(p.primaryAction == .stop)
    #expect(p.statusDetail == nil)
    #expect(p.failureTitle == nil)
  }

  @Test func stoppedOffersStart() {
    let p = presentation(.vmStopped, observation: .present(PreviewVMData.instance(running: false)))
    #expect(String(localized: p.statusTitle) == "Stopped")
    #expect(startTitle(p) == "Start")
  }

  @Test func brokenReadsAsAbnormalButStillOffersStart() {
    let p = presentation(
      .vmStopped, observation: .present(PreviewVMData.instance(rawStatus: "Broken")))
    #expect(String(localized: p.statusTitle) == "Broken")
    #expect(startTitle(p) == "Start")
  }

  @Test func absentOffersCreateAndStart() {
    let p = presentation(.vmAbsent, observation: .absent)
    #expect(String(localized: p.statusTitle) == "Not created")
    #expect(startTitle(p) == "Create and start")
  }

  @Test func unknownShowsTheReasonAndOffersNothing() {
    let p = presentation(.vmUnknown(reason: "colima list failed"))
    #expect(String(localized: p.statusTitle) == "Unknown")
    #expect(p.statusDetail == "colima list failed")
    #expect(p.primaryAction == .none)
  }

  @Test func beforeTheFirstLookupThereIsNoReason() {
    let p = presentation(.vmUnknown(reason: nil))
    #expect(String(localized: p.statusTitle) == "Unknown")
    #expect(p.statusDetail == nil)
    #expect(p.primaryAction == .none)
  }

  @Test func missingColimaOffersNothing() {
    let p = presentation(.colimaMissing(searched: ["/opt/homebrew/bin"]))
    #expect(String(localized: p.statusTitle) == "Colima not found")
    #expect(p.primaryAction == .none)
  }

  @Test func anOperationReplacesTheActionsAndNamesItsStage() {
    let operation = VMOperationProgress(
      kind: .start, stage: .starting, startedAt: t0, stageStartedAt: t0)
    let starting = presentation(.vmBusy(.starting), operation: operation)
    #expect(String(localized: starting.statusTitle) == "Starting")
    #expect(starting.statusDetail == "Start: Starting VM")
    #expect(starting.primaryAction == .none)

    let stop = VMOperationProgress(kind: .stop, stage: .stopping, startedAt: t0, stageStartedAt: t0)
    let stopping = presentation(.vmBusy(.stopping), operation: stop)
    #expect(String(localized: stopping.statusTitle) == "Stopping")
    #expect(stopping.statusDetail == "Stop: Stopping VM")
    #expect(stopping.primaryAction == .none)
  }

  @Test func aLastFailureIsSummarisedInOneLine() {
    let p = presentation(
      .vmStopped, observation: .present(PreviewVMData.instance(running: false)), failure: failure())
    #expect(p.failureTitle.map { String(localized: $0) } == "Last failure: Couldn't start the VM")
    #expect(p.failureCause == "colima exited with code 1")
    #expect(startTitle(p) == "Start")
  }

  @Test func aFailureIsHiddenWhileAnotherOperationRuns() {
    let operation = VMOperationProgress(
      kind: .start, stage: .starting, startedAt: t0, stageStartedAt: t0)
    let p = presentation(.vmBusy(.starting), operation: operation, failure: failure())
    #expect(p.failureTitle == nil)
    #expect(p.failureCause == nil)
  }

  @Test func theDataDiskNoteAppearsOnlyWhereCreatingIsOffered() {
    let absent = presentation(.vmAbsent, observation: .absent, dataDiskMayRemain: true)
    #expect(absent.showsDataDiskNote)
    let stopped = presentation(
      .vmStopped, observation: .present(PreviewVMData.instance(running: false)),
      dataDiskMayRemain: true)
    #expect(stopped.showsDataDiskNote)
    let running = presentation(
      .ready, observation: .present(PreviewVMData.instance(running: true)), dataDiskMayRemain: true)
    #expect(!running.showsDataDiskNote)
    let clean = presentation(.vmAbsent, observation: .absent, dataDiskMayRemain: false)
    #expect(!clean.showsDataDiskNote)
  }
}

private final class MenuBarBundleAnchor {}
