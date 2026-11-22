import SwiftUI

struct ListSummaryBar: View {
  let text: Text

  var body: some View {
    text
      .font(.callout)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TagBadge: View {
  let title: LocalizedStringResource
  var tint: Color = .secondary

  var body: some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(tint.opacity(0.15), in: .capsule)
      // A badge is short and meaningless when cut; the name beside it truncates instead.
      .fixedSize()
  }
}
