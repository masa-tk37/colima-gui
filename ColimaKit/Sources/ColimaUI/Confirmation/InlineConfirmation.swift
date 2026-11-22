import ColimaCore
import SwiftUI

struct InlineConfirmation: View {
  let request: ConfirmationRequest
  let approve: () -> Void
  let cancel: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Text(request.message)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(request.itemGroups.enumerated()), id: \.offset) { _, group in
          ConfirmationItems(group: group)
        }
        HStack {
          Spacer(minLength: 0)
          Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel, action: cancel)
          Button(request.confirmLabel, role: .destructive, action: approve)
        }
      }
    } label: {
      Text(request.title)
    }
  }
}

private struct ConfirmationItems: View {
  let group: ConfirmationItemGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let title = group.title {
        Text(title).font(.subheadline.weight(.semibold))
      }
      ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
        Text(item).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}
