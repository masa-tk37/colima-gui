import ColimaCore
import SwiftUI

/// The store keeps the errors of its last attempt until the next one, so they are shown only after this sheet
/// submitted something itself; a reopened sheet starts clean.
struct NetworkCreateSheet: View {
  let store: NetworkStore
  @Environment(\.dismiss) private var dismiss
  @State private var form: NetworkCreateForm
  @State private var result: NetworkCreateResult?
  @FocusState private var focusedField: NetworkField?

  init(
    store: NetworkStore,
    form: NetworkCreateForm = NetworkCreateForm(name: "", subnet: ""),
    result: NetworkCreateResult? = nil
  ) {
    self.store = store
    _form = State(initialValue: form)
    _result = State(initialValue: result)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField(LocalizedStringResource("Name", bundle: #bundle), text: $form.name, prompt: Text(verbatim: "my-network"))
            .focused($focusedField, equals: .name)
          fieldErrors(.name)
          TextField(LocalizedStringResource("Subnet (optional)", bundle: #bundle), text: $form.subnet, prompt: Text(verbatim: "172.28.0.0/16"))
            .focused($focusedField, equals: .subnet)
          fieldErrors(.subnet)
          LabeledContent(LocalizedStringResource("Driver", bundle: #bundle)) { Text(verbatim: "bridge") }
        } header: {
          Text("Create network", bundle: #bundle)
        }
        if let notice {
          Section { noticeLabel(notice) }
        }
      }
      .formStyle(.grouped)
      .disabled(store.isCreating)
      Divider()
      buttons
    }
    .frame(width: 440)
    .defaultFocus($focusedField, .name)
    .onSubmit(submit)
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      if store.isCreating {
        ProgressView().controlSize(.small)
        Text("Creating…", bundle: #bundle).foregroundStyle(.secondary)
      }
      Spacer()
      Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(LocalizedStringResource("Create", bundle: #bundle), action: submit)
        .keyboardShortcut(.defaultAction)
        .disabled(store.isCreating)
    }
    .padding(12)
  }

  // MARK: Errors

  @ViewBuilder
  private func fieldErrors(_ field: NetworkField) -> some View {
    if case .invalid = result {
      ForEach(store.createFieldErrors.filter { $0.field == field }, id: \.message) { error in
        Text(verbatim: error.message)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel(
            field == .name
              ? Text("Name error: \(error.message)", bundle: #bundle)
              : Text("Subnet error: \(error.message)", bundle: #bundle))
      }
    }
  }

  private enum Notice {
    case failure(String)
    case unavailable
    case busy
  }

  private var notice: Notice? {
    switch result {
    case .failed:
      store.createFailure.map(Notice.failure)
    case .unavailable: .unavailable
    case .busy: .busy
    default: nil
    }
  }

  @ViewBuilder
  private func noticeLabel(_ notice: Notice) -> some View {
    switch notice {
    case .failure(let message):
      Label {
        Text("Couldn't create the network: \(message)", bundle: #bundle).textSelection(.enabled)
      } icon: {
        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
      }
    case .unavailable:
      Label {
        Text("Couldn't create the network because Docker is unavailable.", bundle: #bundle)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    case .busy:
      Label {
        Text("Another network is being created. Wait for it to finish, then try again.", bundle: #bundle)
      } icon: {
        Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Submit

  private func submit() {
    guard !store.isCreating else { return }
    Task {
      let outcome = await store.createNetwork(form)
      result = outcome
      if case .created = outcome { dismiss() }
    }
  }
}
