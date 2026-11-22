import SwiftUI

struct RemovalStatusCell: View {
  let isRemoving: Bool
  let failure: String?

  @ViewBuilder
  var body: some View {
    if isRemoving {
      ProgressView().controlSize(.small)
        .accessibilityLabel(LocalizedStringResource("Deleting", bundle: #bundle))
    } else if let failure {
      Image(systemName: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .help(failure)
        .accessibilityLabel(LocalizedStringResource("Couldn't delete: \(failure)", bundle: #bundle))
    }
  }
}

struct RemovalFailurePanel: View {
  let failures: [(name: String, message: String)]

  @ViewBuilder
  var body: some View {
    if !failures.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
            Label {
              Text("Couldn't delete “\(failure.name)”: \(failure.message)", bundle: #bundle)
                .textSelection(.enabled)
            } icon: {
              Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .font(.callout)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 120)
      .background(.bar)
      .accessibilityElement(children: .contain)
    }
  }
}

struct PruneStatusStrip<Outcome: View>: View {
  let isPruning: Bool
  let runningText: LocalizedStringResource
  let requestError: String?
  let outcome: Outcome?
  let showsNothingToPrune: Bool
  let nothingToPruneDetail: LocalizedStringResource

  @ViewBuilder
  var body: some View {
    if isPruning {
      strip {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(runningText)
        }
      }
    } else if let requestError {
      strip {
        Label {
          Text("Couldn't load the items to delete: \(requestError)", bundle: #bundle).textSelection(.enabled)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    } else if let outcome {
      strip { outcome }
    } else if showsNothingToPrune {
      strip {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Nothing to delete", bundle: #bundle)
            Text(nothingToPruneDetail).foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        }
      }
    }
  }

  private func strip(@ViewBuilder _ content: () -> some View) -> some View {
    content()
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
      .accessibilityElement(children: .contain)
  }
}

struct PruneFailureList: View {
  let failures: [(name: String, message: String)]

  var body: some View {
    ScrollView {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(failures.count) items couldn't be deleted.", bundle: #bundle)
          ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
            Text(verbatim: "“\(failure.name)”: \(failure.message)")
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } icon: {
        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
      }
    }
    .frame(maxHeight: 120)
  }
}
