import ColimaCore
import SwiftUI

public struct VMSettingsView: View {
  @Bindable private var model: VMSettingsModel
  private let controller: VMController
  @State private var submitResult: SettingsSubmitResult?
  @State private var isSubmitting = false
  @State private var retryRecreateResult: RecreateRequestResult?
  private let host: HostResources

  /// - Parameters:
  ///   - model: the form state, created once at the app root.
  ///   - controller: the controller the model edits; read for the running operation and the data-disk notice.
  ///   - submitResult: initial value of what `submit()` returned, so a static preview can show it.
  ///   - host: this Mac's capacity, the upper end of each slider.
  public init(
    model: VMSettingsModel, controller: VMController, submitResult: SettingsSubmitResult? = nil,
    host: HostResources = .current
  ) {
    self.model = model
    self.host = host
    self.controller = controller
    _submitResult = State(initialValue: submitResult)
  }

  public var body: some View {
    Form {
      if let reason = model.loadFailureReason {
        Section {
          Label(reason, systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Section(LocalizedStringResource("Resources", bundle: #bundle)) {
        ResourceSlider(
          title: LocalizedStringResource("CPU", bundle: #bundle), text: $model.cpusText,
          range: 1...host.cpus, field: .cpu, errors: model.fieldErrors,
          isUnapplied: model.unappliedFields.contains(.cpu),
          maximumLabel: Text("Unlimited", bundle: #bundle)
        ) { cores in
          Int(cores) == host.cpus
            ? Text("Unlimited (\(host.cpus) cores)", bundle: #bundle)
            : Text("\(Int(cores)) cores", bundle: #bundle)
        }
        ResourceSlider(
          title: LocalizedStringResource("Memory", bundle: #bundle), text: $model.memoryGiBText,
          range: 1...host.memoryGiB, field: .memory, errors: model.fieldErrors,
          isUnapplied: model.unappliedFields.contains(.memory),
          maximumLabel: Text(verbatim: "\(host.memoryGiB) GiB")
        ) { gib in
          Text(verbatim: "\(gib.formatted(.number.precision(.fractionLength(0...1)))) GiB")
        }
        ResourceSlider(
          title: LocalizedStringResource("Disk", bundle: #bundle), text: $model.diskGiBText,
          range: diskRange, step: sliderStep(spanning: diskRange), field: .disk, errors: model.fieldErrors,
          isUnapplied: model.unappliedFields.contains(.disk),
          maximumLabel: Text(verbatim: "\(host.diskGiB) GiB")
        ) { gib in
          Text(verbatim: "\(Int(gib)) GiB")
        }
        if let floor = model.diskFloorGiB {
          Text("The disk can't go below its current \(floor) GiB without recreating the VM.", bundle: #bundle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Section(LocalizedStringResource("VM type", bundle: #bundle)) {
        vmTypeRows
      }
      Section {
        actionRows
      }
    }
    .formStyle(.grouped)
    .navigationTitle(LocalizedStringResource("VM settings", bundle: #bundle))
    // `onAppear()` rereads the state file; a created or recreated VM has a new one, so the type is also reread when a VM appears.
    .task { await model.onAppear() }
    .onChange(of: controller.observation.isPresent) { _, isPresent in
      if isPresent { model.refreshInstanceVMType() }
    }
    .onChange(of: model.input) {
      if submitResult != .saved(.restartRequired) { submitResult = nil }
    }
  }

  /// The floor can exceed the volume's capacity (a sparse disk image), so the range never inverts.
  private var diskRange: ClosedRange<Int> {
    let floor = model.diskFloorGiB ?? 1
    return floor...max(floor, host.diskGiB)
  }

  // MARK: VM type

  private var vmTypeRows: some View {
    let selection = Binding(
      get: { model.vmType },
      set: { type in Task { await model.selectVMType(type) } })
    let missing = model.missingExecutables(for: model.vmType)
    return VStack(alignment: .leading, spacing: 6) {
      Picker(LocalizedStringResource("VM type", bundle: #bundle), selection: selection) {
        ForEach(VMType.allCases, id: \.self) { type in
          Text(type.rawValue).tag(type)
        }
      }
      if model.unappliedFields.contains(.vmType) {
        UnappliedNote()
      }
      ForEach(model.fieldErrors.filter { $0.field == .vmType }, id: \.message) { error in
        FieldErrorNote(message: error.message)
      }
      if !missing.isEmpty {
        Label(
          LocalizedStringResource(
            "Required executables for \(model.vmType.rawValue) were not found: \(missing.joined(separator: ", "))",
            bundle: #bundle),
          systemImage: "exclamationmark.triangle.fill"
        )
        .symbolRenderingMode(.multicolor)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Action

  @ViewBuilder
  private var actionRows: some View {
    let action = model.primaryAction
    let isOperating = controller.activeOperation != nil
    HStack(alignment: .firstTextBaseline) {
      primaryButton(action, isOperating: isOperating)
      if isOperating {
        Text("Another operation is running", bundle: #bundle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    switch action {
    case .recreate:
      Label(LocalizedStringResource("Changing the VM type recreates the VM. All data inside the VM is deleted.", bundle: #bundle),
        systemImage: "exclamationmark.triangle.fill"
      )
      .symbolRenderingMode(.multicolor)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    case .unavailable(let reason):
      Label(reason, systemImage: "slash.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    case .create:
      if controller.dataDiskMayRemain {
        DataDiskRecoveryView(
          canRetry: controller.canRetryRecreate,
          retryResult: retryRecreateResult,
          retry: requestRetryRecreate)
      }
    case .save:
      EmptyView()
    }
    if let submitResult {
      ResultNote(
        result: submitResult, canRestart: controller.observation.isRunning,
        restartDisabled: isOperating || controller.pendingConfirmation != nil,
        restart: { model.requestRestart() })
    }
  }

  private func primaryButton(_ action: SettingsPrimaryAction, isOperating: Bool) -> some View {
    let isUnavailable = if case .unavailable = action { true } else { false }
    return Button(role: action == .recreate ? .destructive : nil) {
      submit()
    } label: {
      Text(Self.title(of: action))
    }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut(.defaultAction)
    .disabled(isUnavailable || isOperating || isSubmitting)
  }

  private static func title(of action: SettingsPrimaryAction) -> LocalizedStringResource {
    switch action {
    case .save: LocalizedStringResource("Save", bundle: #bundle)
    case .recreate: LocalizedStringResource("Recreate VM", bundle: #bundle)
    case .create: LocalizedStringResource("Create and start", bundle: #bundle)
    case .unavailable: LocalizedStringResource("Save", bundle: #bundle)
    }
  }

  private func submit() {
    isSubmitting = true
    Task {
      submitResult = await model.submit()
      isSubmitting = false
    }
  }

  private func requestRetryRecreate() {
    Task { retryRecreateResult = await controller.requestRetryRecreate() }
  }
}

extension VMObservation {
  fileprivate var isPresent: Bool {
    if case .present = self { true } else { false }
  }
}

/// The form keeps text, so a value set elsewhere (a fraction of a GiB, more than this Mac has) shows as it is until
/// the slider is moved; moving it writes whole numbers.
private struct ResourceSlider<ValueLabel: View>: View {
  let title: LocalizedStringResource
  @Binding var text: String
  let range: ClosedRange<Int>
  var step: Int = 1
  let field: SettingsField
  let errors: [SettingsFieldError]
  let isUnapplied: Bool
  let maximumLabel: Text
  @ViewBuilder let valueLabel: (Double) -> ValueLabel

  var body: some View {
    let value = Double(text.trimmingCharacters(in: .whitespaces))
    let lower = Double(range.lowerBound)
    let upper = max(Double(range.upperBound), value ?? 0, lower + 1)
    // A slider's stops start at its lower end, so the track starts at a multiple of the step to keep them round.
    let stepValue = Double(step)
    let trackLower = (lower / stepValue).rounded(.down) * stepValue
    let trackUpper = (upper / stepValue).rounded(.up) * stepValue
    let binding = Binding(
      get: { min(max(value ?? lower, lower), upper) },
      set: { text = String(Int(min(max($0, lower), upper).rounded())) })
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent(title) {
        Group {
          if let value { valueLabel(value) } else { Text(verbatim: "—") }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Slider(value: binding, in: trackLower...trackUpper, step: stepValue) {
        Text(title)
      } minimumValueLabel: {
        Text(verbatim: "\(range.lowerBound)")
      } maximumValueLabel: {
        maximumLabel
      }
      .labelsHidden()
      .font(.caption)
      .foregroundStyle(.secondary)
      if isUnapplied {
        UnappliedNote()
      }
      ForEach(errors.filter { $0.field == field }, id: \.message) { error in
        FieldErrorNote(message: error.message)
      }
    }
  }
}

private struct UnappliedNote: View {
  var body: some View {
    Label(LocalizedStringResource("The config file differs from the running VM. Restart to apply it.", bundle: #bundle), systemImage: "arrow.triangle.2.circlepath")
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct FieldErrorNote: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.circle.fill")
      .font(.callout)
      .foregroundStyle(.red)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct ResultNote: View {
  let result: SettingsSubmitResult
  let canRestart: Bool
  let restartDisabled: Bool
  let restart: () -> Void

  var body: some View {
    switch result {
    case .saved(.appliesOnNextStart):
      Label(LocalizedStringResource("Saved. The changes apply the next time the VM starts.", bundle: #bundle), systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .saved(.restartRequired):
      VStack(alignment: .leading, spacing: 8) {
        Label(LocalizedStringResource("Saved. Restart the VM to apply the changes.", bundle: #bundle), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if canRestart {
          Button(LocalizedStringResource("Restart", bundle: #bundle), systemImage: "arrow.clockwise", action: restart)
            .disabled(restartDisabled)
        }
      }
    case .recreateRequested:
      Label(LocalizedStringResource("A confirmation will appear. If you approve, the VM is deleted and recreated.", bundle: #bundle), systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
    case .createStarted:
      Label(LocalizedStringResource("Started creating the VM.", bundle: #bundle), systemImage: "play.circle.fill")
        .foregroundStyle(.secondary)
    case .invalid:
      Label(LocalizedStringResource("Some fields have errors. Check the message under each field.", bundle: #bundle), systemImage: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    case .busy:
      Label(LocalizedStringResource("Can't run this while another operation is running.", bundle: #bundle), systemImage: "hourglass")
        .foregroundStyle(.secondary)
    case .unavailable(let reason):
      Label(reason, systemImage: "slash.circle")
        .foregroundStyle(.secondary)
    case .recreateRejected(let error):
      Label(Self.explanation(of: error), systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }

  private static func explanation(of error: RecreatePlanError) -> LocalizedStringResource {
    switch error {
    case .sameVMType:
      LocalizedStringResource("The target VM type is the same as the current one.", bundle: #bundle)
    case .missingExecutables(let type, let missing):
      LocalizedStringResource(
        "Can't recreate: the executables required for \(type.rawValue) were not found: \(missing.joined(separator: ", "))",
        bundle: #bundle)
    }
  }
}

/// Keeps a wide range from becoming a solid row of tick marks.
private func sliderStep(spanning range: ClosedRange<Int>) -> Int {
  let span = range.upperBound - range.lowerBound
  return [1, 2, 5, 10, 20, 50, 100].first { span / $0 <= 24 } ?? 100
}
