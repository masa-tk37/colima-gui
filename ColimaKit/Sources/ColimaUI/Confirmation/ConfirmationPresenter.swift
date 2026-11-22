import ColimaCore
import SwiftUI

public struct ConfirmationPresenter: View {
  private let origin: ConfirmationOrigin
  private let request: ConfirmationRequest?
  private let confirm: @MainActor (ConfirmationRequest.ID) -> ConfirmationOutcome
  private let dismiss: @MainActor () -> Void
  @State private var rejectionReason: String?

  /// - Parameters:
  ///   - origin: the surface this presenter sits on; requests raised elsewhere are ignored.
  ///   - request: the owner's `pendingConfirmation`.
  ///   - rejectionReason: a reason to show from the start; later refusals set it themselves.
  ///   - confirm: the owner's `confirm(id:)`.
  ///   - dismiss: the owner's `dismissConfirmation()`.
  public init(
    origin: ConfirmationOrigin,
    request: ConfirmationRequest?,
    rejectionReason: String? = nil,
    confirm: @escaping @MainActor (ConfirmationRequest.ID) -> ConfirmationOutcome,
    dismiss: @escaping @MainActor () -> Void
  ) {
    self.origin = origin
    self.request = request
    self.confirm = confirm
    self.dismiss = dismiss
    _rejectionReason = State(initialValue: rejectionReason)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let rejectionReason {
        RejectionNotice(reason: rejectionReason) { self.rejectionReason = nil }
      }
      if let shown, origin == .menuBar {
        InlineConfirmation(request: shown, approve: { approve(shown) }, cancel: dismiss)
      }
    }
    .confirmationDialog(
      dialogRequest?.title ?? "",
      isPresented: presentation(of: dialogRequest),
      titleVisibility: .visible,
      presenting: dialogRequest
    ) { request in
      Button(request.confirmLabel, role: .destructive) { approve(request) }
      Button(LocalizedStringResource("Cancel", bundle: #bundle), role: .cancel, action: dismiss)
    } message: { request in
      Text(request.message)
    }
    .sheet(item: sheetBinding) { request in
      ConfirmationSheet(request: request, approve: { approve(request) }, cancel: dismiss)
    }
  }

  private var shown: ConfirmationRequest? {
    guard let request, request.isShown(on: origin) else { return nil }
    return request
  }

  private var dialogRequest: ConfirmationRequest? {
    guard origin == .window, let shown, shown.itemGroups.isEmpty else { return nil }
    return shown
  }

  private var sheetRequest: ConfirmationRequest? {
    guard origin == .window, let shown, !shown.itemGroups.isEmpty else { return nil }
    return shown
  }

  /// The setter is a no-op: SwiftUI clears the binding on any dialog button tap, in an order unspecified against
  /// the button action, so dismissing here would race `approve` and turn it into `.notPending`.
  private func presentation(of request: ConfirmationRequest?) -> Binding<Bool> {
    Binding(get: { request != nil }, set: { _ in })
  }

  private var sheetBinding: Binding<ConfirmationRequest?> {
    Binding(get: { sheetRequest }, set: { if $0 == nil { dismiss() } })
  }

  private func approve(_ request: ConfirmationRequest) {
    if case .rejectedBusy(let reason) = confirm(request.id) {
      rejectionReason = reason
    }
  }
}
