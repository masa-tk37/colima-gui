import ColimaCore
import SwiftUI

struct ConfirmationSheet: View {
  let request: ConfirmationRequest
  let approve: () -> Void
  let cancel: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(request.message)
        }
        ForEach(Array(request.itemGroups.enumerated()), id: \.offset) { _, group in
          Section {
            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
              Text(item)
            }
          } header: {
            if let title = group.title {
              Text(title)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(request.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel, action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(request.confirmLabel, role: .destructive, action: approve)
        }
      }
    }
    .presentationSizing(.form)
  }
}
