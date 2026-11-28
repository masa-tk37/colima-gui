import ColimaCore
import SwiftUI

struct MachineCreateSheet: View {
  let controller: MachineController
  @Environment(\.dismiss) private var dismiss
  @State private var form: MachineCreateFormPresentation
  @FocusState private var focusedField: MachineField?

  init(controller: MachineController, form: MachineCreateFormPresentation = MachineCreateFormPresentation()) {
    self.controller = controller
    _form = State(initialValue: form)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          fields
        } header: {
          Text("Create machine", bundle: #bundle)
        }
        if form.showsBusy {
          Section { busyNotice }
        }
      }
      .formStyle(.grouped)
      .disabled(form.isSubmitting)
      Divider()
      buttons
    }
    .frame(width: 440)
    .defaultFocus($focusedField, .name)
    .onSubmit(submit)
    .task { await loadTemplates() }
  }

  // MARK: Fields

  @ViewBuilder
  private var fields: some View {
    TextField(LocalizedStringResource("Name", bundle: #bundle), text: $form.input.name, prompt: Text(verbatim: "my-machine"))
      .focused($focusedField, equals: .name)
    fieldErrors(.name)
    templatePicker
    fieldErrors(.template)
    numberField(
      LocalizedStringResource("CPU", bundle: #bundle), text: $form.input.cpus, field: .cpu, unit: nil)
    numberField(
      LocalizedStringResource("Memory", bundle: #bundle), text: $form.input.memoryGiB, field: .memory, unit: "GiB")
    numberField(
      LocalizedStringResource("Disk", bundle: #bundle), text: $form.input.diskGiB, field: .disk, unit: "GiB")
  }

  @ViewBuilder
  private var templatePicker: some View {
    switch form.templates {
    case .loading:
      LabeledContent(LocalizedStringResource("Distribution", bundle: #bundle)) {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading…", bundle: #bundle).foregroundStyle(.secondary)
        }
      }
    case .failed:
      LabeledContent(LocalizedStringResource("Distribution", bundle: #bundle)) {
        VStack(alignment: .trailing, spacing: 6) {
          Label {
            Text("Couldn't load the distributions", bundle: #bundle)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          if let message = form.loadFailureMessage {
            Text(verbatim: message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Button(LocalizedStringResource("Retry", bundle: #bundle)) { Task { await loadTemplates() } }
        }
      }
    case .loaded(let templates) where templates.isEmpty:
      LabeledContent(LocalizedStringResource("Distribution", bundle: #bundle)) {
        Text("No Linux distributions are available.", bundle: #bundle).foregroundStyle(.secondary)
      }
    case .loaded(let templates):
      Picker(LocalizedStringResource("Distribution", bundle: #bundle), selection: $form.input.templateID) {
        ForEach(templates, id: \.id) { template in
          Text(verbatim: template.displayName).tag(Optional(template.id))
        }
      }
    }
  }

  private func numberField(
    _ title: LocalizedStringResource, text: Binding<String>, field: MachineField, unit: String?
  ) -> some View {
    MachineNumberField(
      title: title, text: text, field: field, unit: unit, errors: form.errors(for: field), focus: $focusedField)
  }

  private func fieldErrors(_ field: MachineField) -> some View {
    MachineFieldErrors(errors: form.errors(for: field))
  }

  private var busyNotice: some View {
    Label {
      Text("A machine with this name is already being created.", bundle: #bundle)
    } icon: {
      Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack(spacing: 8) {
      if form.isSubmitting {
        ProgressView().controlSize(.small)
        Text("Creating…", bundle: #bundle).foregroundStyle(.secondary)
      }
      Spacer()
      Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(LocalizedStringResource("Create", bundle: #bundle), action: submit)
        .keyboardShortcut(.defaultAction)
        .disabled(!form.canSubmit)
    }
    .padding(12)
  }

  // MARK: Actions

  private func loadTemplates() async {
    form.load(await controller.availableTemplates())
  }

  private func submit() {
    guard form.canSubmit else { return }
    form.isSubmitting = true
    let input = form.input
    let templates = form.offeredTemplates
    Task {
      let outcome = await controller.create(input, templates: templates)
      form.isSubmitting = false
      if form.apply(outcome, submitted: input) { dismiss() }
    }
  }
}

#if DEBUG
  import ColimaCore
  import SwiftUI

  @MainActor
  private enum MachineCreateSheetPreviewScenario {
    case defaults, fieldErrors, nameCollision, defaultVMName, busy, limactlMissing

    func make() async -> (MachineController, MachineCreateFormPresentation) {
      let controllerScenario: MachineControllerPreviews.Scenario =
        switch self {
        case .defaults, .fieldErrors, .defaultVMName: .noMachines
        case .nameCollision: .mixed
        case .busy: .creating
        case .limactlMissing: .limactlMissing
        }
      let controller = await MachineControllerPreviews.make(controllerScenario).controller
      var form = MachineCreateFormPresentation()
      form.load(await controller.availableTemplates())
      guard let attempt else { return (controller, form) }
      attempt(&form.input)
      let outcome = await controller.create(form.input, templates: form.offeredTemplates)
      form.apply(outcome, submitted: form.input)
      return (controller, form)
    }

    private var attempt: ((inout MachineFormInput) -> Void)? {
      switch self {
      case .defaults, .limactlMissing:
        nil
      case .fieldErrors:
        { $0.name = ""; $0.cpus = "abc"; $0.memoryGiB = "99999"; $0.diskGiB = "0" }
      case .nameCollision:
        { $0.name = PreviewMachineData.running.rawValue }
      case .defaultVMName:
        { $0.name = "default" }
      case .busy:
        { $0.name = PreviewMachineData.creating.rawValue }
      }
    }
  }

  private struct CreateSheetPreview: View {
    let scenario: MachineCreateSheetPreviewScenario

    var body: some View {
      PreviewHost({ await scenario.make() }) { controller, form in
        MachineCreateSheet(controller: controller, form: form)
      }
    }
  }

  #Preview("Defaults") {
    CreateSheetPreview(scenario: .defaults)
  }

  #Preview("Errors under each field") {
    CreateSheetPreview(scenario: .fieldErrors)
  }

  #Preview("Name collision") {
    CreateSheetPreview(scenario: .nameCollision)
  }

  #Preview("Name of the default VM") {
    CreateSheetPreview(scenario: .defaultVMName)
  }

  #Preview("Same name already being created") {
    CreateSheetPreview(scenario: .busy)
  }

  #Preview("limactl missing") {
    CreateSheetPreview(scenario: .limactlMissing)
  }
#endif
