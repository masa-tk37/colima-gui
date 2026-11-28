import ColimaCore
import SwiftUI

struct MachineNumberField: View {
  let title: LocalizedStringResource
  @Binding var text: String
  let field: MachineField
  let unit: String?
  let errors: [String]
  var focus: FocusState<MachineField?>.Binding

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 6) {
        TextField(title, text: $text)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 80)
          .focused(focus, equals: field)
        if let unit { Text(verbatim: unit).foregroundStyle(.secondary) }
      }
    }
    MachineFieldErrors(errors: errors)
  }
}

struct MachineFieldErrors: View {
  let errors: [String]

  var body: some View {
    ForEach(errors, id: \.self) { message in
      Text(verbatim: message)
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
