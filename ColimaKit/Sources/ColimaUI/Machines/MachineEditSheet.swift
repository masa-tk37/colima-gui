import ColimaCore
import SwiftUI
import UniformTypeIdentifiers

struct MachineEditSheet: View {
  let controller: MachineController
  let name: MachineName
  @Environment(\.dismiss) private var dismiss
  @State private var form: MachineEditFormPresentation?

  init(controller: MachineController, name: MachineName, form: MachineEditFormPresentation? = nil) {
    self.controller = controller
    self.name = name
    let instance = controller.machines?.first { $0.name == name }
    _form = State(initialValue: form ?? instance.map(MachineEditFormPresentation.init(instance:)))
  }

  var body: some View {
    let content = MachineEditFormPresentation.content(
      canEdit: controller.canEdit(name), saveStarted: form?.saveStarted ?? false)
    if content == .form, let binding = Binding($form) {
      MachineEditForm(controller: controller, name: name, form: binding)
    } else {
      StopFirstGuidance { dismiss() }
    }
  }
}

private struct StopFirstGuidance: View {
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ContentUnavailableView {
        Label {
          Text("Stop the machine before editing it", bundle: #bundle)
        } icon: {
          Image(systemName: "stop.circle")
        }
      } description: {
        Text(
          "A running machine, or one with an operation in progress, cannot be edited. Stop it and wait for the operation to finish, then edit it.",
          bundle: #bundle)
      }
      .frame(maxHeight: .infinity)
      Divider()
      HStack {
        Spacer()
        Button(LocalizedStringResource("Close", bundle: #bundle), action: close)
          .keyboardShortcut(.cancelAction)
      }
      .padding(12)
    }
    .frame(width: 440, height: 260)
  }
}

private struct MachineEditForm: View {
  let controller: MachineController
  let name: MachineName
  @Environment(\.dismiss) private var dismiss
  @Binding var form: MachineEditFormPresentation
  @State private var choosingFolders = false
  @FocusState private var focusedField: MachineField?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          numberField(LocalizedStringResource("CPU", bundle: #bundle), text: $form.input.cpus, field: .cpu, unit: nil)
          numberField(
            LocalizedStringResource("Memory", bundle: #bundle), text: $form.input.memoryGiB, field: .memory, unit: "GiB")
          numberField(
            LocalizedStringResource("Disk", bundle: #bundle), text: $form.input.diskGiB, field: .disk, unit: "GiB")
        } header: {
          HStack(spacing: 6) {
            Text("Edit machine", bundle: #bundle)
            Text(verbatim: name.rawValue).foregroundStyle(.secondary)
          }
        } footer: {
          Text("Changes take effect the next time the machine starts.", bundle: #bundle)
        }
        Section {
          mountRows
          Button {
            choosingFolders = true
          } label: {
            Label {
              Text("Add folder…", bundle: #bundle)
            } icon: {
              Image(systemName: "plus.circle")
            }
          }
        } header: {
          Text("Shared folders", bundle: #bundle)
        }
      }
      .formStyle(.grouped)
      Divider()
      buttons
    }
    .frame(width: 480)
    .defaultFocus($focusedField, .cpu)
    .onSubmit(save)
    .fileImporter(isPresented: $choosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      form.addMounts(folders: urls)
    }
  }

  // MARK: Fields

  private func numberField(
    _ title: LocalizedStringResource, text: Binding<String>, field: MachineField, unit: String?
  ) -> some View {
    MachineNumberField(
      title: title, text: text, field: field, unit: unit, errors: form.errors(for: field), focus: $focusedField)
  }

  @ViewBuilder
  private var mountRows: some View {
    if form.input.mounts.isEmpty {
      Text("No folders are shared with this machine.", bundle: #bundle).foregroundStyle(.secondary)
    }
    ForEach(Array(form.input.mounts.enumerated()), id: \.offset) { index, mount in
      HStack(spacing: 8) {
        Text(verbatim: mount.path)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(mount.path)
        Spacer(minLength: 8)
        Toggle(
          isOn: Binding(
            get: { mount.writable }, set: { form.setWritable($0, at: index) })
        ) {
          Text("Writable", bundle: #bundle)
        }
        .toggleStyle(.checkbox)
        Button {
          form.removeMount(at: index)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(Text("Remove folder", bundle: #bundle))
        .accessibilityLabel(Text("Remove folder", bundle: #bundle))
      }
      fieldErrors(.mount(index: index))
    }
  }

  private func fieldErrors(_ field: MachineField) -> some View {
    MachineFieldErrors(errors: form.errors(for: field))
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack(spacing: 8) {
      Spacer()
      Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(LocalizedStringResource("Save", bundle: #bundle), action: save)
        .keyboardShortcut(.defaultAction)
        .disabled(!form.canSave)
    }
    .padding(12)
  }

  private func save() {
    guard form.canSave else { return }
    let input = form.input
    if form.apply(controller.saveEdit(name, input), submitted: input) { dismiss() }
  }
}

#if DEBUG
  @MainActor
  enum MachineEditSheetPreviewScenario {
    case stopped, running, operationInProgress, fieldErrors, diskShrink, badMountPaths

    nonisolated static let missingFolder = "/Volumes/gone"

    func make() async -> (MachineController, MachineName, MachineEditFormPresentation?) {
      let cli = PreviewLimaCLI()
      cli.configure { $0.listing = .success(PreviewMachineData.mixedListing) }
      let controller = MachineController(
        cli: cli, host: PreviewMachineData.host, homeDirectory: PreviewMachineData.homeDirectory,
        directoryExists: { $0 != Self.missingFolder })
      await controller.refreshNow()
      let name = self == .running ? PreviewMachineData.running : PreviewMachineData.stopped
      if self == .operationInProgress {
        controller.requestStart(name)
        await PreviewSettle.until("the start holds the machine") { !controller.canEdit(name) }
      }
      guard let instance = controller.machines?.first(where: { $0.name == name }), var form = attempt(on: instance)
      else { return (controller, name, nil) }
      form.apply(controller.saveEdit(name, form.input), submitted: form.input)
      return (controller, name, form)
    }

    private func attempt(on instance: MachineInstance) -> MachineEditFormPresentation? {
      var form = MachineEditFormPresentation(instance: instance)
      switch self {
      case .stopped, .running, .operationInProgress:
        return nil
      case .fieldErrors:
        form.input.cpus = "abc"
        form.input.memoryGiB = "99999"
        form.input.diskGiB = "0"
      case .diskShrink:
        form.input.diskGiB = "50"
      case .badMountPaths:
        form.addMounts([Self.missingFolder, "/Volumes/data", "/Volumes/data/app", "relative"])
        form.setWritable(true, at: 2)
      }
      return form
    }
  }

  private struct EditSheetPreview: View {
    let scenario: MachineEditSheetPreviewScenario

    var body: some View {
      PreviewHost({ await scenario.make() }) { controller, name, form in
        MachineEditSheet(controller: controller, name: name, form: form)
      }
    }
  }

  #Preview("Stopped machine") {
    EditSheetPreview(scenario: .stopped)
  }

  #Preview("Running machine") {
    EditSheetPreview(scenario: .running)
  }

  #Preview("Operation in progress") {
    EditSheetPreview(scenario: .operationInProgress)
  }

  #Preview("Errors under each field") {
    EditSheetPreview(scenario: .fieldErrors)
  }

  #Preview("Disk shrink") {
    EditSheetPreview(scenario: .diskShrink)
  }

  #Preview("Bad shared folders") {
    EditSheetPreview(scenario: .badMountPaths)
  }
#endif
