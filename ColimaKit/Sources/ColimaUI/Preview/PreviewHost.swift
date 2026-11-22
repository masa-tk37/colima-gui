#if DEBUG
  import SwiftUI

  /// A view file's `#Preview` must sit inside `#if DEBUG`: the macro's body is compiled in release builds too, and the
  /// scene builders do not exist there.
  struct PreviewHost<Model, Content: View>: View {
    private let make: @MainActor () async -> Model
    private let content: (Model) -> Content
    @State private var model: Model?

    init(
      _ make: @escaping @MainActor () async -> Model,
      @ViewBuilder content: @escaping (Model) -> Content
    ) {
      self.make = make
      self.content = content
    }

    var body: some View {
      Group {
        if let model {
          content(model)
        } else {
          ProgressView()
        }
      }
      .task {
        guard model == nil else { return }
        model = await make()
      }
    }
  }
#endif
